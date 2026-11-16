"""Bounded WebRTC signaling and short-lived coturn REST credentials."""

import base64
import hashlib
import hmac
import os
import re
import time
from dataclasses import dataclass

SIGNAL_LIMIT = 32768
SDP_LIMIT = 24000
TURN_URL = re.compile(
    r"(turns?):([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})"
    r"(?:\?transport=(udp|tcp))?"
)


def signal_fields(message):
    return [message[key] for key in ("call", "revision", "epoch", "identity", "to", "kind", "sdp")]


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


@dataclass(frozen=True)
class TURNConfig:
    urls: tuple[str, ...]
    secret: str

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
        expires = int(time.time() if now is None else now) + 7200
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
