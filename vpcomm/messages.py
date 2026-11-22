"""Bounded, optional ciphertext mailboxes. Independent of call-control budgets."""

import asyncio
import hashlib
import json
import logging
import os
import sqlite3
import time

from .crypto import decode
from .lobby import transcript, verify
from .push import TOKEN, Device

TTL = 7 * 86400
FIELDS = ("id", "from", "to", "scope", "key", "ephemeral", "created", "body")
RECEIPT = ("id", "from", "to", "scope")
LOG = logging.getLogger("vpcomm.messages")


def validate_key(message, identity):
    if set(message) != {"type", "identity", "scope", "key", "signature"}:
        raise ValueError("Invalid message key")
    if message["identity"] != identity or not 1 <= len(message["scope"]) <= 256:
        raise ValueError("Invalid message key identity/scope")
    decode(message["key"], 32)
    verify(
        identity,
        message["signature"],
        transcript("chat-key", identity, message["scope"], message["key"]),
    )


def validate_envelope(message, identity, scope):
    if set(message) != {"type", "signature", *FIELDS}:
        raise ValueError("Invalid message fields")
    if message["from"] != identity or message["to"] == identity or message["scope"] != scope:
        raise ValueError("Invalid message route")
    for field, size in (("id", 16), ("from", 32), ("to", 32), ("key", 32), ("ephemeral", 32)):
        decode(message[field], size)
    created = int(message["created"])
    if str(created) != message["created"] or not time.time() - TTL <= created <= time.time() + 60:
        raise ValueError("Expired message or incorrect clock")
    raw = message["body"]
    if not 39 <= len(raw) <= 5500:
        raise ValueError("Invalid message size")
    decode(raw, len(raw) * 6 // 8)
    verify(
        identity, message["signature"], transcript("chat-message", *(message[k] for k in FIELDS))
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

    def dispatch(self, peer, message, peers):
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
                self.handle(peer, message, peers)
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

    def handle(self, peer, message, peers):
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
                "ON CONFLICT(scope,identity) DO UPDATE SET updated=excluded.updated",
                (scope, peer.identity, json.dumps(message), time.time()),
            )
            peer.chat_scope = scope
            self.db.execute(
                "DELETE FROM chat_badges WHERE scope=? AND identity=?", (scope, peer.identity)
            )
            self.emit(
                peer, {"type": "chat-ready", "push": "yes" if self.sender else "no", "badges": "1"}
            )
            return
        scope = peer.chat_scope
        if not scope:
            raise ValueError("Publish message key first")
        if kind == "chat-allow" and set(message) == {"type", "identities"}:
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
        elif kind == "chat-key-get" and set(message) == {"type", "to"}:
            decode(message["to"], 32)
            bundle, allowed = self.key(scope, message["to"])
            if not bundle or peer.identity not in allowed:
                self.emit(peer, {"type": "chat-unavailable", "to": message["to"]})
            else:
                self.emit(peer, bundle)
        elif kind == "chat-send":
            created = validate_envelope(message, peer.identity, scope)
            bundle, allowed = self.key(scope, message["to"])
            if not bundle or peer.identity not in allowed or bundle["key"] != message["key"]:
                raise ValueError("Recipient unavailable or not verified")
            digest = hashlib.sha256(
                transcript("chat-message", *(message[k] for k in FIELDS))
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
                self.db.execute(
                    "INSERT INTO chat_messages VALUES (?,?,?,?,?,?,NULL,?)",
                    (
                        scope,
                        peer.identity,
                        message["id"],
                        message["to"],
                        digest,
                        json.dumps(message),
                        created,
                    ),
                )
                recipient = peers.get(message["to"])
                if recipient and recipient.chat_scope == scope:
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
                "AND envelope IS NOT NULL ORDER BY (rowid<=?),rowid LIMIT 5",
                (scope, peer.identity, peer.chat_cursor),
            ):
                self.emit(peer, json.loads(row[1]))
                peer.chat_cursor = row[0]
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
