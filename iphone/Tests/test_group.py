import asyncio
import base64
import json
import os

import pytest
from test_interop import tls_fixture

from vpcomm.server import Relay, build_server
from vpcomm.webrtc import TURNConfig

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
        "legacy-presence",
        "rename-directory",
        "quiet-presence",
        "auto-enabled",
        "auto-disabled",
        "auto-unverified",
        "auto-other-relay",
        "auto-unconfirmed",
        "auto-batch",
        "auto-ignore",
        "auto-reject",
        "direct-verified",
        "direct-unverified",
        "direct-decline",
        "direct-lock-decline",
        "direct-disconnect",
        "rtc-group",
        "rtc-direct",
        "rtc-mixed",
        "rtc-no-trickle",
        "rtc-no-recovery",
        "rtc-handoff",
        "rtc-handoff-abort",
        "rtc-handoff-direct",
        "rtc-handoff-direct-hangup",
        "rtc-handoff-direct-online-hangup",
        "rtc-handoff-direct-timeout",
        "rtc-handoff-direct-untrusted",
        "rtc-legacy-relay",
        "rtc-legacy-cold-start",
        "rtc-legacy-direct",
        "profiles",
        "profiles-old",
        "ringback",
        "missed-cancel",
        "missed-cancel-away",
        "missed-timeout",
        "missed-group-timeout",
        "callback",
        "callback-old",
    ],
)
async def test_native_group(mode, tmp_path):
    turn = (
        TURNConfig(("turn:turn.example:3478",), "test-only-secret-" * 3)
        if mode.startswith("rtc-") and not mode.startswith("rtc-legacy-")
        else None
    )
    relay = Relay(TOKEN, turn=turn)
    if mode == "callback-old":
        original_challenge = relay.group.challenge
        relay.group.challenge = lambda nonce: {
            key: value for key, value in original_challenge(nonce).items() if key != "direct"
        }
    if mode == "profiles-old":
        original_challenge = relay.group.challenge
        relay.group.challenge = lambda nonce: {
            key: value for key, value in original_challenge(nonce).items() if key != "profiles"
        }
    if mode == "rtc-handoff-direct-timeout":
        relay.group.request_refresh = lambda call: None
    if mode == "rtc-handoff-direct-untrusted":
        original_connected = relay.group.connected_peer

        def untrusted_snapshot(peer):
            if peer.resumed:
                stored = relay.group.roster_messages[peer.joined]
                relay.group.roster_messages[peer.joined] = {**stored, "signature": "invalid"}
            original_connected(peer)

        relay.group.connected_peer = untrusted_snapshot
    if mode == "rtc-handoff-abort":
        original_candidate = relay.group.rtc_candidate

        def drop_established_socket(peer, message):
            original_candidate(peer, message)
            call = message["call"]
            streams = relay.group.rtc_candidates.get(call, {})
            if len(streams) == 30 and all(ended for _, ended in streams.values()):
                relay.group.rtc_candidate = original_candidate
                # Let the client consume the final candidates before dropping TCP.
                asyncio.get_running_loop().call_later(
                    0.1, relay.group.offers[call].owner.socket.transport.abort
                )

        relay.group.rtc_candidate = drop_established_socket
    if mode == "rtc-handoff-direct-hangup":
        # Hangup before the new socket opens cannot reach the relay; grace expiry
        # cleans up the other endpoint, and the local client must never reconnect.
        relay.group.RESUME_SECONDS = 0.25
    if mode == "quiet-presence":
        original_publish = relay.group.publish_presence

        def repeated_presence():
            original_publish()
            for peer, message in list(relay.group.presence_subscribers.items()):
                if message:
                    for _ in range(3):
                        peer.emit(message)
                    # A changed flag confirms the native client consumed all duplicates.
                    peer.emit({**message, "truncated": "yes"})

        relay.group.publish_presence = repeated_presence
    if mode == "rtc-no-trickle":
        original_challenge = relay.group.challenge
        relay.group.challenge = lambda nonce: {
            key: value for key, value in original_challenge(nonce).items() if key != "trickle"
        }
    if mode == "rtc-no-recovery":
        original_challenge = relay.group.challenge
        relay.group.challenge = lambda nonce: {
            key: value for key, value in original_challenge(nonce).items() if key != "recovery"
        }
    if mode == "legacy-presence":
        relay.group.challenge = lambda nonce: {"type": "challenge", "challenge": nonce}
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
            async with asyncio.timeout(45 if mode.endswith("timeout") else 25):
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
