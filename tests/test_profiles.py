import asyncio
import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from test_group_server import client, group_server
from test_lobby import Device, recv, send
from test_recovery import recovery, resume, snapshot
from test_webrtc import admit, server
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import encode
from vpcomm.group import GroupLobby
from vpcomm.lobby import Peer


def profile(device, photo=b"\xff\xd8\xff\xd9", revision="1"):
    raw = encode(photo)
    return device.signed("device-profile", [device.identity, revision, raw], {
        "type": "profile", "identity": device.identity, "revision": revision, "photo": raw,
    })


async def sync(socket):
    await send(socket, {"type": "ping"})
    await recv(socket, "pong")


async def test_profile_publication_update_removal_and_legacy_isolation():
    async with group_server() as (group, url), client(url) as (a, alice), client(url) as (b, _):
        assert group.challenge("nonce")["profiles"] == "1"
        first = profile(alice)
        await send(a, first)
        await sync(a)
        await sync(b)  # No photo until explicitly subscribed.
        await send(b, {"type": "profile-subscribe"})
        assert await recv(b, "profile") == first
        await send(a, first)
        await sync(a)
        await sync(b)  # Duplicate does not republish.
        second = profile(alice, b"\xff\xd8custom\xff\xd9", "2")
        await send(a, second)
        assert await recv(b, "profile") == second
        removed = profile(alice, b"", "3")
        await send(a, removed)
        assert await recv(b, "profile") == removed
        await a.close()
        await sync(b)
        assert alice.identity not in group.peers


@pytest.mark.parametrize("field", ["identity", "photo", "revision", "signature", "extra"])
async def test_profile_tampering_rejected(field):
    async with group_server() as (_, url), client(url) as (a, alice):
        forged = profile(alice)
        forged[field] = "invalid"
        await send(a, forged)
        with pytest.raises(ConnectionClosed):
            await a.recv()


@pytest.mark.parametrize("photo,revision", [
    (b"not-jpeg", "1"), (b"\xff\xd8" + b"x" * 5117 + b"\xff\xd9", "1"),
    (b"", "0"), (b"", "-1"), (b"", "01"), (b"", str(1 << 64)),
])
async def test_signed_invalid_profile_is_rejected(photo, revision):
    async with group_server() as (_, url), client(url) as (a, alice):
        await send(a, profile(alice, photo, revision))
        with pytest.raises(ConnectionClosed):
            await a.recv()


async def test_another_device_cannot_publish_your_photo():
    async with group_server() as (_, url), client(url) as (a, _), client(url) as (_, bob):
        await send(a, profile(bob))
        with pytest.raises(ConnectionClosed):
            await a.recv()


@pytest.mark.parametrize("revision", ["1", "2"])
async def test_profile_rollback_and_conflicting_revision_rejected(revision):
    async with group_server() as (_, url), client(url) as (a, alice):
        await send(a, profile(alice, revision="2"))
        await sync(a)
        await send(a, profile(alice, b"", revision))
        with pytest.raises(ConnectionClosed):
            await a.recv()


async def test_profile_snapshot_memory_frames_and_rate_are_bounded():
    group = GroupLobby()
    for _ in range(40):
        device = Device()
        peer = Peer(SimpleNamespace(transport=Mock()), device.identity, device.name)
        peer.profile = profile(device, b"\xff\xd8" + b"x" * 5116 + b"\xff\xd9")
        group.peers[device.identity] = peer
    subscriber = next(iter(group.peers.values()))
    group.dispatch(subscriber, {"type": "profile-subscribe"})
    await asyncio.sleep(0)
    assert subscriber.queue.qsize() == 32
    assert len(subscriber.profile_seen) == 32
    while not subscriber.queue.empty():
        assert len(json.dumps(subscriber.queue.get_nowait()).encode()) <= 8192
    group.presence_changed()
    await asyncio.sleep(0)
    assert subscriber.queue.empty()
    original = subscriber.profile
    # Cosmetic flooding is dropped without consuming call-control tokens.
    subscriber.profile_allowance = 0
    for _ in range(50):
        group.admit_control(subscriber, original)
        group.dispatch(subscriber, original)
    assert subscriber.allowance == 12
    assert subscriber.profile is original
    assert subscriber.queue.empty()


async def test_profile_survives_authenticated_handoff():
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, membership = await admit(a, alice, b, bob)
        at = await recovery(a)
        await recovery(b)
        photo = profile(alice)
        await send(a, photo)
        await sync(a)
        async with resume(url, alice, offer["call"], at) as replacement:
            await snapshot(replacement, membership)
            assert group.peers[alice.identity].profile == photo
