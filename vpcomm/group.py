"""Small-group routing. Clients authenticate rosters and encrypt every pairwise link."""

import asyncio
import json
import secrets
import time

from .crypto import decode, encode
from .lobby import Lobby, Peer, name_valid, offer_fields, transcript, verify
from .profile import validate_profile
from .webrtc import (
    CANDIDATE_FIELDS,
    QUALITY_LOG,
    SIGNAL_LIMIT,
    description_info,
    log_quality,
    parse_quality,
    pseudonym,
    signal_fields,
    validate_candidate,
    validate_sdp,
)


class GroupLobby(Lobby):
    MAX_MEMBERS = 6
    RESUME_SECONDS = 40

    def __init__(self, push=None, turn=None, **kwargs):
        super().__init__(**kwargs)
        self.push = push
        self.turn = turn
        self.epochs = {}
        self.rtc_signals = {}
        self.rtc_descriptions = {}
        self.rtc_candidates = {}
        self.members = {}
        self.revisions = {}
        self.paused = set()
        self.request_timers = {}
        self.presence_subscribers = {}
        self.presence_update = None
        self.profile_cache = {}
        self.resume_timers = {}
        self.roster_messages = {}
        self.refresh_pending = {}
        self.refresh_times = {}
        self.refresh_timers = {}

    def challenge(self, nonce):
        return {
            **super().challenge(nonce),
            "presence": "1",
            "profiles": "1",
            "direct": "1",
            **(
                {
                    "webrtc": "1", "quality": "1", "quality_path": "1",
                    "trickle": "1", "recovery": "1",
                }
                if self.turn
                else {}
            ),
        }

    def recoverable_call(self, peer):
        call = peer.joined
        offer = self.offers.get(call)
        return bool(
            peer.resume_token and offer and offer.owner.resume_token
            and offer.message.get("media") == "webrtc" and self.revisions.get(call, 0)
            and peer.identity in self.members.get(call, {})
        )

    def register_peer(self, socket, hello, challenge):
        if hello.get("type") != "resume":
            return super().register_peer(socket, hello, challenge)
        if set(hello) != {"type", "identity", "name", "call", "token", "signature"}:
            raise ValueError("Invalid resume")
        if not name_valid(hello["name"]):
            raise ValueError("Invalid resume name")
        decode(hello["token"], 32)
        verify(
            hello["identity"], hello["signature"],
            transcript("group-resume", challenge, hello["identity"], hello["name"],
                       hello["call"], hello["token"]),
        )
        old = self.peers.get(hello["identity"])
        if (
            not old or not self.recoverable_call(old) or old.joined != hello["call"]
            or old.name != hello["name"]
            or not secrets.compare_digest(old.resume_token, hello["token"])
        ):
            raise ValueError("Resume not authorized or expired")
        now = time.monotonic()
        attempts = [stamp for stamp in old.resume_attempts if now - stamp < 60]
        if len(attempts) >= 8:
            raise ValueError("Too many resume attempts")
        if old.identity not in self.resume_timers and len(self.resume_timers) >= 64:
            raise ValueError("Recovery capacity reached")
        peer = Peer(socket, old.identity, old.name)
        for attr in ("offer", "joined", "direct_calls", "webrtc", "resume_token",
                     "allowance", "last", "ice_allowance", "ice_last",
                     "profile", "profile_subscribed", "profile_allowance", "profile_last"):
            setattr(peer, attr, getattr(old, attr))
        peer.resume_attempts = attempts + [now]
        peer.resumed = True
        self.peers[peer.identity] = peer
        if old.offer:
            self.offers[old.offer].owner = peer
            for request in list(self.offers[old.offer].requests):
                self.remove_request(self.offers[old.offer], request, "reconnecting")
        if old in self.presence_subscribers:
            self.presence_subscribers.pop(old)
            self.presence_subscribers[peer] = None
        self.cancel_resume_timer(peer.identity)
        self.resume_timers[peer.identity] = asyncio.get_running_loop().call_later(
            self.RESUME_SECONDS, self.expire_resume, peer
        )
        old.suspended = True
        old.socket.transport.abort()
        self.paused.add(peer.joined)
        self.refresh_pending.pop(peer.joined, None)
        return peer

    def connected_peer(self, peer):
        if peer.resumed:
            peer.emit({
                "type": "rtc-config", "servers": json.dumps(self.turn.servers(peer.identity))
            })
            peer.emit({**self.roster_messages[peer.joined], "type": "resume-state"})
            self.request_refresh(peer.joined)
        # Clients clear their offer directory before resume, so these are not duplicates.
        super().connected_peer(peer)

    def cancel_resume_timer(self, identity):
        timer = self.resume_timers.pop(identity, None)
        if timer:
            timer.cancel()

    def disconnected_peer(self, peer, recoverable):
        if self.peers.get(peer.identity) is not peer:
            return
        if recoverable and self.recoverable_call(peer) and (
            peer.identity in self.resume_timers or len(self.resume_timers) < 64
        ):
            peer.suspended = True
            self.paused.add(peer.joined)
            self.refresh_pending.pop(peer.joined, None)
            self.cancel_resume_timer(peer.identity)
            self.resume_timers[peer.identity] = asyncio.get_running_loop().call_later(
                self.RESUME_SECONDS, self.expire_resume, peer
            )
            # Pending admissions are not replayed across a socket handoff.
            offer = self.offers[peer.joined]
            if offer.owner is peer:
                for request in list(offer.requests):
                    self.remove_request(offer, request, "reconnecting")
            self.presence_changed()
            return
        self.remove_peer(peer)

    def expire_resume(self, peer):
        if self.peers.get(peer.identity) is peer:
            self.remove_peer(peer)
            peer.socket.transport.abort()

    def remove_peer(self, peer):
        if self.peers.get(peer.identity) is not peer:
            return
        self.cancel_resume_timer(peer.identity)
        super().remove_peer(peer)

    def shutdown(self):
        for timer in self.resume_timers.values():
            timer.cancel()
        self.resume_timers.clear()
        for peer in list(self.peers.values()):
            self.remove_peer(peer)
        if self.presence_update:
            self.presence_update.cancel()
            self.presence_update = None
        self.presence_subscribers.clear()
        self.profile_cache.clear()

    def request_refresh(self, call):
        timer = self.refresh_timers.pop(call, None)
        if timer:
            timer.cancel()
        offer = self.offers.get(call)
        revision = self.revisions.get(call)
        if not offer or not revision or not offer.owner.resume_token:
            return
        if self.refresh_pending.get(call) == revision:
            return
        if any(self.peers[key].suspended for key in self.members[call]):
            return
        now = time.monotonic()
        times = [stamp for stamp in self.refresh_times.get(call, []) if now - stamp < 60]
        if times and now - times[-1] < 2:
            self.refresh_timers[call] = asyncio.get_running_loop().call_later(
                2 - (now - times[-1]), self.request_refresh, call
            )
            return
        if len(times) >= 8:
            self.close_offer(call, "recovery-limit")
            return
        self.refresh_times[call] = times + [now]
        self.refresh_pending[call] = revision
        offer.owner.emit({"type": "rtc-refresh", "call": call, "revision": str(revision)})

    def visible_offer(self, offer, peer):
        if offer.message.get("media") == "webrtc" and not peer.webrtc:
            return False
        target = offer.message.get("target")
        return target is None or (
            peer.direct_calls and peer.identity in {offer.owner.identity, target}
        )

    def validate_offer(self, peer, message):
        if "media" in message:
            expected = {"type", "call", "identity", "ephemeral", "name", "signature", "media"}
            if "target" in message:
                expected.add("target")
                decode(message["target"], 32)
                if not peer.direct_calls or message["target"] == peer.identity:
                    raise ValueError("Invalid individual recipient")
            if not peer.webrtc or message["media"] != "webrtc" or set(message) != expected:
                raise ValueError("Invalid WebRTC offer")
            decode(message["call"], 16)
            decode(message["ephemeral"], 32)
            self.check_sender(peer, message)
            purpose = "webrtc-direct-offer" if "target" in message else "webrtc-offer"
            verify(peer.identity, message["signature"], transcript(purpose, *offer_fields(message)))
            return
        if "target" not in message:
            return super().validate_offer(peer, message)
        if not peer.direct_calls or set(message) != {
            "type",
            "call",
            "identity",
            "ephemeral",
            "name",
            "signature",
            "target",
        }:
            raise ValueError("Invalid individual offer")
        decode(message["call"], 16)
        decode(message["ephemeral"], 32)
        decode(message["target"], 32)
        if message["target"] == peer.identity:
            raise ValueError("Cannot call yourself")
        self.check_sender(peer, message)
        verify(
            peer.identity, message["signature"], transcript("direct-offer", *offer_fields(message))
        )

    def presence_changed(self):
        # Coalesce synchronous membership changes and never stream presence to old clients.
        if self.presence_update is None:
            self.presence_update = asyncio.get_running_loop().call_soon(self.publish_presence)

    def publish_presence(self):
        self.presence_update = None
        peers = sorted(self.peers.values(), key=lambda peer: peer.identity)
        entries = []
        for peer in peers[:32]:
            state = "online"
            if peer.joined:
                state = "in-call" if self.revisions.get(peer.joined, 0) else "calling"
            elif peer.request:
                state = "joining"
            entries.append([peer.identity, peer.name, state])
        payload = json.dumps(entries, separators=(",", ":"))
        message = {
            "type": "presence",
            "members": payload,
            "truncated": "yes" if len(peers) > 32 else "no",
        }
        for peer, previous in list(self.presence_subscribers.items()):
            if self.peers.get(peer.identity) is not peer:
                self.presence_subscribers.pop(peer, None)
            elif previous != message:
                peer.emit(message)
                self.presence_subscribers[peer] = message
        # Profile thumbnails travel separately, never multiplying the presence frame.
        profiles = {peer.identity: peer.profile for peer in peers[:32] if peer.profile}
        # A later subscriber may never have overlapped with an offline phone.
        # Keep snapshots within the existing 32-frame budget and favor live peers.
        for identity, profile in reversed(self.profile_cache.items()):
            if len(profiles) >= 32:
                break
            profiles.setdefault(identity, profile)
        for peer in peers:
            if not peer.profile_subscribed or peer.suspended:
                continue
            for identity, profile in profiles.items():
                if peer.profile_seen.get(identity) != profile["revision"]:
                    peer.emit(profile)
            peer.profile_seen = {
                identity: profile["revision"] for identity, profile in profiles.items()
            }

    @staticmethod
    def parse(raw):
        if not isinstance(raw, str) or len(raw.encode()) > SIGNAL_LIMIT:
            raise ValueError("Invalid group frame")
        value = json.loads(raw)
        if not isinstance(value, dict) or not all(isinstance(v, str) for v in value.values()):
            raise ValueError("Invalid group object")
        if value.get("type") != "rtc-signal" and len(raw.encode()) > 8192:
            raise ValueError("Invalid group frame")
        return value

    def admit_control(self, peer, message):
        if message.get("type") in {"profile", "profile-subscribe"}:
            # Cosmetic updates must not exhaust audio/admission control budgets.
            return
        if message.get("type") == "rtc-candidate":
            # Separate burst budget for up to five links. Stale updates consume
            # this too, without exhausting ordinary call-control allowances.
            now = time.monotonic()
            peer.ice_allowance = min(512, peer.ice_allowance + (now - peer.ice_last) * 64)
            peer.ice_last = now
            if peer.ice_allowance < 1:
                raise ValueError("ICE candidate flood")
            peer.ice_allowance -= 1
            return
        # SDP has its own strict one-message-per-directed-pair/epoch budget.
        if message.get("type") != "rtc-signal":
            super().admit_control(peer, message)

    def close_offer(self, call, reason="closed"):
        for key in [key for key in self.request_timers if key[0] == call]:
            self.request_timers.pop(key).cancel()
        for identity in self.members.pop(call, {}):
            self.cancel_resume_timer(identity)
            peer = self.peers.get(identity)
            if peer:
                peer.joined = None
                if peer.suspended:
                    self.peers.pop(identity, None)
        self.revisions.pop(call, None)
        self.epochs.pop(call, None)
        self.rtc_signals.pop(call, None)
        self.rtc_descriptions.pop(call, None)
        self.rtc_candidates.pop(call, None)
        self.roster_messages.pop(call, None)
        self.refresh_pending.pop(call, None)
        self.refresh_times.pop(call, None)
        timer = self.refresh_timers.pop(call, None)
        if timer:
            timer.cancel()
        self.paused.discard(call)
        super().close_offer(call, reason)
        self.presence_changed()

    def remove_request(self, offer, request, reason):
        timer = self.request_timers.pop((offer.message["call"], request), None)
        if timer:
            timer.cancel()
        super().remove_request(offer, request, reason)
        if offer.message.get("target"):
            self.close_offer(offer.message["call"], reason)
        self.presence_changed()

    def expire_request(self, call, request):
        offer = self.offers.get(call)
        if offer and request in offer.requests:
            self.remove_request(offer, request, "expired")

    def depart(self, peer):
        # A recipient can hang up before sending a join request.
        if peer.direct_calls:
            for call, pending in list(self.offers.items()):
                if pending.message.get("target") == peer.identity:
                    self.close_offer(call)
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
        if kind in {"profile", "profile-subscribe"}:
            now = time.monotonic()
            peer.profile_allowance = min(
                4, peer.profile_allowance + (now - peer.profile_last) / 5
            )
            peer.profile_last = now
            if peer.profile_allowance < 1:
                return
            peer.profile_allowance -= 1
            if kind == "profile-subscribe" and set(message) == {"type"}:
                peer.profile_subscribed = True
                self.presence_changed()
                return
            revision = validate_profile(message, peer.identity)
            previous_profile = peer.profile or self.profile_cache.get(peer.identity)
            if previous_profile:
                previous = int(previous_profile["revision"])
                # Ed25519 signers such as CryptoKit randomize signatures, so a reconnecting
                # phone re-signs the same revision differently. Compare only signed content.
                if revision < previous or (
                    revision == previous and message["photo"] != previous_profile["photo"]
                ):
                    raise ValueError("Profile rollback or conflicting revision")
                if revision == previous:
                    message = previous_profile
            peer.profile = message
            self.profile_cache.pop(peer.identity, None)
            self.profile_cache[peer.identity] = message.copy()
            if len(self.profile_cache) > 128:
                self.profile_cache.pop(next(iter(self.profile_cache)))
            self.presence_changed()
            return
        if kind == "recovery-enable" and set(message) == {"type"} and peer.webrtc:
            if peer.resume_token is None:
                peer.resume_token = encode(secrets.token_bytes(32))
                peer.emit({"type": "recovery-ready", "token": peer.resume_token})
            return
        if kind == "rtc-refresh" and set(message) == {"type", "call", "revision", "epoch"}:
            call = message["call"]
            if not self.recoverable_call(peer) or peer.joined != call:
                raise ValueError("Not a recoverable call member")
            if int(message["revision"]) < self.revisions[call]:
                return
            if (
                message["revision"] != str(self.revisions[call])
                or message["epoch"] != self.epochs[call]
            ):
                raise ValueError("Wrong recovery epoch")
            self.request_refresh(call)
            return
        if kind == "rtc-enable" and set(message) == {"type"}:
            if not self.turn:
                raise ValueError("WebRTC unavailable")
            if not peer.webrtc:
                peer.webrtc = True
                peer.emit(
                    {"type": "rtc-config", "servers": json.dumps(self.turn.servers(peer.identity))}
                )
                for offer in self.offers.values():
                    if offer.message.get("media") == "webrtc" and self.visible_offer(offer, peer):
                        peer.emit(offer.message)
            return
        if kind == "rtc-signal":
            self.rtc_signal(peer, message)
            return
        if kind == "rtc-candidate":
            self.rtc_candidate(peer, message)
            return
        if kind == "rtc-quality":
            self.rtc_quality(peer, message)
            return
        if kind == "direct-enable" and set(message) == {"type"}:
            if not peer.direct_calls:
                peer.direct_calls = True
                for offer in self.offers.values():
                    if offer.message.get("target") and self.visible_offer(offer, peer):
                        peer.emit(offer.message)
            return
        if kind == "request":
            offer = self.offers.get(message.get("call"))
            if offer and offer.message.get("media") == "webrtc" and not peer.webrtc:
                raise ValueError("WebRTC capability required")
            if (
                offer
                and offer.message.get("target")
                and (not peer.direct_calls or peer.identity != offer.message["target"])
            ):
                raise ValueError("Not the selected recipient")
        if kind == "direct-decline" and set(message) == {"type", "call"}:
            offer = self.offers.get(message["call"])
            if offer is None:
                peer.emit({"type": "closed", "call": message["call"], "reason": "unavailable"})
                return
            if offer.message.get("target") != peer.identity:
                raise ValueError("Not the selected recipient")
            self.close_offer(message["call"], "declined")
            return
        if kind == "presence-subscribe" and set(message) == {"type"}:
            self.presence_subscribers.setdefault(peer, None)
            self.presence_changed()
            return
        if kind == "push-capabilities" and set(message) == {"type"}:
            peer.emit({"type": "push-capabilities", "enabled": "yes" if self.push else "no"})
            return
        if kind == "push-register":
            keys = {"type", "token", "environment", "scope"}
            if "media" in message:
                keys.add("media")
                if message["media"] != "webrtc" or not peer.webrtc:
                    raise ValueError("Invalid push media capability")
            if set(message) != keys or not self.push:
                raise ValueError("Push registration unavailable")
            self.push.devices.register(
                peer.identity,
                message["token"],
                message["environment"],
                message["scope"],
                webrtc=message.get("media") == "webrtc",
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
            if peer.offer == call or self.offers[call].message.get("target"):
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
        target = offer.message.get("target")
        if target and (
            len(entries) != 2
            or any(not isinstance(entry, dict) for entry in entries)
            or {entry.get("identity") for entry in entries} != {peer.identity, target}
        ):
            raise ValueError("Individual calls allow only the selected pair")
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
            self.cancel_resume_timer(identity)
            old = self.peers.get(identity)
            if old:
                old.joined = None
                # Removed members also verify the caller's signed removal.
                old.emit(message)
                if old.suspended:
                    self.peers.pop(identity, None)
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
            if not member.suspended:
                self.cancel_resume_timer(identity)
        self.members[call] = members
        self.revisions[call] = revision
        self.epochs[call] = message["epoch"]
        self.roster_messages[call] = message
        self.refresh_pending.pop(call, None)
        self.rtc_signals[call] = set()
        self.rtc_descriptions[call] = {}
        self.rtc_candidates[call] = {}
        if not any(self.peers[identity].suspended for identity in members):
            self.paused.discard(call)
        if revision == 1:
            offer.expiry.cancel()
            offer.expiry = asyncio.get_running_loop().call_later(
                self.session_lifetime, self.close_offer, call, "expired"
            )

    def rtc_signal(self, peer, message):
        if set(message) != {
            "type",
            "call",
            "revision",
            "epoch",
            "identity",
            "to",
            "kind",
            "sdp",
            "signature",
        }:
            raise ValueError("Invalid WebRTC signaling")
        call = message["call"]
        offer = self.offers.get(call)
        if (
            not peer.webrtc
            or not offer
            or offer.message.get("media") != "webrtc"
            or peer.joined != call
            or peer.identity not in self.members[call]
            or message["identity"] != peer.identity
        ):
            raise ValueError("Not admitted to WebRTC call")
        revision = int(message["revision"])
        if revision < self.revisions[call] or call in self.paused:
            super().admit_control(peer, message)
            return
        target = message["to"]
        if (
            message["revision"] != str(self.revisions[call])
            or message["epoch"] != self.epochs.get(call)
            or target == peer.identity
            or target not in self.members[call]
            or message["kind"] != ("offer" if peer.identity < target else "answer")
        ):
            raise ValueError("Invalid WebRTC pair or epoch")
        pair = (peer.identity, target)
        if pair in self.rtc_signals[call]:
            raise ValueError("Duplicate WebRTC description")
        validate_sdp(message["sdp"])
        verify(
            peer.identity, message["signature"], transcript("rtc-signal", *signal_fields(message))
        )
        self.rtc_signals[call].add(pair)
        self.rtc_descriptions[call][pair] = description_info(message["sdp"])
        other = self.peers.get(target)
        if other:
            other.emit(message)

    def rtc_candidate(self, peer, message):
        if set(message) != set(CANDIDATE_FIELDS) | {"type", "signature"}:
            raise ValueError("Invalid ICE update")
        call = message["call"]
        offer = self.offers.get(call)
        if (
            not peer.webrtc
            or not offer
            or offer.message.get("media") != "webrtc"
            or peer.joined != call
            or peer.identity not in self.members[call]
            or message["identity"] != peer.identity
        ):
            raise ValueError("Not admitted to WebRTC call")
        if int(message["revision"]) < self.revisions[call] or call in self.paused:
            return
        target = message["to"]
        if (
            message["revision"] != str(self.revisions[call])
            or message["epoch"] != self.epochs.get(call)
            or target == peer.identity
            or target not in self.members[call]
        ):
            raise ValueError("Invalid ICE pair or epoch")
        pair = (peer.identity, target)
        local = self.rtc_descriptions[call].get(pair)
        remote = self.rtc_descriptions[call].get((target, peer.identity))
        if (
            not local
            or not remote
            or not local[2]
            or not remote[2]
            or message["description"] != local[0]
            or message["mid"] != local[1]
        ):
            raise ValueError("Trickle ICE was not negotiated for this description")
        sequence = validate_candidate(message)
        previous, ended = self.rtc_candidates[call].get(pair, (0, False))
        if ended or sequence != previous + 1:
            raise ValueError("Replayed or out-of-order ICE candidate")
        verify(
            peer.identity,
            message["signature"],
            transcript("rtc-candidate", *[message[key] for key in CANDIDATE_FIELDS]),
        )
        self.rtc_candidates[call][pair] = (sequence, message["candidate"] == "")
        other = self.peers.get(target)
        if other:
            other.emit(message)

    def rtc_quality(self, peer, message):
        # Diagnostics only: a stale or malformed report never ends the call.
        if set(message) != {"type", "call", "links"} or not peer.webrtc:
            raise ValueError("Invalid quality report")
        call = message["call"]
        offer = self.offers.get(call)
        if (
            not offer
            or offer.message.get("media") != "webrtc"
            or peer.joined != call
            or peer.identity not in self.members.get(call, {})
        ):
            return
        try:
            links = parse_quality(message["links"], peer.identity, self.members[call])
        except (ValueError, TypeError):
            QUALITY_LOG.warning("quality report rejected from=%s", pseudonym(peer.identity))
            return
        log_quality(call, peer.identity, links)

    def media(self, peer, raw):
        # destination key || epoch revision || counter/ciphertext/tag.
        if len(raw) != 705 or not peer.joined:
            raise ValueError("Invalid media")
        call = peer.joined
        if self.offers[call].message.get("media") == "webrtc":
            raise ValueError("PCM is not permitted in WebRTC calls")
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
