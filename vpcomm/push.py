"""Optional, bounded APNs VoIP delivery. Never log tokens, payloads or signing keys."""

import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

LOG = logging.getLogger("vpcomm.push")
TOKEN = re.compile(r"[0-9a-f]{64,256}")
RETENTION = 7 * 86400


@dataclass(frozen=True)
class Device:
    identity: str
    token: str
    environment: str
    scope: str
    updated: float


class PushDevices:
    """One endpoint per authenticated device key; bounded, expiring, local storage."""

    def __init__(self, path, access_token, limit=128):
        self.limit = limit
        if path != ":memory:":
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            os.close(fd)
            os.chmod(path, 0o600)
        self.db = sqlite3.connect(path)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS devices "
            "(identity TEXT PRIMARY KEY, token TEXT UNIQUE, environment TEXT, scope TEXT, "
            "updated REAL, namespace TEXT)"
        )
        self.namespace = hashlib.sha256(access_token.encode()).hexdigest()
        # Rotating the relay credential also revokes registrations from the old group.
        self.db.execute("DELETE FROM devices WHERE namespace != ?", (self.namespace,))
        self.db.commit()

    def register(self, identity, token, environment, scope):
        parts = urlsplit(scope)
        if (
            not TOKEN.fullmatch(token)
            or len(token) % 2
            or environment not in {"development", "production"}
            or len(scope) > 256
            or parts.scheme != "wss"
            or not parts.hostname
            or parts.username is not None
            or parts.password is not None
            or parts.path != "/relay"
            or parts.query
            or parts.fragment
        ):
            raise ValueError("Invalid push registration")
        now = time.time()
        self.db.execute("DELETE FROM devices WHERE updated < ?", (now - RETENTION,))
        existing = self.db.execute(
            "SELECT identity FROM devices WHERE identity = ?", (identity,)
        ).fetchone()
        count = self.db.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
        if not existing and count >= self.limit:
            raise ValueError("Push registration capacity")
        try:
            with self.db:
                self.db.execute(
                    "INSERT INTO devices VALUES (?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(identity) DO UPDATE SET token=excluded.token, "
                    "environment=excluded.environment, scope=excluded.scope, "
                    "updated=excluded.updated",
                    (identity, token, environment, scope, now, self.namespace),
                )
        except sqlite3.IntegrityError as error:
            raise ValueError("Push token already registered") from error

    def remove(self, identity, token=None):
        with self.db:
            if token is None:
                self.db.execute("DELETE FROM devices WHERE identity = ?", (identity,))
            else:
                self.db.execute(
                    "DELETE FROM devices WHERE identity = ? AND token = ?", (identity, token)
                )

    def recipients(self, caller):
        rows = self.db.execute(
            "SELECT identity, token, environment, scope, updated FROM devices "
            "WHERE identity != ? AND updated >= ?",
            (caller, time.time() - RETENTION),
        )
        return [Device(*row) for row in rows]

    def current(self, device):
        return (
            self.db.execute(
                "SELECT 1 FROM devices WHERE identity=? AND token=? AND updated=?",
                (device.identity, device.token, device.updated),
            ).fetchone()
            is not None
        )

    def close(self):
        self.db.close()


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class APNs:
    def __init__(self, key, key_id, team_id, bundle_id, client=None):
        if not all(re.fullmatch(r"[A-Za-z0-9]{10}", value) for value in (key_id, team_id)):
            raise ValueError("APNs key/team IDs must have 10 alphanumeric characters")
        if not re.fullmatch(r"[A-Za-z0-9.-]{3,200}", bundle_id):
            raise ValueError("Invalid APNs bundle ID")
        self.key = serialization.load_pem_private_key(key, password=None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(
            self.key.curve, ec.SECP256R1
        ):
            raise ValueError("APNs requires an ES256 .p8 key")
        self.key_id, self.team_id, self.topic = key_id, team_id, bundle_id + ".voip"
        if client is None:
            import httpx

            client = httpx.AsyncClient(
                http2=True,
                timeout=5,
                trust_env=False,
                follow_redirects=False,
                limits=httpx.Limits(max_connections=2),
            )
        self.client = client
        self.jwt = ""
        self.issued = 0

    def authorization(self):
        now = int(time.time())
        if not self.jwt or not 0 <= now - self.issued < 3000:
            header = b64(json.dumps({"alg": "ES256", "kid": self.key_id}).encode())
            claims = b64(json.dumps({"iss": self.team_id, "iat": now}).encode())
            unsigned = f"{header}.{claims}"
            r, s = decode_dss_signature(self.key.sign(unsigned.encode(), ec.ECDSA(hashes.SHA256())))
            self.jwt = unsigned + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
            self.issued = now
        return "bearer " + self.jwt

    async def send(self, device, offer, expires):
        host = (
            "api.sandbox.push.apple.com"
            if device.environment == "development"
            else ("api.push.apple.com")
        )
        response = await self.client.post(
            f"https://{host}/3/device/{device.token}",
            headers={
                "authorization": self.authorization(),
                "apns-topic": self.topic,
                "apns-push-type": "voip",
                "apns-priority": "10",
                "apns-expiration": "0",  # Never store a call for later delivery.
            },
            json={
                "aps": {},
                "v": 1,
                "offer": offer,
                "scope": device.scope,
                "recipient": device.identity,
                "expires": expires,
            },
        )
        if response.status_code == 200:
            return True
        reason = response.json().get("reason", "") if response.content else ""
        if response.status_code == 410 or reason in {"BadDeviceToken", "Unregistered"}:
            return False
        # No response body/URL logging: they can contain device credentials.
        LOG.warning("APNs rejected a VoIP delivery (HTTP %s)", response.status_code)
        return True

    async def close(self):
        await self.client.aclose()


class PushService:
    def __init__(self, devices, sender):
        self.devices, self.sender = devices, sender
        self.queue = asyncio.Queue(maxsize=128)
        self.workers = []
        self.last_call = {}

    def start(self):
        self.workers = [asyncio.create_task(self.run()) for _ in range(2)]

    def announce(self, offer, available):
        now = time.time()
        self.last_call = {key: stamp for key, stamp in self.last_call.items() if stamp > now - 30}
        caller = offer["identity"]
        # Bound ringing separately from the socket control-frame allowance.
        if caller in self.last_call or len(self.last_call) >= 128:
            return
        self.last_call[caller] = now
        for device in self.devices.recipients(caller):
            if offer.get("target") is not None and device.identity != offer["target"]:
                continue
            try:
                self.queue.put_nowait((device, dict(offer), int(now + 30), available))
            except asyncio.QueueFull:
                LOG.warning("VoIP delivery queue full")
                break

    async def run(self):
        while True:
            device, offer, expires, available = await self.queue.get()
            try:
                if time.time() >= expires or not available() or not self.devices.current(device):
                    continue
                if not await self.sender.send(device, offer, expires):
                    self.devices.remove(device.identity, device.token)
            except Exception:
                LOG.warning("VoIP delivery failed; no automatic retry")
            finally:
                self.queue.task_done()

    async def close(self):
        for worker in self.workers:
            worker.cancel()
        await asyncio.gather(*self.workers, return_exceptions=True)
        await self.sender.close()
        self.devices.close()


def from_environment(access_token):
    names = (
        "VPCOMM_APNS_KEY_FILE",
        "VPCOMM_APNS_KEY_ID",
        "VPCOMM_APNS_TEAM_ID",
        "VPCOMM_APNS_BUNDLE_ID",
        "VPCOMM_PUSH_DB",
    )
    values = [os.environ.get(name, "") for name in names]
    if not any(values):
        return None
    if not all(values):
        raise ValueError("Set all five APNs/push environment variables to enable VoIP push")
    key_file, key_id, team_id, bundle_id, database = values
    sender = APNs(Path(key_file).read_bytes(), key_id, team_id, bundle_id)
    return PushService(PushDevices(database, access_token), sender)
