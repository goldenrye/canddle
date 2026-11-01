import json
import secrets
from contextlib import AsyncExitStack, asynccontextmanager

import pytest
from test_lobby import TOKEN, Device, recv, send
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import decode, encode
from vpcomm.lobby import transcript
from vpcomm.server import Relay, build_server


@asynccontextmanager
async def group_server():
    relay = Relay(TOKEN)
    async with build_server(relay, "127.0.0.1", 0) as server:
        yield relay.group, f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/relay"
    assert not relay.group.peers
    assert not relay.group.members
    assert not relay.group.offers
    assert not relay.group.request_timers


@asynccontextmanager
async def client(url):
    device = Device()
    async with connect(
        url, additional_headers={"Authorization": f"Bearer {TOKEN}"}, proxy=None
    ) as socket:
        await send(socket, {"v": 2, "group": True})
        challenge = await recv(socket, "challenge")
        await send(socket, device.registration(challenge["challenge"]))
        await recv(socket, "online")
        yield socket, device


async def offer_request(a, alice, b, bob, confirmed=True):
    offer = alice.offer()
    await send(a, offer)
    await recv(a, "offer")
    await recv(b, "offer")
    request = bob.request(offer)
    await send(b, request)
    await recv(a, "request")
    if confirmed:
        await send(
            b,
            {
                "type": "confirm",
                "call": offer["call"],
                "request": request["request"],
                "proof": encode(secrets.token_bytes(32)),
            },
        )
        await recv(a, "confirm")
    return offer, request


def roster(device, offer, members, revision=1):
    message = {
        "type": "roster",
        "call": offer["call"],
        "revision": str(revision),
        "epoch": encode(secrets.token_bytes(32)),
        "members": json.dumps(members),
    }
    message["signature"] = encode(
        device.key.sign(
            transcript(
                "group-roster", offer["call"], str(revision), message["epoch"], message["members"]
            )
        )
    )
    return message


def media(destination, revision=1):
    return decode(destination, 32) + revision.to_bytes(8, "big") + secrets.token_bytes(665)


@pytest.mark.parametrize(
    "failure", ["non-owner", "unconfirmed", "signature", "revision", "duplicate", "foreign"]
)
async def test_roster_authorization(failure):
    async with group_server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request = await offer_request(a, alice, b, bob, confirmed=failure != "unconfirmed")
        members = [offer, request]
        if failure == "duplicate":
            members.append(request)
        if failure == "foreign":
            # A signed request bound to another call must never be accepted.
            members[1] = bob.request(alice.offer())
            members[1]["request"] = request["request"]
        message = roster(
            bob if failure == "non-owner" else alice,
            offer,
            members,
            revision=2 if failure == "revision" else 1,
        )
        if failure == "signature":
            message["signature"] = encode(secrets.token_bytes(64))
        target = b if failure == "non-owner" else a
        await send(target, message)
        with pytest.raises(ConnectionClosed):
            await target.recv()


async def test_media_routing_no_broadcast_and_removal():
    async with group_server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request = await offer_request(a, alice, b, bob)
        first = roster(alice, offer, [offer, request])
        await send(a, first)
        await recv(a, "roster")
        await recv(b, "roster")
        async with client(url) as (observer, _):
            await recv(observer, "offer")
            packet = media(bob.identity)
            await a.send(packet)
            assert await b.recv() == decode(alice.identity, 32) + packet[32:]
            await send(observer, {"type": "ping"})
            await recv(observer, "pong")
            second = roster(alice, offer, [offer], revision=2)
            await send(a, second)
            await recv(a, "roster")
            assert await recv(b, "roster") == second
            assert group.peers[bob.identity].joined is None
            await b.send(media(alice.identity))
            with pytest.raises(ConnectionClosed):
                await b.recv()


async def test_acceptance_racing_with_withdrawal_is_retryable():
    async with group_server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request = await offer_request(a, alice, b, bob)
        await send(b, {"type": "withdraw", "call": offer["call"], "request": request["request"]})
        await recv(a, "removed")
        await recv(b, "removed")
        await send(a, roster(alice, offer, [offer, request]))
        await recv(a, "roster-retry")
        assert group.revisions[offer["call"]] == 0
        assert list(group.members[offer["call"]]) == [alice.identity]
        await send(a, {"type": "ping"})
        await recv(a, "pong")


async def test_departure_pauses_media_until_new_epoch():
    async with group_server() as (group, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request = await offer_request(a, alice, b, bob)
        await send(a, roster(alice, offer, [offer, request]))
        await recv(a, "roster")
        await recv(b, "roster")
        await send(b, {"type": "leave", "call": offer["call"]})
        await recv(a, "departed")
        await recv(b, "closed")
        assert offer["call"] in group.paused
        await a.send(media(bob.identity))
        await send(a, roster(alice, offer, [offer], revision=2))
        await recv(a, "roster")
        assert offer["call"] not in group.paused
        # In-flight old-epoch audio is dropped, not accepted in the new epoch.
        await a.send(media(bob.identity))
        await send(a, {"type": "ping"})
        await recv(a, "pong")


@pytest.mark.parametrize(
    "failure", ["not-admitted", "foreign-destination", "future-epoch", "oversize"]
)
async def test_media_policy(failure):
    async with group_server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, request = await offer_request(a, alice, b, bob)
        if failure != "not-admitted":
            await send(a, roster(alice, offer, [offer, request]))
            await recv(a, "roster")
            await recv(b, "roster")
        packet = media(
            Device().identity if failure == "foreign-destination" else alice.identity,
            revision=2 if failure == "future-epoch" else 1,
        )
        if failure == "oversize":
            packet += b"x"
        await b.send(packet)
        with pytest.raises(ConnectionClosed):
            await b.recv()


async def test_group_cancel_remains_owner_only():
    async with group_server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        offer, _ = await offer_request(a, alice, b, bob)
        await send(b, {"type": "cancel", "call": offer["call"]})
        with pytest.raises(ConnectionClosed):
            await b.recv()
        await recv(a, "removed")
        await send(a, {"type": "ping"})
        await recv(a, "pong")


async def test_server_rejects_seventh_member():
    async with group_server() as (_, url), client(url) as (a, alice), AsyncExitStack() as stack:
        offer = alice.offer()
        await send(a, offer)
        await recv(a, "offer")
        members = [offer]
        for index in range(1, 7):
            b, bob = await stack.enter_async_context(client(url))
            await recv(b, "offer")
            request = bob.request(offer)
            await send(b, request)
            await recv(a, "request")
            await send(
                b,
                {
                    "type": "confirm",
                    "call": offer["call"],
                    "request": request["request"],
                    "proof": encode(secrets.token_bytes(32)),
                },
            )
            await recv(a, "confirm")
            members.append(request)
            await send(a, roster(alice, offer, members, revision=index))
            if index < 6:
                await recv(a, "roster")
            else:
                with pytest.raises(ConnectionClosed):
                    await a.recv()
