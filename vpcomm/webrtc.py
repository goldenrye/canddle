"""Bounded WebRTC signaling and short-lived coturn REST credentials."""

import base64
import hashlib
import hmac
import json
import logging
import math
import os
import re
import time
from dataclasses import dataclass

QUALITY_LOG = logging.getLogger("vpcomm.quality")
QUALITY_LIMIT = 4096
QUALITY_ROUTE = re.compile(
    r"(?:(?:host|srflx|prflx|relay)(?:/(?:udp|tcp|tls))?|unknown)>"
    r"(?:(?:host|srflx|prflx|relay)(?:/(?:udp|tcp|tls))?|unknown)"
)
# Field -> (minimum, maximum). Client-reported, redacted interval statistics.
QUALITY_NUMBERS = {
    "secs": (0, 3600),
    "rtt_ms": (0, 60000),
    "jitter_ms": (0, 60000),
    "loss_in": (0, 100),
    "loss_out": (0, 100),
    "conceal": (0, 100),
    "jb_ms": (0, 60000),
    "rx_pps": (0, 10000),
    "tx_pps": (0, 10000),
    "rx_kbps": (0, 100000),
    "tx_kbps": (0, 100000),
    "mic_db": (-127, 0),
    "spk_db": (-127, 0),
    # Path diagnostics (relay capability "quality_path"): counts only, never
    # addresses. Local/remote candidates by type, IPv6 candidates, and
    # direct (non-TURN) candidate pairs that succeeded or failed their checks.
    "l_host": (0, 1000),
    "l_srflx": (0, 1000),
    "l_relay": (0, 1000),
    "l_v6": (0, 1000),
    "r_host": (0, 1000),
    "r_srflx": (0, 1000),
    "r_prflx": (0, 1000),
    "r_relay": (0, 1000),
    "r_v6": (0, 1000),
    "d_ok": (0, 1000),
    "d_fail": (0, 1000),
    # 1 when the selected route is IPv6; Local Network access 1 on, 0 off.
    "v6": (0, 1),
    "lan": (0, 1),
}
QUALITY_REQUIRED = {"to", "route", "secs", "rx_pps", "tx_pps", "rx_kbps", "tx_kbps", "muted"}
SIGNAL_LIMIT = 32768
SDP_LIMIT = 24000
TRICKLE_ATTRIBUTE = "a=x-canddle-trickle:1"
CANDIDATE_LIMIT = 64
CANDIDATE_FIELDS = (
    "call",
    "revision",
    "epoch",
    "identity",
    "to",
    "description",
    "sequence",
    "mid",
    "index",
    "candidate",
)
TURN_URL = re.compile(
    r"(turns?):([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})"
    r"(?:\?transport=(udp|tcp))?"
)


def signal_fields(message):
    return [message[key] for key in ("call", "revision", "epoch", "identity", "to", "kind", "sdp")]


def description_info(sdp):
    lines = sdp.splitlines()
    mids = [line[6:] for line in lines if line.startswith("a=mid:")]
    trickle = TRICKLE_ATTRIBUTE in lines
    if trickle and (
        lines.count(TRICKLE_ATTRIBUTE) != 1
        or len(mids) != 1
        or not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", mids[0])
    ):
        raise ValueError("Invalid trickle description")
    digest = base64.urlsafe_b64encode(hashlib.sha256(sdp.encode()).digest()).decode().rstrip("=")
    return digest, mids[0] if len(mids) == 1 else None, trickle


def validate_candidate(message):
    if message["index"] != "0" or not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", message["mid"]):
        raise ValueError("Invalid candidate media")
    sequence = int(message["sequence"])
    if str(sequence) != message["sequence"] or not 1 <= sequence <= CANDIDATE_LIMIT + 1:
        raise ValueError("Invalid candidate sequence")
    candidate = message["candidate"]
    # One printable candidate line only, never arbitrary SDP attributes. The
    # authenticated native ICE parser validates the remaining candidate grammar.
    if candidate and (
        len(candidate.encode()) > 2048
        or not all(32 <= ord(c) <= 126 for c in candidate)
        or not re.fullmatch(r"candidate:[A-Za-z0-9+/]+ 1 (?:udp|tcp|UDP|TCP) .+", candidate)
        or sequence > CANDIDATE_LIMIT
    ):
        raise ValueError("Invalid ICE candidate")
    return sequence


def validate_sdp(sdp):
    if not isinstance(sdp, str) or not 1 <= len(sdp.encode()) <= SDP_LIMIT:
        raise ValueError("Invalid SDP size")
    lines = sdp.splitlines()
    media = [line for line in lines if line.startswith("m=")]
    fingerprints = [line for line in lines if line.startswith("a=fingerprint:")]
    if (
        len(media) != 1
        or not re.fullmatch(r"m=audio [0-9]+ UDP/TLS/RTP/SAVPF(?: [0-9]+)+", media[0])
        or len(fingerprints) != 1
        or not re.fullmatch(
            r"a=fingerprint:sha-256 (?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}", fingerprints[0]
        )
        or "a=rtcp-mux" not in lines
        or not any(re.fullmatch(r"a=rtpmap:[0-9]+ opus/48000/2", line) for line in lines)
    ):
        raise ValueError("WebRTC requires fingerprint-authenticated Opus audio")
    description_info(sdp)


def pseudonym(value):
    """Short stable tag for logs; not reversible to the identity or call ID."""
    return hashlib.sha256(value.encode()).hexdigest()[:8]


def parse_quality(raw, sender, members):
    """Validate one rtc-quality ``links`` payload. Raises ValueError when malformed."""
    if not isinstance(raw, str) or len(raw.encode()) > QUALITY_LIMIT:
        raise ValueError("Invalid quality size")
    links = json.loads(raw)
    if not isinstance(links, list) or not 1 <= len(links) <= 5:
        raise ValueError("Invalid quality link count")
    seen = set()
    for link in links:
        if not isinstance(link, dict) or not QUALITY_REQUIRED <= set(link) <= (
            QUALITY_REQUIRED | set(QUALITY_NUMBERS)
        ):
            raise ValueError("Invalid quality fields")
        to = link["to"]
        if not isinstance(to, str) or to == sender or to not in members or to in seen:
            raise ValueError("Invalid quality peer")
        seen.add(to)
        if not isinstance(link["route"], str) or not QUALITY_ROUTE.fullmatch(link["route"]):
            raise ValueError("Invalid quality route")
        if not isinstance(link["muted"], bool):
            raise ValueError("Invalid quality mute flag")
        for key, (low, high) in QUALITY_NUMBERS.items():
            value = link.get(key)
            if value is None and key not in QUALITY_REQUIRED:
                continue
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or not low <= value <= high
            ):
                raise ValueError(f"Invalid quality value {key}")
    return links


def log_quality(call, sender, links):
    for link in links:
        fields = " ".join(
            f"{key}={link[key]}" for key in QUALITY_NUMBERS if link.get(key) is not None
        )
        QUALITY_LOG.info(
            "quality call=%s from=%s to=%s route=%s muted=%s %s",
            pseudonym(call),
            pseudonym(sender),
            pseudonym(link["to"]),
            link["route"],
            int(link["muted"]),
            fields,
        )


@dataclass(frozen=True)
class TURNConfig:
    urls: tuple[str, ...]
    secret: str
    # coturn rejects refreshes once credentials expire, which would cut TURN-relayed
    # calls short. Connected clients are re-issued fresh credentials hourly.
    CREDENTIAL_SECONDS = 86400

    def __post_init__(self):
        if not 1 <= len(self.urls) <= 4 or len(self.secret) < 32:
            raise ValueError("Set 1-4 TURN URLs and a shared secret of at least 32 characters")
        for url in self.urls:
            match = TURN_URL.fullmatch(url)
            if len(url) > 256 or not match or not 1 <= int(match[3]) <= 65535:
                raise ValueError("Invalid TURN URL; use turn:host:port or turns:host:port")
            if match[1] == "turns" and match[4] == "udp":
                raise ValueError("Use TCP transport for TURN over TLS")

    def servers(self, identity, now=None):
        expires = int(time.time() if now is None else now) + self.CREDENTIAL_SECONDS
        username = f"{expires}:{hashlib.sha256(identity.encode()).hexdigest()[:16]}"
        credential = base64.b64encode(
            hmac.digest(self.secret.encode(), username.encode(), "sha1")
        ).decode()
        return [{"urls": list(self.urls), "username": username, "credential": credential}]


def from_environment():
    urls = os.environ.get("VPCOMM_TURN_URLS", "")
    secret = os.environ.get("VPCOMM_TURN_SECRET", "")
    if not urls and not secret:
        return None
    return TURNConfig(tuple(url.strip() for url in urls.split(",")), secret)
