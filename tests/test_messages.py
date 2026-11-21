import json
import secrets
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from test_lobby import TOKEN, Device

from vpcomm.crypto import decode, encode
from vpcomm.lobby import Peer, transcript, verify
from vpcomm.messages import FIELDS, RECEIPT, TTL, Messages
from vpcomm.push import APNs

SCOPE = "wss://chat.example/relay"


def agreement(device):
    secret = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"vpcomm/chat/v1",
        info=transcript("chat-agreement", SCOPE),
    ).derive(device.key.private_bytes_raw())
    return X25519PrivateKey.from_private_bytes(secret)


def bundle(device):
    key = encode(agreement(device).public_key().public_bytes_raw())
    return device.signed(
        "chat-key",
        [device.identity, SCOPE, key],
        {"type": "chat-key", "identity": device.identity, "scope": SCOPE, "key": key},
    )


def envelope(sender, recipient, text="Can you call me?", created=None):
    ephemeral = X25519PrivateKey.generate()
    public = bundle(recipient)["key"]
    message = {
        "type": "chat-send",
        "id": encode(secrets.token_bytes(16)),
        "from": sender.identity,
        "to": recipient.identity,
        "scope": SCOPE,
        "key": public,
        "ephemeral": encode(ephemeral.public_key().public_bytes_raw()),
        "created": str(int(time.time()) if created is None else created),
    }
    aad = transcript("chat-encryption", *(message[k] for k in FIELDS[:-1]))
    shared = ephemeral.exchange(X25519PublicKey.from_public_bytes(decode(public, 32)))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"vpcomm/chat/v1", info=aad).derive(
        shared
    )
    nonce = secrets.token_bytes(12)
    message["body"] = encode(nonce + AESGCM(key).encrypt(nonce, text.encode(), aad))
    return sender.signed("chat-message", [message[k] for k in FIELDS], message)


def receipt(device, message):
    result = {"type": "chat-receipt", **{key: message[key] for key in RECEIPT}}
    return device.signed("chat-receipt", [message[key] for key in RECEIPT], result)


def output(peer):
    result = []
    while not peer.queue.empty():
        result.append(peer.queue.get_nowait())
    return result


@pytest.fixture
def setup(tmp_path):
    store = Messages(str(tmp_path / "messages.sqlite"), TOKEN)
    devices = [Device() for _ in range(3)]
    peers = {
        d.identity: Peer(SimpleNamespace(transport=Mock()), d.identity, d.name) for d in devices
    }
    for device in devices:
        peer = peers[device.identity]
        store.dispatch(peer, bundle(device), peers)
        store.dispatch(
            peer,
            {
                "type": "chat-allow",
                "identities": json.dumps([other.identity for other in devices if other != device]),
            },
            peers,
        )
        output(peer)
    yield store, devices, peers
    store.db.close()


def test_durable_ciphertext_dedupe_signed_receipt_and_private_routing(setup):
    store, (alice, bob, eve), peers = setup
    message = envelope(alice, bob)
    a, b, e = (peers[d.identity] for d in (alice, bob, eve))
    store.dispatch(a, message, peers)
    assert output(a)[0]["type"] == "chat-stored"
    assert output(b) == [message]
    assert output(e) == []
    row = store.db.execute("SELECT envelope FROM chat_messages").fetchone()[0]
    assert "Can you call me?" not in row
    store.dispatch(a, message, peers)
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 1
    output(a)
    signed = receipt(bob, message)
    store.dispatch(b, signed, peers)
    assert output(a) == [signed]
    assert store.db.execute("SELECT envelope FROM chat_messages").fetchone()[0] is None
    store.dispatch(a, message, peers)
    assert output(a) == [
        signed,
        {"type": "chat-stored", "scope": SCOPE, "id": message["id"], "to": bob.identity},
    ]


@pytest.mark.parametrize("field", [*FIELDS, "signature"])
def test_tampered_envelope_never_forwarded_and_does_not_abort_call(setup, field):
    store, (alice, bob, _), peers = setup
    message = envelope(alice, bob)
    message[field] = "invalid"
    a, b = peers[alice.identity], peers[bob.identity]
    store.dispatch(a, message, peers)
    assert output(a)[0]["type"] == "chat-error"
    assert output(b) == []
    a.socket.transport.abort.assert_not_called()
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 0


def test_unverified_recipient_and_forged_receipts_rejected(setup):
    store, (alice, bob, eve), peers = setup
    a, b, e = (peers[d.identity] for d in (alice, bob, eve))
    message = envelope(alice, bob)
    store.dispatch(a, message, peers)
    output(a)
    output(b)
    store.dispatch(e, receipt(eve, message), peers)
    assert output(e)[0]["type"] == "chat-error"
    assert store.db.execute("SELECT envelope FROM chat_messages").fetchone()[0]
    store.dispatch(b, {"type": "chat-allow", "identities": "[]"}, peers)
    store.dispatch(a, {"type": "chat-key-get", "to": bob.identity}, peers)
    assert output(a) == [{"type": "chat-unavailable", "to": bob.identity}]
    store.dispatch(a, envelope(alice, bob), peers)
    assert output(a)[0]["type"] == "chat-error"


def test_expiry_and_conflicting_id_rejected(setup):
    store, (alice, bob, _), peers = setup
    a = peers[alice.identity]
    for created in [int(time.time()) - TTL - 10, int(time.time()) + 1000]:
        store.dispatch(a, envelope(alice, bob, created=created), peers)
        assert output(a)[0]["type"] == "chat-error"
    first = envelope(alice, bob)
    store.dispatch(a, first, peers)
    output(a)
    conflict = envelope(alice, bob, "Another message")
    conflict["id"] = first["id"]
    conflict = alice.signed("chat-message", [conflict[k] for k in FIELDS], conflict)
    store.dispatch(a, conflict, peers)
    assert output(a)[0]["type"] == "chat-error"


def test_restart_offline_delivery_and_namespace_rotation(tmp_path):
    path = str(tmp_path / "chat.sqlite")
    alice, bob = Device(), Device()
    store = Messages(path, TOKEN)
    a = Peer(SimpleNamespace(transport=Mock()), alice.identity, alice.name)
    b = Peer(SimpleNamespace(transport=Mock()), bob.identity, bob.name)
    for peer, device in [(a, alice), (b, bob)]:
        store.dispatch(peer, bundle(device), {})
        store.dispatch(
            peer,
            {"type": "chat-allow", "identities": json.dumps([alice.identity, bob.identity])},
            {},
        )
        output(peer)
    message = envelope(alice, bob)
    store.dispatch(a, message, {})
    store.db.close()
    store = Messages(path, TOKEN)
    store.dispatch(b, bundle(bob), {})
    output(b)
    store.dispatch(b, {"type": "chat-pull"}, {})
    assert output(b) == [message]
    store.db.close()
    assert (tmp_path / "chat.sqlite").stat().st_mode & 0o777 == 0o600
    store = Messages(path, TOKEN + "new-group")
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 0
    assert store.db.execute("SELECT COUNT(*) FROM chat_keys").fetchone()[0] == 0
    store.db.close()


def test_bounded_chat_queue_does_not_overflow_call_signaling(setup):
    store, (alice, bob, _), peers = setup
    a, b = peers[alice.identity], peers[bob.identity]
    for _ in range(48):
        b.queue.put_nowait({"type": "call-control"})
    store.dispatch(a, envelope(alice, bob), peers)
    assert b.queue.qsize() == 48
    b.socket.transport.abort.assert_not_called()
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 1
    a.chat_allowance = 0
    store.dispatch(a, envelope(alice, bob), peers)
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 1


async def test_alert_push_uses_regular_topic_and_contains_no_message_text():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    from vpcomm.push import Device as PushDevice

    key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    client = SimpleNamespace(post=AsyncMock(return_value=SimpleNamespace(status_code=200)))
    apns = APNs(key, "A" * 10, "B" * 10, "com.jpi.canddle", client)
    assert await apns.send_message(
        PushDevice("recipient", "a" * 64, "production", SCOPE, time.time())
    )
    kwargs = client.post.call_args.kwargs
    assert kwargs["headers"]["apns-push-type"] == "alert"
    assert kwargs["headers"]["apns-topic"] == "com.jpi.canddle"
    assert set(kwargs["json"]) == {"aps", "canddle_message"}
    assert "badge" not in kwargs["json"]["aps"]
    assert "offer" not in kwargs["json"]


def test_receipt_signature_uses_recipient_identity():
    alice, bob = Device(), Device()
    message = envelope(alice, bob)
    signed = receipt(bob, message)
    verify(
        bob.identity, signed["signature"], transcript("chat-receipt", *(signed[k] for k in RECEIPT))
    )
    with pytest.raises(ValueError):
        verify(
            alice.identity,
            signed["signature"],
            transcript("chat-receipt", *(signed[k] for k in RECEIPT)),
        )


def test_unacknowledged_messages_do_not_starve_newer_delivery(setup):
    store, (alice, bob, _), peers = setup
    a, b = peers[alice.identity], peers[bob.identity]
    sent = [envelope(alice, bob, f"Message {index}") for index in range(12)]
    for message in sent:
        store.dispatch(a, message, {})
    received = set()
    for _ in range(3):
        store.dispatch(b, {"type": "chat-pull"}, {})
        batch = output(b)
        assert len(batch) == 5
        received.update(message["id"] for message in batch)
    assert received == {message["id"] for message in sent}


def test_revoking_trust_removes_pending_ciphertext(setup):
    store, (alice, bob, eve), peers = setup
    a, b, e = (peers[d.identity] for d in (alice, bob, eve))
    store.dispatch(a, envelope(alice, bob), {})
    retained = envelope(eve, bob)
    store.dispatch(e, retained, {})
    store.dispatch(b, {"type": "chat-allow", "identities": json.dumps([eve.identity])}, {})
    store.dispatch(b, {"type": "chat-pull"}, {})
    assert output(b) == [retained]


def test_pending_mailbox_capacity_fails_without_disconnect(setup):
    store, (alice, bob, _), peers = setup
    a = peers[alice.identity]
    for _ in range(200):
        a.chat_allowance = 40
        store.dispatch(a, envelope(alice, bob), {})
        assert output(a)[0]["type"] == "chat-stored"
    store.dispatch(a, envelope(alice, bob), {})
    assert output(a)[0]["type"] == "chat-error"
    a.socket.transport.abort.assert_not_called()


async def test_idle_expiry_cleanup_and_push_revocation(tmp_path, monkeypatch):
    import asyncio

    store = Messages(str(tmp_path / "chat.sqlite"), TOKEN)
    alice, bob = Device(), Device()
    peers = {
        d.identity: Peer(SimpleNamespace(transport=Mock()), d.identity, d.name)
        for d in (alice, bob)
    }
    for device in (alice, bob):
        store.dispatch(peers[device.identity], bundle(device), peers)
    store.dispatch(
        peers[bob.identity],
        {"type": "chat-allow", "identities": json.dumps([alice.identity])},
        peers,
    )
    store.dispatch(peers[alice.identity], envelope(alice, bob), peers)
    store.dispatch(
        peers[bob.identity],
        {"type": "chat-push", "token": "a" * 64, "environment": "production"},
        peers,
    )
    store.revoke_push(bob.identity)
    assert (
        store.db.execute(
            "SELECT token FROM chat_keys WHERE identity=?", (bob.identity,)
        ).fetchone()[0]
        == ""
    )
    future = time.time() + TTL + 60
    monkeypatch.setattr("vpcomm.messages.time.time", lambda: future)
    store.start()
    await asyncio.sleep(0)
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 0
    await store.close()


def test_invalid_token_does_not_erase_existing_namespace(tmp_path):
    path = str(tmp_path / "chat.sqlite")
    store = Messages(path, TOKEN)
    original = store.db.execute("SELECT value FROM namespace").fetchone()[0]
    store.db.close()
    with pytest.raises(ValueError):
        Messages(path, "short")
    store = Messages(path, TOKEN)
    assert store.db.execute("SELECT value FROM namespace").fetchone()[0] == original
    store.db.close()


def test_push_token_cannot_be_claimed_by_another_identity(setup):
    store, (alice, bob, _), peers = setup
    frame = {"type": "chat-push", "token": "b" * 64, "environment": "development"}
    store.dispatch(peers[alice.identity], frame, peers)
    store.dispatch(peers[bob.identity], frame, peers)
    assert output(peers[bob.identity])[0]["type"] == "chat-error"
    assert store.db.execute(
        "SELECT identity FROM chat_keys WHERE token=?", (frame["token"],)
    ).fetchall() == [(alice.identity,)]
    store.db.execute(
        "UPDATE chat_keys SET updated=? WHERE identity=?",
        (time.time() - TTL - 1, alice.identity),
    )
    store.db.commit()
    store.dispatch(peers[bob.identity], frame, peers)
    assert output(peers[bob.identity]) == []
    assert store.db.execute(
        "SELECT identity FROM chat_keys WHERE token=?", (frame["token"],)
    ).fetchall() == [(bob.identity,)]


@pytest.mark.parametrize("tampered", [False, True])
async def test_signed_control_revokes_message_alerts_without_lobby_session(setup, tampered):
    from test_lobby import recv, send
    from websockets.asyncio.client import connect
    from websockets.exceptions import ConnectionClosed

    from vpcomm.server import Relay, build_server

    store, (alice, _, _), peers = setup
    store.dispatch(
        peers[alice.identity],
        {"type": "chat-push", "token": "c" * 64, "environment": "development"},
        peers,
    )
    relay = Relay(TOKEN, messages=store)
    async with build_server(relay, "127.0.0.1", 0) as server:
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
        async with connect(
            url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
        ) as socket:
            await send(socket, {"v": 2, "push": True})
            challenge = await recv(socket, "challenge")
            registration = alice.registration(challenge["challenge"])
            if tampered:
                registration["signature"] = Device().registration(challenge["challenge"])[
                    "signature"
                ]
            await send(socket, registration)
            if tampered:
                with pytest.raises(ConnectionClosed):
                    await socket.recv()
            else:
                await recv(socket, "online")
                await send(socket, {"type": "push-unregister"})
                await recv(socket, "push-unregistered")
    token = store.db.execute(
        "SELECT token FROM chat_keys WHERE identity=?", (alice.identity,)
    ).fetchone()[0]
    assert token == ("c" * 64 if tampered else "")
