"""Ephemeral pairing, administered only through a private local Unix socket."""

import argparse
import asyncio
import hashlib
import json
import os
import secrets
import socket
import stat
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlsplit

from .crypto import decode

DEFAULT_SOCKET = "/run/vpcomm/admin.sock"


def validate_relay_url(url: str) -> str:
    parts = urlsplit(url)
    if (
        len(url) > 256
        or not url.isascii()
        or any(ord(char) <= 32 or ord(char) == 127 for char in url)
        or parts.scheme != "wss"
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.path != "/relay"
        or "?" in url
        or "#" in url
        or "\\" in url
        or (parts.port is not None and not 1 <= parts.port <= 65535)
    ):
        raise ValueError("Set the exact public wss://host[:port]/relay URL")
    return url


class PairingCodes:
    def __init__(self, relay_url: str, *, lifetime=120, capacity=16, clock=time.monotonic):
        self.relay_url = validate_relay_url(relay_url)
        if not 1 <= lifetime <= 120 or not 1 <= capacity <= 16:
            raise ValueError("Invalid pairing limits")
        self.lifetime = lifetime
        self.capacity = capacity
        self.clock = clock
        self.codes: dict[bytes, float] = {}
        self.allowance = 20.0
        self.last_request = clock()

    def create(self) -> dict:
        now = self.clock()
        self.codes = {key: expiry for key, expiry in self.codes.items() if expiry > now}
        if len(self.codes) >= self.capacity:
            raise ValueError("Pairing capacity reached; revoke outstanding codes or wait")
        code = secrets.token_urlsafe(32)
        self.codes[hashlib.sha256(code.encode("ascii")).digest()] = now + self.lifetime
        return {"type": "vpcomm-pair", "v": 1, "relay": self.relay_url, "code": code}

    def admit(self) -> bool:
        now = self.clock()
        self.allowance = min(20.0, self.allowance + (now - self.last_request) * 2)
        self.last_request = now
        if self.allowance < 1:
            return False
        self.allowance -= 1
        return True

    def redeem(self, code: str) -> bool:
        try:
            decode(code, 32)
        except ValueError:
            return False
        digest = hashlib.sha256(code.encode("ascii")).digest()
        # No await between lookup and removal: simultaneous redemptions have one winner.
        expiry = self.codes.pop(digest, 0)
        return expiry > self.clock()


@asynccontextmanager
async def admin_socket(codes: PairingCodes, filename: str):
    path = Path(filename)
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o077:
        raise ValueError("Pairing socket parent must be owned by the relay user with mode 700")
    if path.exists() or path.is_symlink():
        existing = path.lstat()
        if not stat.S_ISSOCK(existing.st_mode) or existing.st_uid != os.getuid():
            raise ValueError("Refusing to replace a non-socket or foreign admin path")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.2)
            try:
                probe.connect(str(path))
            except ConnectionRefusedError:
                if path.lstat().st_ino == existing.st_ino:
                    path.unlink()
            else:
                raise ValueError("Another relay is already using the pairing socket")
    active = 0

    async def handle(reader, writer):
        nonlocal active
        admitted = active < 4
        if admitted:
            active += 1
        try:
            if not admitted:
                return
            async with asyncio.timeout(3):
                request = json.loads(await reader.readline())
                if request == {"action": "create"}:
                    response = codes.create()
                elif request == {"action": "revoke"}:
                    codes.codes.clear()
                    response = {"revoked": True}
                else:
                    raise ValueError("Invalid admin command")
                writer.write(json.dumps(response, separators=(",", ":")).encode() + b"\n")
                await writer.drain()
        except (ValueError, TimeoutError, ConnectionError):
            writer.write(b'{"error":"Admin request failed; check capacity or syntax"}\n')
        finally:
            if admitted:
                active -= 1
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    server = await asyncio.start_unix_server(handle, path=path, limit=256, start_serving=False)
    os.chmod(path, 0o600)
    inode = path.stat().st_ino
    try:
        async with server:
            await server.start_serving()
            yield
    finally:
        # Never remove a replacement socket belonging to another process.
        if path.exists() and path.stat().st_ino == inode:
            path.unlink()
        codes.codes.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=os.environ.get("VPCOMM_PAIRING_SOCKET", DEFAULT_SOCKET))
    parser.add_argument("--revoke", action="store_true", help="Invalidate all unused pairing codes")
    parser.add_argument(
        "--json", action="store_true", help="Print sensitive pairing payload, not QR"
    )
    args = parser.parse_args()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(args.socket)
            action = "revoke" if args.revoke else "create"
            client.sendall(json.dumps({"action": action}).encode() + b"\n")
            with client.makefile("rb") as stream:
                response = json.loads(stream.readline(2048))
        if "error" in response:
            parser.exit(1, response["error"] + "\n")
        if args.revoke:
            print("Unused pairing codes revoked.")
        elif args.json:
            print(json.dumps(response, separators=(",", ":")))
        else:
            import qrcode

            qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=4)
            qr.add_data(json.dumps(response, separators=(",", ":")))
            qr.make(fit=True)
            print("Scan in Canddle > Pair with QR. Expires in 2 minutes; single use.")
            print("Keep this screen private. Anyone scanning first can obtain relay access.")
            qr.print_ascii(out=sys.stdout, invert=True)
    except (OSError, ValueError):
        parser.exit(
            1, "Pairing unavailable. Check server pairing settings and local socket access.\n"
        )


if __name__ == "__main__":
    main()
