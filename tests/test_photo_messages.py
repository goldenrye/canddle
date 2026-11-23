import json

import pytest
from test_lobby import TOKEN, Device, recv, send
from test_messages import SCOPE, bundle, envelope, output, receipt
from test_messages import setup as setup
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from vpcomm.messages import FIELDS, PHOTO_BYTES, PHOTO_FRAME_LIMIT, Messages
from vpcomm.server import Relay, build_server


def photo_bundle(device):
    message = {**bundle(device), "type": "chat-photo-key"}
    return device.signed("chat-photo-key",
                         [message[k] for k in ("identity", "scope", "key")], message)


def enable_photos(store, devices, peers):
    for device in devices:
        store.dispatch(peers[device.identity], photo_bundle(device), peers)
        assert output(peers[device.identity]) == [{"type": "chat-photo-ready"}]


def test_photo_capability_preserves_text_and_requires_a_signed_opt_in(setup):
    store, (alice, bob, eve), peers = setup
    a = peers[alice.identity]
    request = {"type": "chat-photo-key-get", "to": bob.identity}
    store.dispatch(a, request, peers)
    assert output(a)[0]["type"] == "chat-photo-unavailable"
    bad = {**photo_bundle(bob), "signature": bundle(bob)["signature"]}
    store.dispatch(peers[bob.identity], bad, peers)
    assert output(peers[bob.identity])[0]["type"] == "chat-error"
    enable_photos(store, [alice, bob, eve], peers)
    store.dispatch(a, request, peers)
    assert output(a) == [photo_bundle(bob)]
    store.dispatch(a, {"type": "chat-key-get", "to": bob.identity}, peers)
    assert output(a) == [bundle(bob)]
    store.dispatch(peers[bob.identity], bundle(bob), peers)  # Downgrade clears opt-in.
    output(peers[bob.identity])
    store.dispatch(a, request, peers)
    assert output(a)[0]["type"] == "chat-photo-unavailable"


def test_photo_is_one_private_offline_message_never_on_call_socket(setup):
    store, devices, peers = setup
    alice, bob, _ = devices
    enable_photos(store, devices, peers)
    a, b = peers[alice.identity], peers[bob.identity]
    message = envelope(alice, bob, b"private-image" * 8000, photos=True)
    store.dispatch(a, message, peers)  # Large data must use the isolated transport.
    assert output(a)[0]["type"] == "chat-error"
    store.dispatch(a, message, peers, photos=True)
    assert output(a)[0]["type"] == "chat-stored"
    assert output(b) == []
    store.dispatch(b, {"type": "chat-pull"}, peers)
    assert output(b) == []
    store.dispatch(b, {"type": "chat-badge", "count": "2", "receipts": "[]"}, peers)
    assert store.badge_count(SCOPE, bob.identity) == 3
    store.dispatch(b, {"type": "chat-photo-pull"}, peers, photos=True)
    assert output(b) == [message]
    store.dispatch(a, message, peers, photos=True)
    output(a)
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 1
    store.dispatch(b, receipt(bob, message), peers)
    assert output(a) == [receipt(bob, message)]
    store.dispatch(a, {"type": "chat-photo-status", "id": message["id"], "to": bob.identity},
                   peers, photos=True)
    assert output(a) == [receipt(bob, message)]
    assert store.badge_count(SCOPE, bob.identity) == 2
    assert store.db.execute("SELECT envelope FROM chat_messages").fetchone()[0] is None


@pytest.mark.parametrize("field", [*FIELDS, "signature", "type"])
def test_photo_tampering_and_type_confusion_are_rejected(setup, field):
    store, devices, peers = setup
    alice, bob, _ = devices
    enable_photos(store, devices, peers)
    message = envelope(alice, bob, b"pixels", photos=True)
    message[field] = "chat-send" if field == "type" else "tampered"
    store.dispatch(peers[alice.identity], message, peers, photos=True)
    assert output(peers[alice.identity])[0]["type"] == "chat-error"
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 0
    peers[alice.identity].socket.transport.abort.assert_not_called()


@pytest.mark.parametrize("size,accepted", [(PHOTO_BYTES, True), (PHOTO_BYTES + 1, False)])
def test_photo_ciphertext_bounds(setup, size, accepted):
    store, devices, peers = setup
    alice, bob, _ = devices
    enable_photos(store, devices, peers)
    message = envelope(alice, bob, b"x" * size, photos=True)
    store.dispatch(peers[alice.identity], message, peers, photos=True)
    assert output(peers[alice.identity])[0]["type"] == ("chat-stored" if accepted else "chat-error")
    if accepted:
        assert len(json.dumps(message).encode()) < PHOTO_FRAME_LIMIT


@pytest.mark.parametrize("limit", ["MAILBOX_BYTES", "TOTAL_BYTES"])
def test_photo_byte_quota_rejects_without_disconnecting(setup, monkeypatch, limit):
    store, devices, peers = setup
    alice, bob, _ = devices
    enable_photos(store, devices, peers)
    message = envelope(alice, bob, b"x" * 5000, photos=True)
    monkeypatch.setattr(f"vpcomm.messages.{limit}", len(json.dumps(message)) + 100)
    store.dispatch(peers[alice.identity], message, peers, photos=True)
    assert output(peers[alice.identity])[0]["type"] == "chat-stored"
    store.dispatch(peers[alice.identity], envelope(alice, bob, b"x" * 5000, photos=True),
                   peers, photos=True)
    assert output(peers[alice.identity])[0]["type"] == "chat-error"
    assert store.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0] == 1
    peers[alice.identity].socket.transport.abort.assert_not_called()


def test_photo_restart_rotation_revocation_and_status_privacy(setup):
    store, devices, peers = setup
    alice, bob, eve = devices
    enable_photos(store, devices, peers)
    sent = [envelope(alice, bob, f"photo-{index}", photos=True) for index in range(3)]
    for message in sent:
        store.dispatch(peers[alice.identity], message, {}, photos=True)
    path = store.db.execute("PRAGMA database_list").fetchone()[2]
    reopened = Messages(path, TOKEN)
    try:
        seen = set()
        for _ in range(3):
            reopened.dispatch(peers[bob.identity], {"type": "chat-photo-pull"}, {}, photos=True)
            seen.add(output(peers[bob.identity])[0]["id"])
        assert seen == {message["id"] for message in sent}
        reopened.dispatch(peers[eve.identity],
                          {"type": "chat-photo-status", "id": sent[0]["id"], "to": bob.identity},
                          {}, photos=True)
        assert output(peers[eve.identity])[0]["type"] == "chat-error"
        reopened.dispatch(peers[bob.identity], {"type": "chat-allow", "identities": "[]"}, {})
        reopened.dispatch(peers[bob.identity], {"type": "chat-photo-pull"}, {}, photos=True)
        assert output(peers[bob.identity]) == [{"type": "chat-photo-empty"}]
    finally:
        reopened.db.close()


async def photo_register(socket, device, *, tamper=False):
    await send(socket, {"v": 2, "photos": True})
    challenge = await recv(socket, "challenge")
    registration = device.signed(
        "chat-photo-session", [challenge["challenge"], device.identity, SCOPE],
        {"type": "photo-register", "identity": device.identity, "scope": SCOPE},
    )
    if tamper:
        registration["signature"] = Device().registration(challenge["challenge"])["signature"]
    await send(socket, registration)


@pytest.mark.parametrize("tamper", [False, True])
async def test_isolated_photo_session_authentication_and_call_liveness(setup, tamper):
    store, devices, peers = setup
    alice, bob, _ = devices
    enable_photos(store, devices, peers)
    relay = Relay(TOKEN, messages=store)
    async with build_server(relay, "127.0.0.1", 0) as server:
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
        headers = {"Authorization": f"Bearer {TOKEN}"}
        async with connect(url, additional_headers=headers, proxy=None) as call:
            await send(call, {"v": 2, "group": True})
            challenge = await recv(call, "challenge")
            await send(call, alice.registration(challenge["challenge"]))
            await recv(call, "online")
            original = relay.group.peers[alice.identity]
            async with connect(url, additional_headers=headers, proxy=None,
                               max_size=PHOTO_FRAME_LIMIT) as photo:
                await photo_register(photo, alice, tamper=tamper)
                if tamper:
                    with pytest.raises(ConnectionClosed):
                        await photo.recv()
                else:
                    await recv(photo, "photo-online")
                    # A half-finished transfer must not obstruct or replace call control.
                    await send(call, {"type": "ping"})
                    await recv(call, "pong")
                    message = envelope(alice, bob, b"x" * PHOTO_BYTES, photos=True)
                    await send(photo, message)
                    await recv(photo, "chat-stored")
            assert relay.group.peers[alice.identity] is original
            await send(call, {"type": "ping"})
            await recv(call, "pong")
    assert not store.photo_sessions


async def test_photo_session_cancellation_cannot_close_call_socket(setup):
    store, devices, peers = setup
    alice, _, _ = devices
    enable_photos(store, devices, peers)
    relay = Relay(TOKEN, messages=store)
    async with build_server(relay, "127.0.0.1", 0) as server:
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
        headers = {"Authorization": f"Bearer {TOKEN}"}
        async with connect(url, additional_headers=headers, proxy=None) as call:
            await send(call, {"v": 2, "group": True})
            challenge = await recv(call, "challenge")
            await send(call, alice.registration(challenge["challenge"]))
            await recv(call, "online")
            async with connect(url, additional_headers=headers, proxy=None) as photo:
                await photo_register(photo, alice)
                await recv(photo, "photo-online")
                photo.transport.abort()
            await send(call, {"type": "ping"})
            await recv(call, "pong")
    assert not store.photo_sessions
