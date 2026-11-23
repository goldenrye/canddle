# Private Messages

Canddle supports one-to-one text and photos between previously verified iPhone device keys.
The desktop client does not implement chat. Group chat, other attachments, reactions,
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

## Send a Photo

Upgrade the relay and both iPhone apps, then open Canddle on both phones once.
In a conversation, tap the photo icon, choose one image, review the preview,
and tap **Send photo**. Tap a received or sent photo to open it full-screen.
Text drafts are separate and remain in the composer.

To paste a picture, use **Copy Image** in another app (or copy a screenshot),
then tap **Paste** beside the conversation's photo icon. Review the image and
tap **Send photo**; pasting never sends automatically or replaces your text draft.
The iOS system Paste button accepts image content, not a copied URL or plain text,
and is unavailable when the clipboard has no compatible image. Regular text paste
in the message field remains unchanged. There is no automatic clipboard read.

Long-press a sent/received picture and choose **Copy photo**, or open it full-screen
and tap **Copy photo**. This copies the resized JPEG, not the original source file.
An explicitly copied photo is on the system clipboard in readable form and can be
pasted into other apps; clipboard protections are separate from message encryption.

The system picker grants access only to the selected image; full photo-library
permission is not required. The app accepts source images up to 25 MB, corrects
orientation, preserves aspect ratio, and sends a JPEG copy at most 1,280 pixels
on its longest side and 128 KiB. Original filenames, GPS and capture metadata
are not copied. Photos are compressed, not original-quality file transfers;
animated images/Live Photos send a single still frame. Camera capture, videos,
captions, saving to Files/Photos, and other file types are not included.

Photo bytes and local history are end-to-end encrypted like text. The relay
can observe that a message is a photo and its encrypted size, but cannot see
the image. Generic push notifications and unread badges work the same as text.
Delivery requires successful image validation and durable storage on the recipient.

An authenticated, short-lived connection to the same `/relay` endpoint handles
each photo upload/download/status check, independently of the call-signaling socket.
Failed transfers retry from the beginning using the same ciphertext/ID; queued
photos poll a small status message instead of repeatedly uploading the image.
They still share the phone's bandwidth, so photo traffic can compete with audio
on poor coverage. Polling can add about 15 seconds before delivery.

Older apps keep exchanging text. Updated relays advertise `photos: "1"` in
`chat-ready`; only updated recipients publish a separately signed photo key.
The photo button requires a connection to a photo-capable relay. Photos already
saved in the outbox survive disconnection/relaunch and retry. A text-only
recipient leaves a photo pending with an upgrade/verification explanation.
No new public port, service, or environment variable is required.

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
- History is capped at 1,000 entries and 24 MB of encrypted storage per device/relay.
  Photos can fill this before the entry limit. Clear read history when full;
  unsaved incoming messages are not acknowledged. Corrupt files are preserved,
  not overwritten. Relay queues also have record and byte limits.
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
capability absence, photo orientation/metadata removal, photo offline delivery,
call coexistence, revocation, byte bounds, and queue backpressure.
Direct source compilation does not validate signing, installation or APNs.

## Two-Phone Release Checks

- Copy an image from Photos, Safari's Copy Image action, and a screenshot; tap
  Paste, preview, remove/replace, then Send photo. Confirm a text draft survives,
  plain text/URL-only clipboard content does not become a photo, and opening a
  conversation never reads the clipboard. Copy a received photo and paste it
  into another conversation. Check narrow screens and large accessibility text.
- Leave the conversation or change relays while a large pasted image is loading.
  Confirm the late result does not create a draft in the new conversation.
- Choose portrait/landscape, HEIC, rotated, transparent, and large photos. Confirm
  the preview, explicit Send photo, full-screen viewing, and canceled selection.
  Check metadata removal and quality on the received JPEG. Incoming messages
  while the picker/viewer is covering the conversation should stay unread until
  returning to the conversation.
- Send a photo while the recipient is offline, reconnect, and confirm exactly
  one image, one unread badge, and eventual Delivered status. Interrupt a transfer
  with Wi-Fi/cellular changes and verify retry without duplicate messages.
- Exchange photos while a call rings and while audio is active. Confirm that
  photo failure does not disconnect call signaling. Check bandwidth effects on
  a slow cellular connection and pending photos to text-only recipients.

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
