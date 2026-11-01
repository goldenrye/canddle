"""Foreground signaling only; invitations remain client-to-client ciphertext."""

import asyncio
import contextlib
import json
import secrets
import time
from dataclasses import dataclass, field

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from websockets.exceptions import ConnectionClosed

from .crypto import decode, encode

CONTEXT = b"vpcomm/lobby/v1/"


def transcript(purpose, *fields):
    """Length-prefix UTF-8 fields, avoiding JSON canonicalization dependencies."""
    result = CONTEXT + purpose.encode("ascii") + b"\0"
    for value in fields:
        raw = value.encode("utf-8")
        result += len(raw).to_bytes(4, "big") + raw
    return result


def offer_fields(offer):
    return [offer[k] for k in ("call", "identity", "ephemeral", "name")]


def request_fields(offer, request):
    return offer_fields(offer) + [request[k] for k in ("request", "identity", "ephemeral", "name")]


def verify(identity, signature, message):
    try:
        Ed25519PublicKey.from_public_bytes(decode(identity, 32)).verify(
            decode(signature, 64), message
        )
    except InvalidSignature as error:
        raise ValueError("Invalid signature") from error


def name_valid(name):
    return isinstance(name, str) and 1 <= len(name) <= 40 and all(32 <= ord(c) <= 126 for c in name)


@dataclass(eq=False)
class Peer:
    socket: object
    identity: str
    name: str
    queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=64))
    offer: str | None = None
    request: tuple[str, str] | None = None
    allowance: float = 12
    last: float = field(default_factory=time.monotonic)

    def emit(self, message):
        try:
            self.queue.put_nowait(message)
        except asyncio.QueueFull:
            # Abort a slow peer without spawning an unbounded set of close tasks.
            self.socket.transport.abort()

    async def write(self):
        while True:
            message = await self.queue.get()
            async with asyncio.timeout(3):
                await self.socket.send(json.dumps(message, separators=(",", ":")))


@dataclass
class Offer:
    owner: Peer
    message: dict
    requests: dict[str, tuple[Peer, dict, bool]] = field(default_factory=dict)
    expiry: asyncio.TimerHandle | None = None


class Lobby:
    def __init__(self, lifetime=120, session_lifetime=3600):
        self.peers: dict[str, Peer] = {}
        self.offers: dict[str, Offer] = {}
        self.lifetime = lifetime
        self.session_lifetime = session_lifetime

    def broadcast(self, message, excluding=()):
        for peer in tuple(self.peers.values()):
            if peer not in excluding:
                peer.emit(message)

    def close_offer(self, call, reason="closed"):
        offer = self.offers.pop(call, None)
        if offer is None:
            return
        if offer.expiry:
            offer.expiry.cancel()
        offer.owner.offer = None
        for peer, _, _ in offer.requests.values():
            peer.request = None
        self.broadcast({"type": "closed", "call": call, "reason": reason})

    def remove_request(self, offer, request, reason):
        peer, _, _ = offer.requests.pop(request)
        peer.request = None
        message = {
            "type": "removed",
            "call": offer.message["call"],
            "request": request,
            "reason": reason,
        }
        peer.emit(message)
        offer.owner.emit(message)

    async def handle(self, socket):
        peer = None
        writer = None
        try:
            challenge = encode(secrets.token_bytes(32))
            async with asyncio.timeout(10):
                await socket.send(json.dumps({"type": "challenge", "challenge": challenge}))
                hello = self.parse(await socket.recv())
            if set(hello) != {"type", "identity", "name", "signature"}:
                raise ValueError("Invalid registration")
            if hello["type"] != "register" or not name_valid(hello["name"]):
                raise ValueError("Invalid registration")
            verify(
                hello["identity"],
                hello["signature"],
                transcript("register", challenge, hello["identity"], hello["name"]),
            )
            if hello["identity"] in self.peers:
                raise ValueError("Device already online")
            peer = Peer(socket, hello["identity"], hello["name"])
            self.peers[peer.identity] = peer
            writer = asyncio.create_task(peer.write())
            # A writer failure must also wake a blocked reader.
            writer.add_done_callback(lambda _: socket.transport.abort())
            peer.emit({"type": "online"})
            for offer in self.offers.values():
                peer.emit(offer.message)
            async with asyncio.timeout(self.session_lifetime):
                while True:
                    async with asyncio.timeout(45):
                        message = self.parse(await socket.recv())
                    now = time.monotonic()
                    peer.allowance = min(12, peer.allowance + (now - peer.last) * 2)
                    peer.last = now
                    if peer.allowance < 1:
                        raise ValueError("Rate exceeded")
                    peer.allowance -= 1
                    self.dispatch(peer, message)
        except (ValueError, TypeError, KeyError, TimeoutError):
            await socket.close(1008, "Invalid lobby request or time limit")
        except ConnectionClosed:
            pass
        finally:
            if peer:
                self.peers.pop(peer.identity, None)
                if peer.offer:
                    self.close_offer(peer.offer)
                if peer.request:
                    call, request = peer.request
                    offer = self.offers.get(call)
                    if offer and request in offer.requests:
                        self.remove_request(offer, request, "withdrawn")
            if writer:
                writer.cancel()
                with contextlib.suppress(asyncio.CancelledError, ConnectionClosed, TimeoutError):
                    await writer

    @staticmethod
    def parse(raw):
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > 1024:
            raise ValueError("Invalid lobby frame")
        value = json.loads(raw)
        if not isinstance(value, dict) or not all(isinstance(v, str) for v in value.values()):
            raise ValueError("Invalid lobby object")
        return value

    def dispatch(self, peer, message):
        kind = message.get("type")
        if kind == "ping" and set(message) == {"type"}:
            peer.emit({"type": "pong"})
            return
        if kind == "offer":
            if set(message) != {"type", "call", "identity", "ephemeral", "name", "signature"}:
                raise ValueError("Invalid offer")
            if peer.offer or peer.request or message["call"] in self.offers:
                raise ValueError("Device busy")
            decode(message["call"], 16)
            decode(message["ephemeral"], 32)
            self.check_sender(peer, message)
            verify(peer.identity, message["signature"], transcript("offer", *offer_fields(message)))
            offer = Offer(peer, message)
            self.offers[message["call"]] = offer
            peer.offer = message["call"]
            offer.expiry = asyncio.get_running_loop().call_later(
                self.lifetime, self.close_offer, peer.offer, "expired"
            )
            self.broadcast(message)
            return
        if kind == "request":
            if set(message) != {
                "type",
                "call",
                "request",
                "identity",
                "ephemeral",
                "name",
                "signature",
            }:
                raise ValueError("Invalid join request")
            offer = self.offers.get(message["call"])
            if offer is None:
                peer.emit({"type": "closed", "call": message["call"], "reason": "unavailable"})
                return
            if peer.offer or peer.request or peer is offer.owner or len(offer.requests) >= 16:
                raise ValueError("Device busy or request capacity")
            decode(message["request"], 16)
            decode(message["ephemeral"], 32)
            if message["request"] in offer.requests:
                raise ValueError("Duplicate request")
            self.check_sender(peer, message)
            verify(
                peer.identity,
                message["signature"],
                transcript("request", *request_fields(offer.message, message)),
            )
            offer.requests[message["request"]] = (peer, message, False)
            peer.request = (message["call"], message["request"])
            offer.owner.emit(message)
            return
        keys = {
            "cancel": {"type", "call"},
            "withdraw": {"type", "call", "request"},
            "reject": {"type", "call", "request"},
            "confirm": {"type", "call", "request", "proof"},
            "approve": {"type", "call", "request", "box"},
        }
        if kind not in keys or set(message) != keys[kind]:
            raise ValueError("Invalid action")
        call = message["call"]
        offer = self.offers.get(call)
        if offer is None:
            peer.emit({"type": "closed", "call": call, "reason": "unavailable"})
            return
        if kind == "cancel":
            if offer.owner is not peer:
                raise ValueError("Not owner")
            self.close_offer(call)
            return
        request = message["request"]
        entry = offer.requests.get(request)
        if entry is None:
            peer.emit(
                {"type": "removed", "call": call, "request": request, "reason": "unavailable"}
            )
            return
        requester, original, confirmed = entry
        if kind in {"withdraw", "confirm"}:
            if requester is not peer:
                raise ValueError("Not requester")
            if kind == "withdraw":
                self.remove_request(offer, request, "withdrawn")
            else:
                decode(message["proof"], 32)
                if confirmed:
                    raise ValueError("Already confirmed")
                offer.requests[request] = (requester, original, True)
                offer.owner.emit(message)
        else:
            if offer.owner is not peer:
                raise ValueError("Not owner")
            if kind == "reject":
                self.remove_request(offer, request, "rejected")
            else:
                if not confirmed:
                    raise ValueError("Requester must confirm first")
                # A vp1 invitation is 70 ASCII bytes, plus GCM's nonce and tag.
                decode(message["box"], 98)
                # All state mutation happens before any writer yields: one winner.
                requester.emit(message)
                peer.emit({"type": "granted", "call": call, "request": request})
                self.close_offer(call, "joined")

    @staticmethod
    def check_sender(peer, message):
        if message["identity"] != peer.identity or message["name"] != peer.name:
            raise ValueError("Identity mismatch")
