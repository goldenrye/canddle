"""Network handoff retains admission, never replays uncertain media signaling."""

import asyncio
import time
from contextlib import asynccontextmanager

import pytest
from test_group_server import client, roster
from test_lobby import TOKEN, Device, recv, send
from test_webrtc import admit, candidate, descriptions, server, signal
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import encode


async def recovery(socket):
    await send(socket, {"type": "recovery-enable"})
    return (await recv(socket, "recovery-ready"))["token"]


@asynccontextmanager
async def resume(url, device, call, token, mutation=None):
    async with connect(
        url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
    ) as socket:
        await send(socket, {"v": 2, "group": True})
        challenge = (await recv(socket, "challenge"))["challenge"]
        fields = [challenge, device.identity, device.name, call, token]
        if mutation == "challenge":
            fields[0] = encode(bytes(32))
        message = device.signed("group-resume", fields, {
            "type": "resume", "identity": device.identity, "name": device.name,
            "call": call, "token": token,
        })
        if mutation and mutation != "challenge":
            message[mutation] = "invalid"
        await send(socket, message)
        yield socket


async def snapshot(socket, membership):
    await recv(socket, "online")
    await recv(socket, "rtc-config")
    assert await recv(socket, "resume-state") == {**membership, "type": "resume-state"}


async def sync(socket):
    await send(socket, {"type": "ping"})
    await recv(socket, "pong")


@pytest.mark.parametrize("caller", [False, True])
@pytest.mark.parametrize("direct", [False, True])
@pytest.mark.parametrize("replace_live", [False, True])
async def test_handoff_retains_admission_and_resets_signaling(caller, direct, replace_live):
    async with (
        server() as (group, url),
        client(url, direct=True) as (a, alice),
        client(url, direct=True) as (b, bob),
    ):
        offer, request, first = await admit(a, alice, b, bob, direct)
        at, bt = await recovery(a), await recovery(b)
        await descriptions(a, alice, b, bob, first)
        await send(b, candidate(bob, alice, first))
        await recv(a, "rtc-candidate")
        old_socket, device, token = (a, alice, at) if caller else (b, bob, bt)
        old_peer = group.peers[device.identity]
        if not replace_live:
            await old_socket.close(1001)
            await sync(b if caller else a)
            assert old_peer.suspended
            assert offer["call"] in group.paused
        async with resume(url, device, offer["call"], token) as new:
            await snapshot(new, first)
            host, guest = (new, b) if caller else (a, new)
            assert await recv(host, "rtc-refresh") == {
                "type": "rtc-refresh", "call": offer["call"], "revision": "1",
            }
            await recv(new, "offer")
            # Late cleanup of the old transport cannot remove its replacement.
            group.disconnected_peer(old_peer, True)
            assert group.peers[device.identity] is not old_peer
            assert set(group.members[offer["call"]]) == {alice.identity, bob.identity}
            assert offer["call"] in group.paused
            second = roster(alice, offer, [offer, request], revision=2)
            await send(host, second)
            await recv(host, "roster")
            await recv(guest, "roster")
            assert not group.resume_timers
            assert offer["call"] not in group.paused
            await send(guest, signal(bob, alice, first))  # Old epoch is discarded.
            await descriptions(host, alice, guest, bob, second)
            await send(guest, candidate(bob, alice, second))
            await recv(host, "rtc-candidate")
            await send(host, {"type": "cancel", "call": offer["call"]})
            await recv(host, "closed")
            await recv(guest, "closed")
            assert not group.refresh_pending and not group.roster_messages
            assert not group.refresh_timers


@pytest.mark.parametrize(
    "mutation", ["challenge", "identity", "name", "call", "token", "signature"]
)
async def test_resume_tampering_does_not_displace_live_peer(mutation):
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        await recovery(a)
        token = await recovery(b)
        original = group.peers[bob.identity]
        async with resume(url, bob, offer["call"], token, mutation) as bad:
            with pytest.raises(ConnectionClosed):
                await bad.recv()
        assert group.peers[bob.identity] is original
        await sync(b)


@pytest.mark.parametrize("caller", [False, True])
async def test_resume_expiry_and_normal_hangup_are_terminal(caller):
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        at, bt = await recovery(a), await recovery(b)
        socket, device, token = (a, alice, at) if caller else (b, bob, bt)
        group.RESUME_SECONDS = 0.03
        await socket.close(1001)
        await recv(b if caller else a, "closed" if caller else "departed")
        assert device.identity not in group.peers
        assert not group.resume_timers
        async with resume(url, device, offer["call"], token) as late:
            with pytest.raises(ConnectionClosed):
                await late.recv()


@pytest.mark.parametrize("code", [1000, 1008, 1009])
async def test_explicit_hangup_and_protocol_close_never_resume(code):
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        token = await recovery(a)
        await recovery(b)
        await a.close(code)
        await recv(b, "closed")
        assert not group.resume_timers
        async with resume(url, alice, offer["call"], token) as late:
            with pytest.raises(ConnectionClosed):
                await late.recv()


async def test_removed_member_cannot_resume():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        await recovery(a)
        token = await recovery(b)
        await send(a, roster(alice, offer, [offer], revision=2))
        await recv(a, "roster")
        await recv(b, "roster")
        async with resume(url, bob, offer["call"], token) as late:
            with pytest.raises(ConnectionClosed):
                await late.recv()
        await sync(b)


async def test_simultaneous_handoff_waits_for_both_members():
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request, first = await admit(a, alice, b, bob)
        at, bt = await recovery(a), await recovery(b)
        await a.close(1001)
        await b.close(1001)
        async with resume(url, alice, offer["call"], at) as host:
            await snapshot(host, first)
            await recv(host, "offer")
            await sync(host)
            assert not group.refresh_pending
            async with resume(url, bob, offer["call"], bt) as guest:
                await snapshot(guest, first)
                await recv(guest, "offer")
                await recv(host, "rtc-refresh")
                await send(host, roster(alice, offer, [offer, request], revision=2))
                await recv(host, "roster")
                await recv(guest, "roster")
                assert not group.resume_timers


async def test_fresh_snapshot_after_missed_roster_keeps_call_paused():
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request, _ = await admit(a, alice, b, bob)
        await recovery(a)
        token = await recovery(b)
        await b.close(1001)
        await sync(a)
        second = roster(alice, offer, [offer, request], revision=2)
        await send(a, second)
        await recv(a, "roster")
        assert offer["call"] in group.paused
        assert bob.identity in group.resume_timers
        async with resume(url, bob, offer["call"], token) as guest:
            await snapshot(guest, second)
            await recv(guest, "offer")
            await recv(a, "rtc-refresh")
            third = roster(alice, offer, [offer, request], revision=3)
            await send(a, third)
            await recv(a, "roster")
            await recv(guest, "roster")
            assert not group.paused


async def test_refresh_is_coalesced_and_bounded():
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request, first = await admit(a, alice, b, bob)
        await recovery(a)
        await recovery(b)
        refresh = {key: first[key] for key in ("call", "revision", "epoch")}
        refresh["type"] = "rtc-refresh"
        for _ in range(3):
            await send(b, refresh)
        await sync(b)
        await recv(a, "rtc-refresh")
        await sync(a)  # No duplicate refresh queued.
        await send(a, roster(alice, offer, [offer, request], revision=2))
        await recv(a, "roster")
        await recv(b, "roster")
        group.request_refresh(offer["call"])
        assert offer["call"] in group.refresh_timers
        group.refresh_times[offer["call"]] = [time.monotonic() - 3] * 8
        group.request_refresh(offer["call"])
        await recv(a, "closed")
        await recv(b, "closed")
        assert not group.refresh_timers and not group.refresh_times


@pytest.mark.parametrize("limit", ["attempts", "capacity"])
async def test_resume_resource_bounds(limit):
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        await recovery(a)
        token = await recovery(b)
        old = group.peers[bob.identity]
        if limit == "attempts":
            old.resume_attempts = [time.monotonic()] * 8
        else:
            group.resume_timers = {
                str(i): asyncio.get_running_loop().call_later(60, lambda: None) for i in range(64)
            }
        async with resume(url, bob, offer["call"], token) as bad:
            with pytest.raises(ConnectionClosed):
                await bad.recv()
        assert group.peers[bob.identity] is old
        await sync(b)


async def test_old_caller_does_not_gain_unsupported_recovery():
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        token = await recovery(b)
        await b.close(1001)
        await recv(a, "departed")
        assert not group.resume_timers
        async with resume(url, bob, offer["call"], token) as bad:
            with pytest.raises(ConnectionClosed):
                await bad.recv()


@pytest.mark.parametrize("wrong", ["token", "device", "call"])
async def test_valid_signature_alone_does_not_authorize_resume(wrong):
    async with server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _, _ = await admit(a, alice, b, bob)
        await recovery(a)
        token = await recovery(b)
        original = group.peers[bob.identity]
        async with resume(
            url, Device() if wrong == "device" else bob,
            encode(bytes(16)) if wrong == "call" else offer["call"],
            encode(bytes(32)) if wrong == "token" else token,
        ) as bad:
            with pytest.raises(ConnectionClosed):
                await bad.recv()
        assert group.peers[bob.identity] is original
        await sync(b)


async def test_refresh_requires_current_authenticated_membership():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        _, _, first = await admit(a, alice, b, bob)
        await recovery(a)
        await recovery(b)
        await send(b, {
            "type": "rtc-refresh", "call": first["call"],
            "revision": first["revision"], "epoch": encode(bytes(32)),
        })
        with pytest.raises(ConnectionClosed):
            await b.recv()
