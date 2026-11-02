"""Small-group routing. Clients authenticate rosters and encrypt every pairwise link."""

import asyncio
import json
import time

from .crypto import decode, encode
from .lobby import Lobby, transcript, verify


class GroupLobby(Lobby):
    MAX_MEMBERS = 6

    def __init__(self, push=None, **kwargs):
        super().__init__(**kwargs)
        self.push = push
        self.members = {}
        self.revisions = {}
        self.paused = set()
        self.request_timers = {}

    @staticmethod
    def parse(raw):
        if not isinstance(raw, str) or len(raw.encode()) > 8192:
            raise ValueError("Invalid group frame")
        value = json.loads(raw)
        if not isinstance(value, dict) or not all(isinstance(v, str) for v in value.values()):
            raise ValueError("Invalid group object")
        return value

    def close_offer(self, call, reason="closed"):
        for key in [key for key in self.request_timers if key[0] == call]:
            self.request_timers.pop(key).cancel()
        for identity in self.members.pop(call, {}):
            peer = self.peers.get(identity)
            if peer:
                peer.joined = None
        self.revisions.pop(call, None)
        self.paused.discard(call)
        super().close_offer(call, reason)

    def remove_request(self, offer, request, reason):
        timer = self.request_timers.pop((offer.message["call"], request), None)
        if timer:
            timer.cancel()
        super().remove_request(offer, request, reason)

    def expire_request(self, call, request):
        offer = self.offers.get(call)
        if offer and request in offer.requests:
            self.remove_request(offer, request, "expired")

    def depart(self, peer):
        if peer.joined and peer.joined != peer.offer:
            call = peer.joined
            self.members.get(call, {}).pop(peer.identity, None)
            self.paused.add(call)
            offer = self.offers.get(call)
            if offer:
                offer.owner.emit({"type": "departed", "call": call, "identity": peer.identity})
            peer.joined = None

    def dispatch(self, peer, message):
        kind = message.get("type")
        if kind == "push-capabilities" and set(message) == {"type"}:
            peer.emit({"type": "push-capabilities", "enabled": "yes" if self.push else "no"})
            return
        if kind == "push-register":
            if set(message) != {"type", "token", "environment", "scope"} or not self.push:
                raise ValueError("Push registration unavailable")
            self.push.devices.register(
                peer.identity, message["token"], message["environment"], message["scope"]
            )
            peer.emit({"type": "push-registered"})
            return
        if kind == "push-unregister" and set(message) == {"type"}:
            if self.push:
                self.push.devices.remove(peer.identity)
            peer.emit({"type": "push-unregistered"})
            return
        if kind in {"offer", "request"} and peer.joined:
            raise ValueError("Already in a call")
        if kind == "approve":
            raise ValueError("Use signed group roster")
        if kind == "roster":
            self.roster(peer, message)
            return
        if kind == "leave":
            if set(message) != {"type", "call"} or peer.joined != message["call"]:
                raise ValueError("Not a member")
            call = peer.joined
            if peer.offer == call:
                self.close_offer(call)
            else:
                self.depart(peer)
                peer.emit({"type": "closed", "call": call, "reason": "left"})
            return
        super().dispatch(peer, message)
        if kind == "offer":
            call = message["call"]
            self.members[call] = {peer.identity: message}
            self.revisions[call] = 0
            peer.joined = call
            if self.push:
                self.push.announce(message, lambda: call in self.offers)
        elif kind == "request" and peer.request:
            call, request = peer.request
            self.request_timers[(call, request)] = asyncio.get_running_loop().call_later(
                self.lifetime, self.expire_request, call, request
            )

    def roster(self, peer, message):
        if set(message) != {"type", "call", "revision", "epoch", "members", "signature"}:
            raise ValueError("Invalid roster")
        call = message["call"]
        offer = self.offers.get(call)
        if not offer or offer.owner is not peer:
            raise ValueError("Not caller")
        revision = int(message["revision"])
        if (
            str(revision) != message["revision"]
            or revision != self.revisions[call] + 1
            or revision >= 1 << 64
        ):
            raise ValueError("Invalid revision")
        decode(message["epoch"], 32)
        verify(
            peer.identity,
            message["signature"],
            transcript(
                "group-roster", call, message["revision"], message["epoch"], message["members"]
            ),
        )
        entries = json.loads(message["members"])
        if not isinstance(entries, list) or not 1 <= len(entries) <= self.MAX_MEMBERS:
            raise ValueError("Invalid member count")
        members = {}
        admitted = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("identity"), str):
                raise ValueError("Invalid member")
            identity = entry["identity"]
            if identity in members:
                raise ValueError("Duplicate member")
            existing = self.members[call].get(identity)
            if existing != entry:
                request = entry.get("request")
                pending = offer.requests.get(request)
                if not pending:
                    # A valid caller decision may race a leave, timeout or disconnect.
                    # No mutation has occurred; ask the caller to rebuild its proposal.
                    peer.emit(
                        {
                            "type": "roster-retry",
                            "call": call,
                            "revision": message["revision"],
                            "identity": identity,
                        }
                    )
                    return
                if pending[1] != entry or not pending[2]:
                    raise ValueError("Member was not confirmed")
                admitted.append(request)
            members[identity] = entry
            if identity not in self.peers:
                raise ValueError("Disconnected member")
        if members.get(peer.identity) != offer.message or len(admitted) > 1:
            raise ValueError("Invalid caller or admission")
        previous = self.members[call]
        for identity in previous.keys() - members.keys():
            old = self.peers.get(identity)
            if old:
                old.joined = None
                # Removed members also verify the caller's signed removal.
                old.emit(message)
        for request in admitted:
            member, _, _ = offer.requests.pop(request)
            member.request = None
            timer = self.request_timers.pop((call, request), None)
            if timer:
                timer.cancel()
        for identity in members:
            member = self.peers[identity]
            member.joined = call
            member.emit(message)
        self.members[call] = members
        self.revisions[call] = revision
        self.paused.discard(call)
        if revision == 1:
            offer.expiry.cancel()
            offer.expiry = asyncio.get_running_loop().call_later(
                self.session_lifetime, self.close_offer, call, "expired"
            )

    def media(self, peer, raw):
        # destination key || epoch revision || counter/ciphertext/tag.
        if len(raw) != 705 or not peer.joined:
            raise ValueError("Invalid media")
        call = peer.joined
        now = time.monotonic()
        peer.media_allowance = min(600, peer.media_allowance + (now - peer.media_last) * 300)
        peer.media_last = now
        if peer.media_allowance < 1:
            raise ValueError("Media flood")
        peer.media_allowance -= 1
        revision = int.from_bytes(raw[32:40], "big")
        if revision < self.revisions[call] or call in self.paused:
            return
        if revision != self.revisions[call] or revision == 0:
            raise ValueError("Invalid media epoch")
        target = encode(raw[:32])
        if target == peer.identity or target not in self.members[call]:
            raise ValueError("Destination not admitted")
        other = self.peers.get(target)
        if other:
            other.emit(decode(peer.identity, 32) + raw[32:])
