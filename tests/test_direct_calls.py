import secrets

import pytest
from test_group_server import client, group_server, media, roster
from test_lobby import Device, recv, send
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import decode, encode
from vpcomm.lobby import offer_fields, transcript


def direct_offer(caller, target):
    message = {**caller.offer(), "target": target}
    message["signature"] = encode(
        caller.key.sign(transcript("direct-offer", *offer_fields(message)))
    )
    return message


async def confirm(socket, caller, offer, request):
    await send(socket, request)
    await recv(caller, "request")
    await send(socket, {
        "type": "confirm", "call": offer["call"], "request": request["request"],
        "proof": encode(secrets.token_bytes(32)),
    })
    await recv(caller, "confirm")


async def test_only_selected_peer_sees_offer_and_closure():
    async with group_server() as (_, url), client(url, direct=True) as (a, alice), \
            client(url, direct=True) as (b, bob), client(url, direct=True) as (c, _):
        offer = direct_offer(alice, bob.identity)
        await send(a, offer)
        assert await recv(a, "offer") == offer
        assert await recv(b, "offer") == offer
        # A pong is a barrier: no hidden offer may precede it.
        await send(c, {"type": "ping"})
        await recv(c, "pong")
        async with client(url, direct=True) as (late, _), client(url) as (legacy, _):
            for socket in (late, legacy):
                await send(socket, {"type": "ping"})
                await recv(socket, "pong")
            await send(b, {"type": "direct-decline", "call": offer["call"]})
            assert (await recv(a, "closed"))["reason"] == "declined"
            await recv(b, "closed")
            for socket in (c, late, legacy):
                await send(socket, {"type": "ping"})
                await recv(socket, "pong")


async def test_offline_recipient_gets_offer_only_after_capability_opt_in():
    bob = Device()
    async with group_server() as (_, url), client(url, direct=True) as (a, alice):
        offer = direct_offer(alice, bob.identity)
        await send(a, offer)
        await recv(a, "offer")
        async with client(url, device=bob) as (b, _):
            await send(b, {"type": "ping"})
            await recv(b, "pong")
            await send(b, {"type": "direct-enable"})
            assert await recv(b, "offer") == offer
            await send(b, {"type": "direct-enable"})
            await send(b, {"type": "ping"})
            await recv(b, "pong")


@pytest.mark.parametrize("action", ["request", "direct-decline"])
async def test_outsider_cannot_join_or_decline_known_call(action):
    async with group_server() as (group, url), client(url, direct=True) as (a, alice), \
            client(url, direct=True) as (b, bob), client(url, direct=True) as (c, eve):
        offer = direct_offer(alice, bob.identity)
        await send(a, offer)
        await recv(a, "offer")
        await recv(b, "offer")
        await send(c, eve.request(offer) if action == "request" else {
            "type": action, "call": offer["call"],
        })
        with pytest.raises(ConnectionClosed):
            await c.recv()
        assert offer["call"] in group.offers
        assert not group.offers[offer["call"]].requests


@pytest.mark.parametrize("failure", ["target", "stripped", "self", "legacy"])
async def test_direct_offer_binding_and_capability(failure):
    async with group_server() as (_, url), client(url, direct=failure != "legacy") as (a, alice):
        offer = direct_offer(alice, alice.identity if failure == "self" else Device().identity)
        if failure == "target":
            offer["target"] = Device().identity
        if failure == "stripped":
            del offer["target"]
        await send(a, offer)
        with pytest.raises(ConnectionClosed):
            await a.recv()


@pytest.mark.parametrize("ending", [
    "decline", "cancel", "unanswered-disconnect", "pending-disconnect", "withdraw",
    "reject", "request-expiry", "offer-expiry", "leave", "disconnect", "caller-disconnect",
])
async def test_direct_call_lifecycle(ending):
    async with group_server() as (group, url), client(url, direct=True) as (a, alice), \
            client(url, direct=True) as (b, bob):
        offer = direct_offer(alice, bob.identity)
        await send(a, offer)
        await recv(a, "offer")
        await recv(b, "offer")
        if ending in {"pending-disconnect", "withdraw", "reject", "request-expiry",
                      "leave", "disconnect", "caller-disconnect"}:
            request = bob.request(offer)
            await confirm(b, a, offer, request)
        if ending in {"leave", "disconnect", "caller-disconnect"}:
            await send(a, roster(alice, offer, [offer, request]))
            await recv(a, "roster")
            await recv(b, "roster")
            packet = media(bob.identity)
            await a.send(packet)
            assert await b.recv() == decode(alice.identity, 32) + packet[32:]
        if ending in {"unanswered-disconnect", "pending-disconnect", "disconnect"}:
            await b.close()
        elif ending == "caller-disconnect":
            await a.close()
            await recv(b, "closed")
        elif ending == "offer-expiry":
            group.close_offer(offer["call"], "expired")
        elif ending == "request-expiry":
            group.expire_request(offer["call"], request["request"])
        else:
            kind = "direct-decline" if ending == "decline" else ending
            message = {"type": kind, "call": offer["call"]}
            if ending in {"withdraw", "reject"}:
                message["request"] = request["request"]
            await send(a if ending in {"cancel", "reject"} else b, message)
        if ending in {"withdraw", "reject", "request-expiry"}:
            await recv(a, "removed")
        if ending != "caller-disconnect":
            await recv(a, "closed")
        assert not group.offers and not group.members and not group.request_timers
        assert all(peer.joined is None and peer.request is None for peer in group.peers.values())


@pytest.mark.parametrize("members", ["one", "three", "wrong-pair"])
async def test_direct_roster_cannot_change_selected_pair(members):
    async with group_server() as (_, url), client(url, direct=True) as (a, alice), \
            client(url, direct=True) as (b, bob):
        offer = direct_offer(alice, bob.identity)
        await send(a, offer)
        await recv(a, "offer")
        await recv(b, "offer")
        request = bob.request(offer)
        await confirm(b, a, offer, request)
        outsider = Device().request(offer)
        entries = {"one": [offer], "three": [offer, request, outsider],
                   "wrong-pair": [offer, outsider]}[members]
        await send(a, roster(alice, offer, entries))
        with pytest.raises(ConnectionClosed):
            await a.recv()
