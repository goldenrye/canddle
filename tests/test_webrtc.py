import asyncio
import base64
import hashlib
import hmac
import json
import sqlite3
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock

import pytest
from test_group_server import client, media, roster
from test_lobby import TOKEN, Device, recv, send
from websockets.exceptions import ConnectionClosed

from vpcomm.crypto import encode
from vpcomm.lobby import offer_fields, transcript
from vpcomm.push import PushDevices, PushService
from vpcomm.server import Relay, build_server
from vpcomm.webrtc import TURNConfig, from_environment, signal_fields, validate_sdp

TURN = TURNConfig(("turn:turn.example.com:3478?transport=udp",), "test-secret-" * 4)
SDP = (
    "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtcp-mux\r\n"
    "a=rtpmap:111 opus/48000/2\r\na=fingerprint:sha-256 " + ":".join(["AB"] * 32) + "\r\n"
)


def offer(device, target=None):
    message = {**device.offer(), "media": "webrtc"}
    if target:
        message["target"] = target
    purpose = "webrtc-direct-offer" if target else "webrtc-offer"
    message["signature"] = encode(device.key.sign(transcript(purpose, *offer_fields(message))))
    return message


def signal(device, other, membership, sdp=SDP):
    message = {
        "type": "rtc-signal",
        "call": membership["call"],
        "revision": membership["revision"],
        "epoch": membership["epoch"],
        "identity": device.identity,
        "to": other.identity,
        "kind": "offer" if device.identity < other.identity else "answer",
        "sdp": sdp,
    }
    message["signature"] = encode(
        device.key.sign(transcript("rtc-signal", *signal_fields(message)))
    )
    return message


@asynccontextmanager
async def server():
    relay = Relay(TOKEN, turn=TURN)
    async with build_server(relay, "127.0.0.1", 0) as live:
        yield relay.group, f"ws://127.0.0.1:{live.sockets[0].getsockname()[1]}/relay"
    assert not relay.group.members
    assert not relay.group.epochs
    assert not relay.group.rtc_signals


async def enable(socket):
    await send(socket, {"type": "rtc-enable"})
    config = await recv(socket, "rtc-config")
    assert json.loads(config["servers"])[0]["urls"] == list(TURN.urls)


async def admit(a, alice, b, bob, direct=False):
    await enable(a)
    await enable(b)
    announcement = offer(alice, bob.identity if direct else None)
    await send(a, announcement)
    await recv(a, "offer")
    await recv(b, "offer")
    request = bob.request(announcement)
    await send(b, request)
    await recv(a, "request")
    await send(
        b,
        {
            "type": "confirm",
            "call": announcement["call"],
            "request": request["request"],
            "proof": encode(bytes(32)),
        },
    )
    await recv(a, "confirm")
    membership = roster(alice, announcement, [announcement, request])
    await send(a, membership)
    await recv(a, "roster")
    await recv(b, "roster")
    return announcement, request, membership


def test_turn_credentials_and_environment(monkeypatch):
    entry = TURN.servers("device", now=100)[0]
    assert entry["username"] == "7300:" + hashlib.sha256(b"device").hexdigest()[:16]
    assert (
        entry["credential"]
        == base64.b64encode(
            hmac.digest(TURN.secret.encode(), entry["username"].encode(), "sha1")
        ).decode()
    )
    assert TURN.servers("other", now=100)[0]["credential"] != entry["credential"]
    monkeypatch.delenv("VPCOMM_TURN_URLS", raising=False)
    monkeypatch.delenv("VPCOMM_TURN_SECRET", raising=False)
    assert from_environment() is None
    monkeypatch.setenv("VPCOMM_TURN_URLS", TURN.urls[0])
    with pytest.raises(ValueError):
        from_environment()
    monkeypatch.setenv("VPCOMM_TURN_SECRET", TURN.secret)
    assert from_environment() == TURN


@pytest.mark.parametrize(
    "url",
    [
        "https://turn.example:3478",
        "turn:user:pass@host:3478",
        "turn:host:0",
        "turn:host:65536",
        "turns:host:5349?transport=udp",
        "turn:host:3478\ninjected=true",
    ],
)
def test_invalid_turn_urls(url):
    with pytest.raises(ValueError):
        TURNConfig((url,), TURN.secret)


@pytest.mark.parametrize(
    "sdp",
    [
        "",
        SDP + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
        SDP.replace("UDP/TLS/RTP/SAVPF", "RTP/AVP"),
        SDP.replace("sha-256", "sha-1"),
        SDP.replace("opus", "PCMU"),
        SDP + "a=x:" + "a" * 24000,
    ],
)
def test_invalid_sdp(sdp):
    with pytest.raises(ValueError):
        validate_sdp(sdp)


@pytest.mark.parametrize("direct", [False, True])
async def test_authenticated_pair_delivery_and_legacy_isolation(direct):
    async with (
        server() as (group, url),
        client(url, direct=True) as (a, alice),
        client(url, direct=True) as (b, bob),
        client(url) as (legacy, _),
    ):
        _, _, membership = await admit(a, alice, b, bob, direct)
        # Long-but-bounded SDP is permitted without increasing other control frame limits.
        message = signal(alice, bob, membership, SDP + "a=x:" + "x" * 9000 + "\r\n")
        await send(a, message)
        assert await recv(b, "rtc-signal") == message
        answer = signal(bob, alice, membership)
        await send(b, answer)
        assert await recv(a, "rtc-signal") == answer
        assert len(group.rtc_signals[membership["call"]]) == 2
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(legacy.recv(), 0.05)


@pytest.mark.parametrize(
    "field",
    ["identity", "to", "call", "epoch", "revision", "kind", "sdp", "signature", "replay", "pcm"],
)
async def test_signal_authorization(field):
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        _, _, membership = await admit(a, alice, b, bob)
        message = signal(alice, bob, membership)
        if field == "replay":
            await send(a, message)
            await recv(b, "rtc-signal")
        elif field == "pcm":
            await a.send(media(bob.identity))
        else:
            message[field] = {"revision": "2", "kind": "wrong", "sdp": SDP.replace("AB", "CD")}.get(
                field, "invalid"
            )
        if field != "pcm":
            await send(a, message)
        with pytest.raises(ConnectionClosed):
            await a.recv()


async def test_old_epoch_ignored_and_current_epoch_renewed():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        announcement, request, membership = await admit(a, alice, b, bob)
        old = signal(alice, bob, membership)
        await send(a, old)
        await recv(b, "rtc-signal")
        updated = roster(alice, announcement, [announcement, request], revision=2)
        await send(a, updated)
        await recv(a, "roster")
        await recv(b, "roster")
        await send(a, old)
        message = signal(alice, bob, updated)
        await send(a, message)
        assert await recv(b, "rtc-signal") == message
        removed = roster(alice, announcement, [announcement], revision=3)
        await send(a, removed)
        await recv(a, "roster")
        await recv(b, "roster")
        await send(b, signal(bob, alice, removed))
        with pytest.raises(ConnectionClosed):
            await b.recv()


async def test_unadmitted_peer_cannot_send_sdp():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, bob):
        await enable(a)
        await enable(b)
        announcement = offer(alice)
        await send(a, announcement)
        await recv(a, "offer")
        await recv(b, "offer")
        await send(b, signal(bob, alice, roster(alice, announcement, [announcement])))
        with pytest.raises(ConnectionClosed):
            await b.recv()


@pytest.mark.parametrize("mutation", ["strip", "media", "signature"])
async def test_media_mode_is_signed(mutation):
    async with server() as (_, url), client(url) as (socket, device):
        await enable(socket)
        message = offer(device)
        if mutation == "strip":
            del message["media"]
        else:
            message[mutation] = "invalid"
        await send(socket, message)
        with pytest.raises(ConnectionClosed):
            await socket.recv()


async def test_late_capability_replays_offer_only_once():
    async with server() as (_, url), client(url) as (a, alice), client(url) as (b, _):
        await enable(a)
        announcement = offer(alice)
        await send(a, announcement)
        await recv(a, "offer")
        await enable(b)
        assert await recv(b, "offer") == announcement
        await send(b, {"type": "rtc-enable"})
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(b.recv(), 0.05)


async def test_webrtc_push_capability_and_database_migration(tmp_path):
    path = str(tmp_path / "devices.sqlite")
    db = sqlite3.connect(path)
    db.execute(
        "CREATE TABLE devices (identity TEXT PRIMARY KEY, token TEXT UNIQUE, environment TEXT,"
        "scope TEXT, updated REAL, namespace TEXT)"
    )
    db.close()
    store = PushDevices(path, TOKEN)
    caller, modern, old = Device(), Device(), Device()
    store.register(
        modern.identity, "a" * 64, "production", "wss://voice.example/relay", webrtc=True
    )
    store.register(old.identity, "b" * 64, "production", "wss://voice.example/relay")
    service = PushService(store, AsyncMock())
    service.announce(offer(caller), lambda: True)
    assert service.queue.qsize() == 1
    assert service.queue.get_nowait()[0].identity == modern.identity
    service.last_call.clear()
    service.announce(offer(caller, old.identity), lambda: True)
    assert service.queue.empty()
    store.close()
    store = PushDevices(path, TOKEN)
    assert next(
        d for d in store.recipients(caller.identity) if d.identity == modern.identity
    ).webrtc
    store.register(modern.identity, "a" * 64, "production", "wss://voice.example/relay")
    assert not any(d.webrtc for d in store.recipients(caller.identity))
    store.close()
