"""Bounded, optional ciphertext mailboxes. Independent of call-control budgets."""

import asyncio
import hashlib
import json
import logging
import os
import secrets
import sqlite3
import time

from .crypto import decode, encode
from .lobby import Lobby, Peer, transcript, verify
from .push import TOKEN, Device

TTL = 7 * 86400
PHOTO_BYTES = 128 * 1024
PHOTO_FRAME_LIMIT = 176 * 1024
MAILBOX_BYTES = 8 * 1024 * 1024
TOTAL_BYTES = 64 * 1024 * 1024
FIELDS = ("id", "from", "to", "scope", "key", "ephemeral", "created", "body")
RECEIPT = ("id", "from", "to", "scope")
LOG = logging.getLogger("vpcomm.messages")


def validate_key(message, identity, *, photos=False):
    if set(message) != {"type", "identity", "scope", "key", "signature"}:
        raise ValueError("Invalid message key")
    purpose = "chat-photo-key" if photos else "chat-key"
    if (
        message["type"] != purpose or message["identity"] != identity
        or not 1 <= len(message["scope"]) <= 256
    ):
        raise ValueError("Invalid message key identity/scope")
    decode(message["key"], 32)
    verify(
        identity,
        message["signature"],
        transcript(purpose, identity, message["scope"], message["key"]),
    )


def validate_envelope(message, identity, scope, *, photos=False):
    if set(message) != {"type", "signature", *FIELDS}:
        raise ValueError("Invalid message fields")
    if (
        message["type"] != ("chat-photo" if photos else "chat-send")
        or message["from"] != identity or message["to"] == identity or message["scope"] != scope
    ):
        raise ValueError("Invalid message route")
    for field, size in (("id", 16), ("from", 32), ("to", 32), ("key", 32), ("ephemeral", 32)):
        decode(message[field], size)
    created = int(message["created"])
    if str(created) != message["created"] or not time.time() - TTL <= created <= time.time() + 60:
        raise ValueError("Expired message or incorrect clock")
    raw = message["body"]
    if not 39 <= len(raw) <= ((PHOTO_BYTES + 28) * 4 // 3 + 4 if photos else 5500):
        raise ValueError("Invalid message size")
    encrypted = decode(raw, len(raw) * 6 // 8)
    if not 29 <= len(encrypted) <= (PHOTO_BYTES if photos else 4096) + 28:
        raise ValueError("Invalid ciphertext size")
    verify(
        identity, message["signature"],
        transcript("chat-photo-message" if photos else "chat-message",
                   *(message[k] for k in FIELDS)),
    )
    return created


def validate_receipt(message, identity, scope):
    if (
        not isinstance(message, dict)
        or set(message) != {"type", "signature", *RECEIPT}
        or not all(isinstance(value, str) for value in message.values())
        or message["type"] != "chat-receipt"
        or message["to"] != identity
        or message["scope"] != scope
    ):
        raise ValueError("Invalid receipt")
    verify(
        identity, message["signature"], transcript("chat-receipt", *(message[k] for k in RECEIPT))
    )


class Messages:
    def __init__(self, path, access_token, sender=None):
        if len(access_token) < 32 or not access_token.isascii():
            raise ValueError("Access token must be at least 32 ASCII characters")
        if path != ":memory:":
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            os.close(fd)
            os.chmod(path, 0o600)
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA secure_delete=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS namespace (value TEXT);
            CREATE TABLE IF NOT EXISTS chat_keys (
                scope TEXT, identity TEXT, bundle TEXT, allowed TEXT DEFAULT '[]',
                token TEXT DEFAULT '', environment TEXT DEFAULT '', updated REAL,
                PRIMARY KEY(scope, identity));
            CREATE TABLE IF NOT EXISTS chat_messages (
                scope TEXT, sender TEXT, id TEXT, recipient TEXT, digest TEXT,
                envelope TEXT, receipt TEXT, created REAL,
                PRIMARY KEY(scope, sender, id));
            CREATE TABLE IF NOT EXISTS chat_badges (
                scope TEXT, identity TEXT, count INTEGER,
                PRIMARY KEY(scope, identity));
        """)
        for table, column, definition in [
            ("chat_keys", "photo_bundle", "TEXT"),
            ("chat_keys", "photo_cursor", "INTEGER DEFAULT 0"),
            ("chat_messages", "kind", "TEXT DEFAULT 'text'"),
        ]:
            if column not in {row[1] for row in self.db.execute(f"PRAGMA table_info({table})")}:
                self.db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
        namespace = hashlib.sha256(access_token.encode()).hexdigest()
        previous = self.db.execute("SELECT value FROM namespace").fetchone()
        if not previous or previous[0] != namespace:
            self.db.executescript(
                "DELETE FROM chat_keys; DELETE FROM chat_messages; DELETE FROM chat_badges; "
                "DELETE FROM namespace;"
            )
            self.db.execute("INSERT INTO namespace VALUES (?)", (namespace,))
        self.db.commit()
        self.sender = sender
        self.queue = asyncio.Queue(maxsize=128)
        self.worker = None
        self.cleaner = None
        self.photo_sessions = set()
        self.photo_rates = {}

    async def transfer(self, socket):
        """One authenticated photo operation on a socket that never joins the call lobby."""
        identity_scope = None
        try:
            async with asyncio.timeout(10):
                nonce = encode(secrets.token_bytes(32))
                await socket.send(json.dumps({"type": "challenge", "challenge": nonce}))
                hello = Lobby.parse(await socket.recv())
                if (
                    set(hello) != {"type", "identity", "scope", "signature"}
                    or hello["type"] != "photo-register"
                ):
                    raise ValueError("Invalid photo registration")
                verify(hello["identity"], hello["signature"],
                       transcript("chat-photo-session", nonce, hello["identity"], hello["scope"]))
                row = self.db.execute(
                    "SELECT photo_bundle FROM chat_keys WHERE scope=? AND identity=?",
                    (hello["scope"], hello["identity"]),
                ).fetchone()
                if not row or not row[0]:
                    raise ValueError("Photo messaging not enabled")
                key = (hello["scope"], hello["identity"])
                tokens, last = self.photo_rates.get(key, (8, time.monotonic()))
                now = time.monotonic()
                tokens = min(8, tokens + (now - last) * 2)
                if key in self.photo_sessions or tokens < 1:
                    raise ValueError("Photo transfer busy")
                self.photo_rates[key] = (tokens - 1, now)
                self.photo_sessions.add(key)
                identity_scope = key
                await socket.send('{"type":"photo-online"}')
            async with asyncio.timeout(45):
                raw = await socket.recv()
                if not isinstance(raw, str) or len(raw.encode()) > PHOTO_FRAME_LIMIT:
                    raise ValueError("Invalid photo frame")
                message = json.loads(raw)
                if (
                    not isinstance(message, dict)
                    or not all(isinstance(value, str) for value in message.values())
                    or message.get("type") not in {
                        "chat-photo", "chat-photo-pull", "chat-photo-status"
                    }
                ):
                    raise ValueError("Invalid photo operation")
                peer = Peer(socket, hello["identity"], "Photo transfer", chat_scope=hello["scope"])
                self.dispatch(peer, message, {}, photos=True)
                while not peer.queue.empty():
                    await socket.send(json.dumps(peer.queue.get_nowait(), separators=(",", ":")))
        finally:
            if identity_scope:
                self.photo_sessions.discard(identity_scope)

    def start(self):
        self.cleaner = asyncio.create_task(self.cleanup())
        if self.sender:
            self.worker = asyncio.create_task(self.run())

    async def cleanup(self):
        while True:
            try:
                with self.db:
                    self.db.execute(
                        "DELETE FROM chat_messages WHERE created < ?", (time.time() - TTL,)
                    )
            except sqlite3.Error:
                LOG.warning("Message expiry cleanup failed")
            await asyncio.sleep(60)

    async def close(self):
        tasks = [task for task in (self.worker, self.cleaner) if task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.db.close()

    @staticmethod
    def emit(peer, message):
        # A backed-up chat must never overflow the shared call signaling queue.
        if peer and not peer.suspended and peer.queue.qsize() < 48:
            peer.emit(message)

    def dispatch(self, peer, message, peers, *, photos=False):
        now = time.monotonic()
        peer.chat_allowance = min(40, peer.chat_allowance + (now - peer.chat_last) * 5)
        peer.chat_last = now
        if peer.chat_allowance < 1:
            return
        peer.chat_allowance -= 1
        try:
            with self.db:
                self.db.execute("DELETE FROM chat_messages WHERE created < ?", (time.time() - TTL,))
                self.db.execute(
                    "UPDATE chat_keys SET token='' WHERE updated < ?", (time.time() - TTL,)
                )
                self.handle(peer, message, peers, photos=photos)
        except (ValueError, TypeError, KeyError, sqlite3.Error):
            self.emit(
                peer,
                {
                    "type": "chat-error",
                    "id": message.get("id", ""),
                    "to": message.get("to", ""),
                    "error": "Message rejected; refresh or retry.",
                },
            )

    def key(self, scope, identity):
        row = self.db.execute(
            "SELECT bundle, allowed FROM chat_keys WHERE scope=? AND identity=?", (scope, identity)
        ).fetchone()
        return (json.loads(row[0]), json.loads(row[1])) if row else (None, [])

    def revoke_push(self, identity):
        with self.db:
            self.db.execute("UPDATE chat_keys SET token='' WHERE identity=?", (identity,))

    def badge_count(self, scope, identity):
        row = self.db.execute(
            "SELECT count FROM chat_badges WHERE scope=? AND identity=?", (scope, identity)
        ).fetchone()
        if row is None:
            return None  # Older clients do not opt in to combined badges.
        pending = self.db.execute(
            "SELECT COUNT(*) FROM chat_messages WHERE scope=? AND recipient=? "
            "AND envelope IS NOT NULL AND created>=?",
            (scope, identity, time.time() - TTL),
        ).fetchone()[0]
        return row[0] + pending

    def handle(self, peer, message, peers, *, photos=False):
        kind = message["type"]
        if kind == "chat-key":
            validate_key(message, peer.identity)
            scope = message["scope"]
            previous, _ = self.key(scope, peer.identity)
            if previous and previous["key"] != message["key"]:
                raise ValueError("Message key changed")
            if (
                not previous
                and self.db.execute("SELECT COUNT(*) FROM chat_keys").fetchone()[0] >= 256
            ):
                raise ValueError("Message device capacity")
            self.db.execute(
                "INSERT INTO chat_keys(scope,identity,bundle,updated) VALUES (?,?,?,?) "
                "ON CONFLICT(scope,identity) DO UPDATE SET "
                "updated=excluded.updated,photo_bundle=NULL",
                (scope, peer.identity, json.dumps(message), time.time()),
            )
            peer.chat_scope = scope
            self.db.execute(
                "DELETE FROM chat_badges WHERE scope=? AND identity=?", (scope, peer.identity)
            )
            self.emit(
                peer, {"type": "chat-ready", "push": "yes" if self.sender else "no",
                       "badges": "1", "photos": "1"}
            )
            return
        scope = peer.chat_scope
        if not scope:
            raise ValueError("Publish message key first")
        if kind == "chat-photo-key":
            validate_key(message, peer.identity, photos=True)
            bundle, _ = self.key(scope, peer.identity)
            if message["scope"] != scope or message["key"] != bundle["key"]:
                raise ValueError("Photo key mismatch")
            self.db.execute(
                "UPDATE chat_keys SET photo_bundle=? WHERE scope=? AND identity=?",
                (json.dumps(message), scope, peer.identity),
            )
            self.emit(peer, {"type": "chat-photo-ready"})
        elif kind == "chat-allow" and set(message) == {"type", "identities"}:
            identities = json.loads(message["identities"])
            if not isinstance(identities, list) or len(identities) > 128:
                raise ValueError("Invalid trusted devices")
            for identity in identities:
                decode(identity, 32)
            self.db.execute(
                "UPDATE chat_keys SET allowed=? WHERE scope=? AND identity=?",
                (json.dumps(identities), scope, peer.identity),
            )
            for sender, message_id in self.db.execute(
                "SELECT sender,id FROM chat_messages WHERE scope=? AND recipient=? "
                "AND envelope IS NOT NULL",
                (scope, peer.identity),
            ).fetchall():
                if sender not in identities:
                    self.db.execute(
                        "DELETE FROM chat_messages WHERE scope=? AND sender=? AND id=?",
                        (scope, sender, message_id),
                    )
        elif kind in {"chat-key-get", "chat-photo-key-get"} and set(message) == {"type", "to"}:
            decode(message["to"], 32)
            bundle, allowed = self.key(scope, message["to"])
            if kind == "chat-photo-key-get":
                row = self.db.execute(
                    "SELECT photo_bundle FROM chat_keys WHERE scope=? AND identity=?",
                    (scope, message["to"]),
                ).fetchone()
                bundle = json.loads(row[0]) if row and row[0] else None
            if not bundle or peer.identity not in allowed:
                self.emit(peer, {"type": "chat-photo-unavailable" if kind == "chat-photo-key-get"
                                else "chat-unavailable", "to": message["to"]})
            else:
                self.emit(peer, bundle)
        elif kind == "chat-send" or (photos and kind == "chat-photo"):
            photo = kind == "chat-photo"
            created = validate_envelope(message, peer.identity, scope, photos=photo)
            bundle, allowed = self.key(scope, message["to"])
            if not bundle or peer.identity not in allowed or bundle["key"] != message["key"]:
                raise ValueError("Recipient unavailable or not verified")
            if photo and not self.db.execute(
                "SELECT 1 FROM chat_keys WHERE scope=? AND identity=? AND photo_bundle IS NOT NULL",
                (scope, message["to"]),
            ).fetchone():
                raise ValueError("Recipient must enable photos")
            digest = hashlib.sha256(
                transcript("chat-photo-message" if photo else "chat-message",
                           *(message[k] for k in FIELDS))
            ).hexdigest()
            previous = self.db.execute(
                "SELECT digest, receipt FROM chat_messages WHERE scope=? AND sender=? AND id=?",
                (scope, peer.identity, message["id"]),
            ).fetchone()
            if previous:
                if previous[0] != digest:
                    raise ValueError("Conflicting message ID")
                if previous[1]:
                    self.emit(peer, json.loads(previous[1]))
            else:
                total = self.db.execute("SELECT COUNT(*) FROM chat_messages").fetchone()[0]
                pending = self.db.execute(
                    "SELECT COUNT(*) FROM chat_messages WHERE envelope IS NOT NULL AND "
                    "(recipient=? OR sender=?)",
                    (message["to"], peer.identity),
                ).fetchone()[0]
                if total >= 4096 or pending >= 200:
                    raise ValueError("Message queue full")
                encoded = json.dumps(message)
                used = self.db.execute(
                    "SELECT COALESCE(SUM(LENGTH(envelope)),0), "
                    "COALESCE(SUM(CASE WHEN recipient=? OR sender=? "
                    "THEN LENGTH(envelope) ELSE 0 END),0) "
                    "FROM chat_messages", (message["to"], peer.identity),
                ).fetchone()
                if used[0] + len(encoded) > TOTAL_BYTES or used[1] + len(encoded) > MAILBOX_BYTES:
                    raise ValueError("Message byte capacity")
                self.db.execute(
                    "INSERT INTO chat_messages"
                    "(scope,sender,id,recipient,digest,envelope,receipt,created,kind) "
                    "VALUES (?,?,?,?,?,?,NULL,?,?)",
                    (
                        scope,
                        peer.identity,
                        message["id"],
                        message["to"],
                        digest,
                        encoded,
                        created,
                        "photo" if photo else "text",
                    ),
                )
                recipient = peers.get(message["to"])
                if not photo and recipient and recipient.chat_scope == scope:
                    self.emit(recipient, message)
                if self.sender:
                    try:
                        self.queue.put_nowait((scope, message["to"], peer.identity, message["id"]))
                    except asyncio.QueueFull:
                        pass  # Ciphertext remains available to the next mailbox poll.
            self.emit(
                peer,
                {"type": "chat-stored", "scope": scope, "id": message["id"], "to": message["to"]},
            )
        elif kind == "chat-badge" and set(message) == {"type", "count", "receipts"}:
            count = int(message["count"])
            if str(count) != message["count"] or not 0 <= count <= 1128:
                raise ValueError("Invalid badge count")
            receipts = json.loads(message["receipts"])
            if not isinstance(receipts, list) or len(receipts) > 32:
                raise ValueError("Invalid badge receipts")
            for receipt in receipts:
                validate_receipt(receipt, peer.identity, scope)
            # Receipt removal and the device's local count commit together, preventing
            # newly downloaded unread messages from being counted again as queued.
            for receipt in receipts:
                self.handle(peer, receipt, peers)
            self.db.execute(
                "INSERT INTO chat_badges VALUES (?,?,?) ON CONFLICT(scope,identity) "
                "DO UPDATE SET count=excluded.count",
                (scope, peer.identity, count),
            )
        elif kind == "chat-receipt":
            validate_receipt(message, peer.identity, scope)
            self.db.execute(
                "UPDATE chat_messages SET envelope=NULL,receipt=? WHERE scope=? AND sender=? "
                "AND id=? AND recipient=?",
                (json.dumps(message), scope, message["from"], message["id"], peer.identity),
            )
            sender = peers.get(message["from"])
            if sender and sender.chat_scope == scope:
                self.emit(sender, message)
        elif kind == "chat-pull" and set(message) == {"type"}:
            # Rotate even unacknowledged ciphertext so a bad message cannot starve the inbox.
            for row in self.db.execute(
                "SELECT rowid,envelope FROM chat_messages WHERE scope=? AND recipient=? "
                "AND envelope IS NOT NULL AND kind='text' ORDER BY (rowid<=?),rowid LIMIT 5",
                (scope, peer.identity, peer.chat_cursor),
            ):
                self.emit(peer, json.loads(row[1]))
                peer.chat_cursor = row[0]
        elif photos and kind == "chat-photo-status" and set(message) == {"type", "id", "to"}:
            decode(message["id"], 16)
            decode(message["to"], 32)
            row = self.db.execute(
                "SELECT receipt FROM chat_messages "
                "WHERE scope=? AND sender=? AND id=? AND recipient=?",
                (scope, peer.identity, message["id"], message["to"]),
            ).fetchone()
            if not row:
                raise ValueError("Photo expired or removed")
            self.emit(peer, json.loads(row[0]) if row[0] else {
                "type": "chat-stored", "scope": scope, "id": message["id"], "to": message["to"]
            })
        elif photos and kind == "chat-photo-pull" and set(message) == {"type"}:
            cursor = self.db.execute(
                "SELECT photo_cursor FROM chat_keys WHERE scope=? AND identity=?",
                (scope, peer.identity),
            ).fetchone()[0]
            row = self.db.execute(
                "SELECT rowid,envelope FROM chat_messages WHERE scope=? AND recipient=? "
                "AND envelope IS NOT NULL AND kind='photo' ORDER BY (rowid<=?),rowid LIMIT 1",
                (scope, peer.identity, cursor),
            ).fetchone()
            if row:
                self.emit(peer, json.loads(row[1]))
                self.db.execute(
                    "UPDATE chat_keys SET photo_cursor=? WHERE scope=? AND identity=?",
                    (row[0], scope, peer.identity),
                )
            else:
                self.emit(peer, {"type": "chat-photo-empty"})
        elif kind == "chat-push" and set(message) == {"type", "token", "environment"}:
            token, environment = message["token"], message["environment"]
            if token and (
                not TOKEN.fullmatch(token)
                or len(token) % 2
                or environment not in {"development", "production"}
            ):
                raise ValueError("Invalid message push token")
            if (
                token
                and self.db.execute(
                    "SELECT 1 FROM chat_keys WHERE token=? AND identity<>?", (token, peer.identity)
                ).fetchone()
            ):
                raise ValueError("Message push token belongs to another device")
            self.db.execute(
                "UPDATE chat_keys SET token=?,environment=?,updated=? WHERE scope=? AND identity=?",
                (token, environment, time.time(), scope, peer.identity),
            )
        else:
            raise ValueError("Unknown message operation")

    async def run(self):
        while True:
            scope, recipient, sender, message_id = await self.queue.get()
            try:
                row = self.db.execute(
                    "SELECT token,environment,updated,allowed FROM chat_keys "
                    "WHERE scope=? AND identity=?",
                    (scope, recipient),
                ).fetchone()
                pending = self.db.execute(
                    "SELECT 1 FROM chat_messages WHERE scope=? AND sender=? AND id=? "
                    "AND envelope IS NOT NULL AND created>=?",
                    (scope, sender, message_id, time.time() - TTL),
                ).fetchone()
                if not row or not row[0] or row[2] < time.time() - TTL or not pending:
                    continue
                if sender not in json.loads(row[3]):
                    continue
                device = Device(recipient, row[0], row[1], scope, row[2])
                if not await self.sender.send_message(
                    device, badge=self.badge_count(scope, recipient)
                ):
                    with self.db:
                        self.db.execute(
                            "UPDATE chat_keys SET token='' "
                            "WHERE scope=? AND identity=? AND token=?",
                            (scope, recipient, row[0]),
                        )
            except Exception:
                LOG.warning("Message notification failed; ciphertext remains queued")
            finally:
                self.queue.task_done()
