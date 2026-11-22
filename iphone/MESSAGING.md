# Private Messages

Canddle supports one-to-one text between previously verified iPhone device keys.
The desktop client does not implement chat. Group text, attachments, reactions,
typing indicators, read receipts, and multi-device history sync are not included.
Calls and their verification rules remain unchanged.

## Enable

1. Upgrade the relay and both iPhones. Enable the optional
   [message database overlay](../deploy/README.md#optional-private-messages).
2. Use the same relay URL on both phones and complete mutual device verification
   in a call. Merely seeing someone in the directory does not verify them.
3. Open Canddle on both phones at least once to publish their signed message
   encryption keys and recipient allowlists.
4. Tap the bubble icon at the top of Calls, then select a conversation.
5. For background alerts, configure [Apple push](BACKGROUND_CALLS.md), tap
   **Enable message notifications** inside Messages, and allow iOS alerts.
   An enabled missed-call badge alone does not enable message alerts.

Older relays or relays without `VPCOMM_MESSAGES_DB` show messaging unavailable;
calls still work. A recipient who has not yet enabled messaging or verified the
sender leaves new text pending. No unverified or group-call fallback is used.

## Conversation Behavior

- Text is limited to 4,096 UTF-8 bytes. Emoji/non-ASCII characters may use multiple
  bytes. Empty/whitespace-only messages cannot be sent.
- **Pending** means saved on this phone, awaiting relay acceptance.
  **Queued for delivery** means accepted by the relay.
  **Delivered** requires a verified recipient signature after decryption and
  durable local storage. It does not mean read.
- **Failed** messages offer Retry. Expired retries use a new ID and timestamp;
  other retries reuse their original ciphertext/ID to avoid duplicates.
- Pending messages retry while connected, including after relaunch. Offline
  delivery expires seven days after composing, not after the last retry.
  Keep phone clocks set automatically.
- The conversation includes that peer's uncleared missed calls and a private
  call button. Busy/disconnected/unverified states disable calling. Calling
  does not clear the missed-call badge.
- The bubble icon and conversation list show in-app unread counts. Opening a
  conversation marks it read. The Home Screen badge is **unread messages plus
  uncleared missed calls**. Reading messages removes only their part; clearing
  missed calls preserves unread messages. Simply opening the inbox marks nothing
  read. Messages received in the visible conversation are already read.
- **Clear read history** removes that conversation's read incoming and completed
  outgoing entries. It retains unread/pending entries and recent dedupe IDs.
  It does not clear missed-call history or delete the other person's messages.
- History is capped at 1,000 entries per device/relay. Clear read history when
  full; unsaved incoming text is not acknowledged. Corrupt files are preserved,
  not overwritten. Relay queue limits can also reject new text.
- Relay changes dismiss the conversation and isolate its history. Encrypted
  history remains on the phone; restoring the same relay and device identity
  restores it. There is no backup/export/import or identity-key migration.

## Background Alerts

Regular APNs alerts say only **You have a new private message.** Message text,
sender names, and photos never enter the push payload. Tapping opens Messages;
the app then reconnects and decrypts its mailbox. There is no notification
extension and no background decryption/read receipt. Canddle never uses PushKit
to deliver text.

Alerts require a signed push-capable app, matching APNs bundle/environment,
relay credentials, notification permission, network access, and Apple delivery.
Focus, OS policies, collapse behavior, and expiry can delay or suppress alerts.
One generic alert can represent several messages. The inbox is authoritative.
Without APNs, offline delivery still works when the recipient opens Canddle.

### Home Screen Badge

Enable **Badges** under iPhone **Settings > Notifications > Canddle**. You can
also request badge-only permission from Messages or the missed-call settings.
Badge permission is separate from enabling banners/sounds.

Upgrade both the app and relay, then open the app once to synchronize the
combined count. Updated relays advertise `badges: "1"` in `chat-ready`; opted-in
clients submit a bounded `chat-badge` summary and up to 32 signed delivery
receipts together. The relay atomically removes acknowledged queued copies,
stores the local count, and adds still-pending messages to subsequent APNs
badges. The aggregate count contains no text or sender names and is not a read
receipt to senders. Existing SQLite databases upgrade automatically.

Older relays still support local unread badges, but not badges for messages
waiting while the app is closed. Older apps do not opt in; their notification
payloads continue to omit badges.

While suspended, the badge is best-effort: APNs can arrive late, and a previously
scheduled missed-call deadline can overwrite a newer message badge (or vice
versa). Missed calls/read changes not yet synced are also absent from the relay's
summary. Foreground entry and mailbox sync reconcile the exact local count.
There is no notification extension to coordinate these OS writes while closed.

End-to-end encryption uses CryptoKit X25519, HKDF-SHA256, AES-GCM, and Ed25519.
This experimental protocol has **no forward secrecy or Signal-style ratchet**.
Read the [security limitations](../SECURITY.md#private-text-messages) before use.

## Automated Checks

From the repository root on macOS with Xcode and project test dependencies:

```sh
xcrun swiftc -parse-as-library iphone/Core/*.swift \
  iphone/App/LobbyStore.swift iphone/App/GroupStore.swift \
  iphone/App/MessageStore.swift iphone/Tests/MessageChecks.swift \
  -o /tmp/canddle-messages-checks
VPCOMM_MESSAGES_PROBE=/tmp/canddle-messages-checks \
  PYTHONPATH=tests:iphone/Tests python -m pytest iphone/Tests/test_messaging.py -q
python -m pytest tests/test_messages.py tests/test_push.py -q
```

Coverage includes tamper/expiry rejection, Swift/Python crypto interoperability,
encrypted persistence and dedupe, signed receipts, offline/reconnect delivery,
capability absence, call coexistence, revocation, bounds, and queue backpressure.
Direct source compilation does not validate signing, installation or APNs.

## Two-Phone Release Checks

- Exchange text after mutual verification; confirm pending, queued and delivered
  states. Inspect long text, emoji, keyboard layout, scrolling, and accessibility.
- Background/lock the recipient and send text. Confirm a generic Canddle alert,
  no caller screen, no plaintext/name in the preview, and an increased combined badge.
- Start with two missed calls and send three messages: after sync the badge should
  be five. Read the messages: it should be two. Clear missed calls while messages
  remain unread: only the missed-call portion should disappear.
- Test duplicate delivery, relaunch with unread text, messages in the visible
  conversation, and a message arriving near a missed-call deadline. Verify the
  count reconciles after foreground sync, with badges both enabled and denied.
- Tap the alert; confirm correct inbox, one message, correct sender/photo, unread
  clearing, and the sender's eventual Delivered state.
- Deny notification permission, enable it later in Settings, and repeat.
  Test development APNs and production/TestFlight separately.
- Disconnect the sender, compose text, relaunch, and reconnect. Then repeat with
  only the recipient offline. Confirm retry does not duplicate the message.
- Exchange messages while a call rings and while audio is active. Answer, hang up,
  and change networks; verify call controls/audio remain responsive.
- Remove verification and change/forget the relay. Confirm no send to the old
  peer, no old conversation shown under the new relay, and scoped photo fallback.
- Clear read history, reconnect, and confirm no duplicate history reappears.
  Exercise seven-day expiry and full storage in controlled test fixtures.

Real-device APNs, notification UI, audio coexistence, and deployment smoke checks
must be completed before distributing this feature to family devices.
