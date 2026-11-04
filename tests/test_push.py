import asyncio
import base64
import json
import time
from unittest.mock import AsyncMock

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from test_group_server import client
from test_lobby import TOKEN, Device, recv, send
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from vpcomm.push import RETENTION, APNs, PushDevices, PushService
from vpcomm.server import Relay, build_server

SCOPE = "wss://voice.example.com/relay"
PUSH_TOKEN = "a" * 64


def test_registration_rotation_expiry_capacity_and_revoke(tmp_path):
    path = str(tmp_path / "push.sqlite")
    store = PushDevices(path, TOKEN, limit=1)
    store.register("one", PUSH_TOKEN, "development", SCOPE)
    assert not store.recipients("one")
    with pytest.raises(ValueError):
        store.register("two", "b" * 64, "production", SCOPE)
    original = store.recipients("other")[0]
    store.register("one", "b" * 64, "production", SCOPE)
    assert not store.current(original)
    store.remove("one", PUSH_TOKEN)
    assert len(store.recipients("other")) == 1
    store.close()
    store = PushDevices(path, TOKEN, limit=1)
    assert store.recipients("other")[0].environment == "production"
    store.db.execute("UPDATE devices SET updated=?", (time.time() - RETENTION - 1,))
    store.db.commit()
    assert not store.recipients("other")
    store.register("two", PUSH_TOKEN, "development", SCOPE)
    store.close()
    assert (tmp_path / "push.sqlite").stat().st_mode & 0o777 == 0o600
    store = PushDevices(path, TOKEN + "-rotated")
    assert not store.recipients("other")
    store.close()


@pytest.mark.parametrize(
    "token,environment,scope",
    [
        ("not-hex", "development", SCOPE),
        ("a" * 65, "development", SCOPE),
        (PUSH_TOKEN, "other", SCOPE),
        (PUSH_TOKEN, "production", "http://evil.example/relay"),
        (PUSH_TOKEN, "production", "wss://user:password@voice.example/relay"),
        (PUSH_TOKEN, "production", SCOPE + "?secret=x"),
    ],
)
def test_invalid_registration(token, environment, scope):
    store = PushDevices(":memory:", TOKEN)
    with pytest.raises(ValueError):
        store.register("one", token, environment, scope)
    store.close()


def test_cannot_replace_another_device_token():
    store = PushDevices(":memory:", TOKEN)
    store.register("one", PUSH_TOKEN, "development", SCOPE)
    with pytest.raises(ValueError):
        store.register("two", PUSH_TOKEN, "development", SCOPE)
    assert store.recipients("other")[0].identity == "one"
    store.close()


async def test_authenticated_registration_offline_delivery_and_unregister():
    sender = AsyncMock()
    sender.send.return_value = True
    push = PushService(PushDevices(":memory:", TOKEN), sender)
    push.start()
    relay = Relay(TOKEN, push=push)
    try:
        async with build_server(relay, "127.0.0.1", 0) as server:
            url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
            async with client(url) as (receiver, device):
                await send(receiver, {"type": "push-capabilities"})
                assert (await recv(receiver, "push-capabilities"))["enabled"] == "yes"
                registration = {
                    "type": "push-register",
                    "token": PUSH_TOKEN,
                    "environment": "development",
                    "scope": SCOPE,
                }
                await send(receiver, registration)
                await recv(receiver, "push-registered")
                assert push.devices.recipients("other")[0].identity == device.identity
            async with client(url) as (caller, caller_device):
                offer = caller_device.offer()
                await send(caller, offer)
                await recv(caller, "offer")
                await asyncio.wait_for(push.queue.join(), 2)
                sender.send.assert_awaited_once()
                target, sent_offer, expires = sender.send.call_args.args
                assert target.identity == device.identity
                assert sent_offer == offer
                assert time.time() < expires <= time.time() + 30
                # Registration cannot choose another identity.
                await send(caller, {**registration, "identity": device.identity})
                with pytest.raises(ConnectionClosed):
                    await caller.recv()
            async with client(url) as (socket, new_device):
                await send(
                    socket,
                    {
                        "type": "push-register",
                        "token": "b" * 64,
                        "environment": "production",
                        "scope": SCOPE,
                    },
                )
                await recv(socket, "push-registered")
                await send(socket, {"type": "push-unregister"})
                await recv(socket, "push-unregistered")
                assert all(d.identity != new_device.identity for d in push.devices.recipients(""))
    finally:
        await push.close()


async def test_cancelled_expired_revoked_and_throttled_pushes():
    store = PushDevices(":memory:", TOKEN)
    store.register("receiver", PUSH_TOKEN, "development", SCOPE)
    sender = AsyncMock()
    sender.send.return_value = True
    service = PushService(store, sender)
    caller = Device()
    offer = caller.offer()
    service.announce(offer, lambda: False)
    service.announce(caller.offer(), lambda: True)
    assert service.queue.qsize() == 1  # caller ringing rate limit
    service.start()
    await asyncio.wait_for(service.queue.join(), 2)
    sender.send.assert_not_awaited()
    device = store.recipients("caller")[0]
    service.queue.put_nowait((device, offer, int(time.time()) - 1, lambda: True))
    service.queue.put_nowait((device, offer, int(time.time()) + 30, lambda: True))
    store.remove(device.identity)
    await asyncio.wait_for(service.queue.join(), 2)
    sender.send.assert_not_awaited()
    store.register("receiver", PUSH_TOKEN, "development", SCOPE)
    device = store.recipients("caller")[0]
    sender.send.return_value = False
    service.queue.put_nowait((device, offer, int(time.time()) + 30, lambda: True))
    await asyncio.wait_for(service.queue.join(), 2)
    assert not store.recipients("caller")
    await service.close()


async def test_individual_push_notifies_only_selected_device():
    from test_direct_calls import direct_offer

    store = PushDevices(":memory:", TOKEN)
    caller, target, bystander = Device(), Device(), Device()
    store.register(target.identity, PUSH_TOKEN, "development", SCOPE)
    store.register(bystander.identity, "b" * 64, "production", SCOPE)
    sender = AsyncMock()
    sender.send.return_value = True
    service = PushService(store, sender)
    service.start()
    try:
        offer = direct_offer(caller, target.identity)
        service.announce(offer, lambda: True)
        await asyncio.wait_for(service.queue.join(), 2)
        sender.send.assert_awaited_once()
        device, sent_offer, _ = sender.send.call_args.args
        assert device.identity == target.identity
        assert sent_offer == offer
    finally:
        await service.close()


@pytest.mark.parametrize(
    "environment,host",
    [
        ("development", "api.sandbox.push.apple.com"),
        ("production", "api.push.apple.com"),
    ],
)
async def test_apns_headers_payload_and_es256_signature(environment, host):
    private = ec.generate_private_key(ec.SECP256R1())
    key = private.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    store = PushDevices(":memory:", TOKEN)
    store.register("receiver", PUSH_TOKEN, environment, SCOPE)
    device = store.recipients("caller")[0]
    offer = Device().offer()
    requests = []

    async def handle(request):
        requests.append(request)
        return httpx.Response(200)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handle))
    apns = APNs(key, "A123456789", "B123456789", "org.example.canddle", http)
    expires = int(time.time()) + 30
    assert await apns.send(device, offer, expires)
    request = requests[0]
    assert request.url.host == host
    assert request.headers["apns-topic"] == "org.example.canddle.voip"
    assert request.headers["apns-push-type"] == "voip"
    assert request.headers["apns-priority"] == "10"
    assert request.headers["apns-expiration"] == "0"
    payload = json.loads(request.content)
    assert payload == {
        "aps": {},
        "v": 1,
        "offer": offer,
        "scope": SCOPE,
        "recipient": "receiver",
        "expires": expires,
    }
    jwt = request.headers["authorization"].removeprefix("bearer ")
    header, claims, signature = jwt.split(".")
    sig = base64.urlsafe_b64decode(signature + "==")
    private.public_key().verify(
        encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")),
        (header + "." + claims).encode(),
        ec.ECDSA(hashes.SHA256()),
    )
    assert json.loads(base64.urlsafe_b64decode(claims + "=="))["iss"] == "B123456789"
    assert apns.authorization() == "bearer " + jwt
    await apns.close()
    store.close()


@pytest.mark.parametrize(
    "status,reason,keep",
    [
        (410, "Unregistered", False),
        (400, "BadDeviceToken", False),
        (403, "InvalidProviderToken", True),
        (429, "TooManyRequests", True),
    ],
)
async def test_apns_rejection_policy(status, reason, keep):
    key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    http = httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda request: httpx.Response(status, json={"reason": reason})
        )
    )
    store = PushDevices(":memory:", TOKEN)
    store.register("receiver", PUSH_TOKEN, "development", SCOPE)
    apns = APNs(key, "A123456789", "B123456789", "org.example.canddle", http)
    assert await apns.send(store.recipients("caller")[0], Device().offer(), 0) is keep
    await apns.close()
    store.close()


@pytest.mark.parametrize("tampered", [False, True])
async def test_independent_signed_revocation(tampered):
    store = PushDevices(":memory:", TOKEN)
    owner = Device()
    store.register(owner.identity, PUSH_TOKEN, "development", SCOPE)
    service = PushService(store, AsyncMock())
    relay = Relay(TOKEN, push=service)
    async with build_server(relay, "127.0.0.1", 0) as server:
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
        async with connect(
            url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
        ) as socket:
            await send(socket, {"v": 2, "push": True})
            challenge = await recv(socket, "challenge")
            hello = owner.registration(challenge["challenge"])
            if tampered:
                hello["signature"] = Device().registration(challenge["challenge"])["signature"]
            await send(socket, hello)
            if tampered:
                with pytest.raises(ConnectionClosed):
                    await socket.recv()
                assert store.recipients("other")
            else:
                await recv(socket, "online")
                await send(socket, {"type": "push-unregister"})
                await recv(socket, "push-unregistered")
                assert not store.recipients("other")
    assert not relay.connections
    await service.close()
