import asyncio
import base64
import json
import os

import pytest
from test_interop import tls_fixture

from vpcomm.server import Relay, build_server

PROBE = os.environ.get("VPCOMM_GROUP_PROBE")
pytestmark = pytest.mark.skipif(not PROBE, reason="Compile GroupChecks.swift")
TOKEN = "group-test-" + "a" * 40


@pytest.mark.parametrize(
    "mode",
    [
        "lifecycle",
        "streaming",
        "disconnect",
        "cancel",
        "capacity",
        "reject",
        "ignore",
        "save-failure",
        "caller-save-failure",
        "tls",
    ],
)
async def test_native_group(mode, tmp_path):
    relay = Relay(TOKEN)
    relay.group.lifetime = 1.5 if mode == "ignore" else 120
    context, root = tls_fixture(tmp_path) if mode == "tls" else (None, None)
    if context:
        from websockets.asyncio.server import serve

        server_context = serve(
            relay.handle,
            "127.0.0.1",
            0,
            ssl=context,
            process_request=relay.authorize,
            max_size=8192,
            compression=None,
        )
    else:
        server_context = build_server(relay, "127.0.0.1", 0)
    async with server_context as server:
        config = {
            "address": f"{'wss' if context else 'ws'}://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay",
            "token": TOKEN,
            "mode": mode,
            "root": base64.b64encode(root.read_bytes()).decode() if root else None,
        }
        process = await asyncio.create_subprocess_exec(
            PROBE,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            async with asyncio.timeout(25):
                output, error = await process.communicate(json.dumps(config).encode())
            assert process.returncode == 0, output.decode() + error.decode()
            assert output.decode().strip() == f"PASS group {mode}"
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
    assert not relay.group.peers
    assert not relay.group.offers
    assert not relay.group.members
    assert not relay.group.request_timers
