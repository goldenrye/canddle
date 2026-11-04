import asyncio
import json
from types import SimpleNamespace
from unittest.mock import Mock

from test_group_server import client, group_server, roster
from test_lobby import Device, recv, send

from vpcomm.group import GroupLobby
from vpcomm.lobby import Peer


async def presence(socket, expected):
    async with asyncio.timeout(3):
        while True:
            message = await recv(socket)
            if message["type"] == "presence":
                entries = json.loads(message["members"])
                states = {identity: state for identity, _, state in entries}
                if all(states.get(key) == value for key, value in expected.items()):
                    return entries


async def test_presence_lifecycle_and_legacy_clients():
    async with group_server() as (group, url), client(url) as (a, alice):
        assert group.challenge("nonce")["presence"] == "1"
        await send(a, {"type": "presence-subscribe"})
        await presence(a, {alice.identity: "online"})
        async with client(url) as (b, bob):
            entries = await presence(a, {bob.identity: "online"})
            assert [bob.identity, bob.name, "online"] in entries
            # Unsubscribed clients still receive exactly the old protocol.
            await send(b, {"type": "ping"})
            await recv(b, "pong")
            offer = alice.offer()
            await send(a, offer)
            await recv(b, "offer")
            await presence(a, {alice.identity: "calling"})
            request = bob.request(offer)
            await send(b, request)
            await presence(a, {bob.identity: "joining"})
            await send(b, {
                "type": "confirm", "call": offer["call"], "request": request["request"],
                "proof": request["ephemeral"],
            })
            await recv(a, "confirm")
            await send(a, roster(alice, offer, [offer, request]))
            await recv(b, "roster")
            await presence(a, {alice.identity: "in-call", bob.identity: "in-call"})
            await send(b, {"type": "leave", "call": offer["call"]})
            await recv(b, "closed")
            await presence(a, {bob.identity: "online"})
        await presence(a, {bob.identity: None})
        await send(a, {"type": "cancel", "call": offer["call"]})
        await presence(a, {alice.identity: "online"})
    await asyncio.sleep(0)
    assert not group.presence_subscribers


async def test_presence_request_expiry():
    async with group_server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer = alice.offer()
        await send(a, offer)
        await recv(a, "offer")
        await recv(b, "offer")
        group.lifetime = 0.1
        await send(a, {"type": "presence-subscribe"})
        await presence(a, {bob.identity: "online"})
        await send(b, bob.request(offer))
        await presence(a, {bob.identity: "joining"})
        await presence(a, {bob.identity: "online"})


async def test_presence_snapshot_is_bounded_coalesced_and_only_sent_on_change():
    group = GroupLobby()
    for _ in range(40):
        device = Device('"' * 40)
        peer = Peer(SimpleNamespace(transport=Mock()), device.identity, device.name)
        group.peers[peer.identity] = peer
    subscriber = next(iter(group.peers.values()))
    group.dispatch(subscriber, {"type": "presence-subscribe"})
    for _ in range(20):
        group.presence_changed()
    await asyncio.sleep(0)
    message = subscriber.queue.get_nowait()
    assert len(json.dumps(message).encode()) <= 8192
    assert len(json.loads(message["members"])) == 32
    assert message["truncated"] == "yes"
    group.presence_changed()
    await asyncio.sleep(0)
    assert subscriber.queue.empty()
    assert all(peer.queue.empty() for peer in group.peers.values())
