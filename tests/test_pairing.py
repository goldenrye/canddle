import asyncio
import json
import os
import socket
import stat
import sys
import tempfile
from pathlib import Path

import pytest

from vpcomm.pairing import PairingCodes, admin_socket, validate_relay_url
from vpcomm.server import Relay, build_server

TOKEN = "test-permanent-token-" + "a" * 40
PUBLIC = "wss://voice.example.com:8443/relay"


def test_single_use_expiry_and_no_plaintext_storage():
    now = [100.0]
    codes = PairingCodes(PUBLIC, clock=lambda: now[0])
    ticket = codes.create()
    assert TOKEN not in json.dumps(ticket)
    assert ticket["code"].encode() not in codes.codes
    assert codes.redeem(ticket["code"])
    assert not codes.redeem(ticket["code"])
    expired = codes.create()
    now[0] += 120
    assert not codes.redeem(expired["code"])
    assert not codes.redeem("bad")


def test_bounded_codes_and_requests():
    now = [1.0]
    codes = PairingCodes(PUBLIC, capacity=1, clock=lambda: now[0])
    codes.create()
    with pytest.raises(ValueError):
        codes.create()
    assert all(codes.admit() for _ in range(20))
    assert not codes.admit()
    now[0] += 121
    codes.create()
    assert codes.admit()


@pytest.mark.parametrize(
    "url",
    [
        "ws://example.com/relay",
        "wss://user:pw@example.com/relay",
        "wss://example.com/relay?",
        "wss://example.com/relay#",
        "wss://example.com/other",
        "wss://example.com:0/relay",
        "wss://example.com:abc/relay",
        "wss://example.com\\evil/relay",
    ],
)
def test_bad_public_urls(url):
    with pytest.raises(ValueError):
        validate_relay_url(url)


async def get_pair(port, code, *, path="/pair", extra=""):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(
            (
                f"GET {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Pair {code}\r\n"
                f"{extra}Connection: close\r\n\r\n"
            ).encode()
        )
        await writer.drain()
        async with asyncio.timeout(3):
            raw = await reader.read()
        headers, body = raw.split(b"\r\n\r\n", 1)
        return int(headers.split()[1]), headers, body
    finally:
        writer.close()
        await writer.wait_closed()


async def test_http_redemption_concurrent_replay_and_no_cache():
    codes = PairingCodes(PUBLIC)
    relay = Relay(TOKEN, pairing=codes)
    async with build_server(relay, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        code = codes.create()["code"]
        results = await asyncio.gather(get_pair(port, code), get_pair(port, code))
        assert sorted(result[0] for result in results) == [200, 401]
        success = next(result for result in results if result[0] == 200)
        assert json.loads(success[2]) == {"v": 1, "relay": PUBLIC, "token": TOKEN}
        assert b"no-store" in success[1]
        assert b"Access-Control-Allow-Origin" not in success[1]
        assert TOKEN.encode() not in next(result[2] for result in results if result[0] == 401)


async def test_browser_query_websocket_rejected_without_consuming():
    codes = PairingCodes(PUBLIC)
    async with build_server(Relay(TOKEN, pairing=codes), "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        code = codes.create()["code"]
        for extra in [
            "Origin: https://evil.example\r\n",
            "Upgrade: websocket\r\n",
            "Authorization: Pair duplicate\r\n",
        ]:
            status, _, body = await get_pair(port, code, extra=extra)
            assert status == 401 and TOKEN.encode() not in body
        assert (await get_pair(port, code, path="/pair?code=x"))[0] == 404
        assert (await get_pair(port, code))[0] == 200


async def test_disabled_and_rate_limited():
    async with build_server(Relay(TOKEN), "127.0.0.1", 0) as server:
        assert (await get_pair(server.sockets[0].getsockname()[1], "x"))[0] == 404
    codes = PairingCodes(PUBLIC)
    codes.allowance = 0
    async with build_server(Relay(TOKEN, pairing=codes), "127.0.0.1", 0) as server:
        assert (await get_pair(server.sockets[0].getsockname()[1], "x"))[0] == 429


@pytest.fixture
def short_directory():
    # macOS Unix-domain socket paths are limited to roughly 104 bytes.
    with tempfile.TemporaryDirectory(prefix="vpp-", dir="/tmp") as name:
        yield Path(name)


async def test_admin_socket_create_revoke_permissions_and_cleanup(short_directory):
    directory = short_directory
    path = directory / "admin.sock"
    codes = PairingCodes(PUBLIC)
    async with admin_socket(codes, str(path)):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600

        async def command(action):
            reader, writer = await asyncio.open_unix_connection(path)
            writer.write(json.dumps({"action": action}).encode() + b"\n")
            await writer.drain()
            result = json.loads(await reader.readline())
            writer.close()
            await writer.wait_closed()
            return result

        ticket = await command("create")
        assert ticket["relay"] == PUBLIC
        assert await command("revoke") == {"revoked": True}
        assert not codes.redeem(ticket["code"])
        assert "error" in await command("unknown")
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "vpcomm.pairing",
            "--socket",
            str(path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        output, errors = await process.communicate()
        assert process.returncode == 0, errors
        assert b"Scan in Canddle" in output and b"single use" in output
        assert TOKEN.encode() not in output
    assert not path.exists()
    assert not codes.codes
    os.chmod(directory, 0o755)
    with pytest.raises(ValueError, match="mode 700"):
        async with admin_socket(codes, str(path)):
            pass


async def test_stale_socket_recovery_and_active_socket_preserved(short_directory):
    path = short_directory / "admin.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
        stale.bind(str(path))
    codes = PairingCodes(PUBLIC)
    async with admin_socket(codes, str(path)):
        with pytest.raises(ValueError, match="already using"):
            async with admin_socket(codes, str(path)):
                pass
        assert path.exists()
