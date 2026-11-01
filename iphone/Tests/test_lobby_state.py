"""Native observable-store lifecycle tests with injected in-memory storage."""

import asyncio
import json
import os

import pytest

from vpcomm.server import Relay, build_server

PROBE = os.environ.get("VPCOMM_LOBBY_STORE_PROBE")
pytestmark = pytest.mark.skipif(not PROBE, reason="Compile the native lobby store probe")
TOKEN = "lobby-store-test-" + "a" * 40


@pytest.mark.parametrize(
    "mode",
    [
        "approve",
        "cancel",
        "reject",
        "disconnect",
        "expire",
        "caller-save-failure",
        "requester-save-failure",
    ],
)
async def test_native_lobby_store(mode):
    relay = Relay(TOKEN)
    relay.lobby.lifetime = 0.5 if mode == "expire" else 120
    async with build_server(relay, "127.0.0.1", 0) as server:
        process = await asyncio.create_subprocess_exec(
            PROBE,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        config = {
            "address": f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay",
            "token": TOKEN,
            "mode": mode,
        }
        try:
            async with asyncio.timeout(15):
                output, error = await process.communicate(json.dumps(config).encode())
            assert process.returncode == 0, error.decode() + output.decode()
            assert output.decode().strip() == f"PASS lobby state {mode}"
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
    assert not relay.lobby.peers
    assert not relay.lobby.offers
