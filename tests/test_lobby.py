import asyncio
import json
import secrets
from contextlib import AsyncExitStack, asynccontextmanager
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import encode
from vpcomm.lobby import Peer, offer_fields, request_fields, transcript
from vpcomm.server import Relay, build_server

TOKEN = "lobby-tests-" + "a" * 40


class Device:
    def __init__(self, name="Phone"):
        self.key = Ed25519PrivateKey.generate()
        self.identity = encode(self.key.public_key().public_bytes_raw())
        self.name = name

    def signed(self, purpose, fields, message):
        return {**message, "signature": encode(self.key.sign(transcript(purpose, *fields)))}

    def registration(self, challenge):
        return self.signed(
            "register",
            [challenge, self.identity, self.name],
            {"type": "register", "identity": self.identity, "name": self.name},
        )

    def offer(self):
        message = {
            "type": "offer",
            "call": encode(secrets.token_bytes(16)),
            "identity": self.identity,
            "ephemeral": encode(secrets.token_bytes(32)),
            "name": self.name,
        }
        return self.signed("offer", offer_fields(message), message)

    def request(self, offer):
        message = {
            "type": "request",
            "call": offer["call"],
            "request": encode(secrets.token_bytes(16)),
            "identity": self.identity,
            "ephemeral": encode(secrets.token_bytes(32)),
            "name": self.name,
        }
        return self.signed("request", request_fields(offer, message), message)


async def send(socket, message):
    await socket.send(json.dumps(message))


async def recv(socket, kind=None):
    async with asyncio.timeout(2):
        message = json.loads(await socket.recv())
    if kind:
        assert message["type"] == kind
    return message


@asynccontextmanager
async def server(lifetime=120, capacity=32):
    relay = Relay(TOKEN, max_connections=capacity)
    relay.lobby.lifetime = lifetime
    async with build_server(relay, "127.0.0.1", 0) as running:
        yield relay, f"ws://127.0.0.1:{running.sockets[0].getsockname()[1]}/relay"
    assert not relay.lobby.peers
    assert not relay.lobby.offers
    assert not relay.connections


@asynccontextmanager
async def client(url, device=None):
    device = device or Device()
    async with connect(
        url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
    ) as socket:
        await send(socket, {"v": 1, "lobby": True})
        challenge = await recv(socket, "challenge")
        await send(socket, device.registration(challenge["challenge"]))
        await recv(socket, "online")
        yield socket, device


async def announce(a, b, owner):
    offer = owner.offer()
    await send(a, offer)
    assert await recv(a, "offer") == offer
    assert await recv(b, "offer") == offer
    return offer


async def request(a, b, requester, offer, confirm=True):
    message = requester.request(offer)
    await send(b, message)
    assert await recv(a, "request") == message
    if confirm:
        proof = {
            "type": "confirm",
            "call": offer["call"],
            "request": message["request"],
            "proof": encode(secrets.token_bytes(32)),
        }
        await send(b, proof)
        assert await recv(a, "confirm") == proof
    return message


def approval(offer, request):
    return {
        "type": "approve",
        "call": offer["call"],
        "request": request["request"],
        "box": encode(secrets.token_bytes(98)),
    }


async def test_approval_single_winner_and_no_invitation_broadcast():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        async with client(url) as (c, charlie):
            offer = await announce(a, b, alice)
            assert await recv(c, "offer") == offer
            one = await request(a, b, bob, offer)
            two = await request(a, c, charlie, offer)
            message = approval(offer, one)
            await send(a, message)
            await send(a, approval(offer, two))
            assert await recv(b, "approve") == message
            await recv(a, "granted")
            for socket in (a, b, c):
                await recv(socket, "closed")
            await recv(a, "closed")
            await send(c, {"type": "ping"})
            await recv(c, "pong")


async def test_late_arrival_gets_offer_and_owner_disconnect_removes_it():
    async with server() as (_, url), client(url) as (a, alice):
        offer = alice.offer()
        await send(a, offer)
        await recv(a, "offer")
        async with client(url) as (b, _):
            assert await recv(b, "offer") == offer
            await a.close()
            await recv(b, "closed")


@pytest.mark.parametrize("action", ["withdraw", "reject", "disconnect"])
async def test_request_removal(action):
    async with server() as (relay, url), client(url) as (a, alice), client(url) as (b, bob):
        offer = await announce(a, b, alice)
        message = await request(a, b, bob, offer, confirm=False)
        if action == "disconnect":
            await b.close()
        else:
            await send(
                b if action == "withdraw" else a,
                {"type": action, "call": offer["call"], "request": message["request"]},
            )
            await recv(b, "removed")
        await recv(a, "removed")
        assert not relay.lobby.offers[offer["call"]].requests


async def test_expiry_cleans_requests():
    async with server(lifetime=0.2) as (relay, url):
        async with client(url) as (a, alice), client(url) as (b, bob):
            offer = await announce(a, b, alice)
            await request(a, b, bob, offer, confirm=False)
            assert (await recv(a, "closed"))["reason"] == "expired"
            await recv(b, "closed")
            assert not relay.lobby.offers
            assert all(p.offer is None and p.request is None for p in relay.lobby.peers.values())


@pytest.mark.parametrize("action", ["approve", "cancel", "reject"])
async def test_non_owner_cannot_approve_cancel_or_reject(action):
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer = await announce(a, b, alice)
        message = await request(a, b, bob, offer)
        payload = approval(offer, message)
        payload["type"] = action
        if action != "approve":
            payload.pop("box")
        if action == "cancel":
            payload.pop("request")
        await send(b, payload)
        with pytest.raises(ConnectionClosed):
            await b.recv()


async def test_cannot_approve_without_requester_confirmation():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer = await announce(a, b, alice)
        message = await request(a, b, bob, offer, confirm=False)
        await send(a, approval(offer, message))
        with pytest.raises(ConnectionClosed):
            await a.recv()
        await recv(b, "closed")


@pytest.mark.parametrize("field", ["identity", "ephemeral", "name", "call", "signature"])
async def test_tampered_offer_rejected(field):
    async with server() as (_, url), client(url) as (a, alice):
        offer = alice.offer()
        offer[field] = Device().offer()[field]
        if field == "name":
            offer[field] = "Impostor"
        await send(a, offer)
        with pytest.raises(ConnectionClosed):
            await a.recv()


async def test_signed_request_cannot_move_between_offers():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer = await announce(a, b, alice)
        message = bob.request(alice.offer())
        message["call"] = offer["call"]
        await send(b, message)
        with pytest.raises(ConnectionClosed):
            await b.recv()


async def test_registration_replay_challenge_and_duplicate_identity():
    async with server() as (_, url), client(url) as (_, alice):
        for replay in (False, True):
            async with connect(
                url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
            ) as socket:
                await send(socket, {"v": 1, "lobby": True})
                challenge = (await recv(socket, "challenge"))["challenge"]
                await send(
                    socket,
                    alice.registration(encode(secrets.token_bytes(32)) if replay else challenge),
                )
                with pytest.raises(ConnectionClosed):
                    await socket.recv()


@pytest.mark.parametrize("payload", [[], {"type": "ping", "x": "extra"}, {"type": 1}, "x" * 1025])
async def test_malformed_messages(payload):
    async with server() as (_, url), client(url) as (a, _):
        await send(a, payload)
        with pytest.raises(ConnectionClosed):
            await a.recv()


async def test_flood_is_bounded():
    async with server() as (_, url), client(url) as (a, _):
        for _ in range(20):
            try:
                await send(a, {"type": "ping"})
            except ConnectionClosed:
                break
        async with asyncio.timeout(4):
            with pytest.raises(ConnectionClosed):
                while True:
                    await a.recv()
        assert a.close_code == 1008


async def test_lobby_uses_shared_connection_limit():
    async with server(capacity=2) as (_, url), client(url), client(url):
        async with connect(
            url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
        ) as extra:
            with pytest.raises(ConnectionClosed):
                await extra.recv()


async def test_request_capacity_and_session_expiry():
    async with server() as (relay, url), client(url) as (a, alice), AsyncExitStack() as stack:
        offer = alice.offer()
        await send(a, offer)
        await recv(a, "offer")
        for _ in range(16):
            b, bob = await stack.enter_async_context(client(url))
            await recv(b, "offer")
            await request(a, b, bob, offer, confirm=False)
        async with client(url) as (extra, device):
            await recv(extra, "offer")
            await send(extra, device.request(offer))
            with pytest.raises(ConnectionClosed):
                await extra.recv()
        assert len(relay.lobby.offers[offer["call"]].requests) == 16
        relay.lobby.session_lifetime = 0.05
        async with client(url) as (short, _):
            await recv(short, "offer")
            with pytest.raises(ConnectionClosed):
                await short.recv()


def test_slow_peer_queue_is_bounded():
    transport = Mock()
    peer = Peer(SimpleNamespace(transport=transport), "key", "Phone")
    for _ in range(65):
        peer.emit({"type": "pong"})
    assert peer.queue.qsize() == 64
    transport.abort.assert_called_once()
