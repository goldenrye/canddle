import asyncio
import json
import os

import pytest

from vpcomm.messages import Messages
from vpcomm.server import Relay, build_server

PROBE = os.environ.get("VPCOMM_MESSAGES_PROBE")
pytestmark = pytest.mark.skipif(not PROBE, reason="Compile MessageChecks.swift")
TOKEN = "native-message-test-" + "a" * 40


async def run_probe(config, *args):
    process = await asyncio.create_subprocess_exec(
        PROBE,
        *args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        async with asyncio.timeout(80):
            output, error = await process.communicate(json.dumps(config).encode())
        assert process.returncode == 0, output.decode() + error.decode()
        return output.decode()
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


@pytest.mark.parametrize("enabled,photos", [(False, False), (True, False), (True, True)])
async def test_native_private_messaging_and_call_coexistence(tmp_path, enabled, photos):
    messages = Messages(str(tmp_path / "queue.sqlite"), TOKEN) if enabled else None
    relay = Relay(TOKEN, messages=messages)
    try:
        async with build_server(relay, "127.0.0.1", 0) as server:
            address = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
            output = await run_probe(
                dict(address=address, token=TOKEN, enabled=enabled, photos=photos)
            )
            assert output.strip() == "PASS native private messaging"
        if messages:
            rows = messages.db.execute("SELECT envelope, receipt FROM chat_messages").fetchall()
            assert len(rows) == 2
            assert all(envelope is None and receipt for envelope, receipt in rows)
            assert messages.db.execute("SELECT DISTINCT kind FROM chat_messages").fetchall() == [
                ("photo" if photos else "text",)
            ]
            badges = messages.db.execute("SELECT count FROM chat_badges ORDER BY count").fetchall()
            assert badges == [(0,), (2,)]  # Sender has none; recipient has two unread.
    finally:
        if messages:
            await messages.close()


async def test_native_encryption_and_protected_history():
    assert "PASS message crypto" in await run_probe({}, "unit")


async def test_python_swift_message_crypto_interoperability():
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from test_lobby import Device
    from test_messages import agreement, bundle, envelope

    from vpcomm.crypto import decode, encode
    from vpcomm.lobby import transcript, verify
    from vpcomm.messages import FIELDS, RECEIPT

    alice, bob = Device(), Device()
    sent = envelope(alice, bob, "Private text from Python")
    output = json.loads(
        await run_probe(
            {
                "message": sent,
                "bundle": bundle(alice),
                "secret": encode(bob.key.private_bytes_raw()),
            },
            "interop",
        )
    )
    assert output["text"] == "Private text from Python"
    receipt = output["receipt"]
    verify(
        bob.identity,
        receipt["signature"],
        transcript("chat-receipt", *(receipt[k] for k in RECEIPT)),
    )
    reply = output["reply"]
    verify(
        bob.identity, reply["signature"], transcript("chat-message", *(reply[k] for k in FIELDS))
    )
    metadata = transcript("chat-encryption", *(reply[k] for k in FIELDS[:-1]))
    shared = agreement(alice).exchange(
        X25519PublicKey.from_public_bytes(decode(reply["ephemeral"], 32))
    )
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"vpcomm/chat/v1", info=metadata).derive(
        shared
    )
    body = decode(reply["body"], len(reply["body"]) * 6 // 8)
    assert AESGCM(key).decrypt(body[:12], body[12:], metadata) == b"Reply from Swift"
