# Security Model and Wire Protocol

## Intended Protection

The intent is audio-content confidentiality and integrity between trusted
installations, even when the relay or network is untrusted. Manual calls support
two participants; native iPhone group calls support up to six. The relay
terminates TLS but receives only end-to-end ciphertext after the handshake.
TLS remains necessary to protect relay credentials and reduce exposure of
room identifiers and handshake metadata to network observers.

This is an experimental application protocol using standard cryptographic
primitives, not a standardized or independently audited secure messenger.
Passing tests does not prove its security. Do not treat stage one as approved
for high-sensitivity use.

## Assumptions and Limitations

- Clients, operating systems, audio devices, dependencies, and the initial
  application distribution must be trustworthy. Malware can read audio before
  encryption or after decryption.
- With manual calling, the invitation must reach the intended participant over an authenticated,
  confidential channel. Anyone holding its secret can impersonate a
  participant, including a malicious relay that obtains it.
- Sharing an invitation in a messenger transfers trust to that messenger for
  that call's initial authentication. For stronger assurance, exchange it in
  person or over an already authenticated encrypted channel.
- The manual audio protocol uses group-secret authentication for a group of two. The
  optional iPhone lobby adds verified device-key authentication for invitation
  delivery, not proof of a person's real-world identity. A relay token is not a peer identity.
- Compare the session verification code through an independent trusted channel.
  A mismatch requires hanging up. This check is user-operated, not a UI gate;
  the microphone opens after authenticated key confirmation.
- The other participant can record or retransmit the conversation.
- AWS, the network, and the relay can observe source IPs, connection timing,
  duration, packet sizes, approximate usage, and denial-of-service effects.
  The relay also sees room identifiers and ephemeral public handshake data.
- No anonymity, metadata-hiding, censorship-resistance, or availability claim
  is made. Network operators can block this traffic.
- Python does not guarantee erasure of secret material from memory. Process
  dumps, swap, terminal scrollback, clipboard history, and OS snapshots matter.
- Dependencies and desktop updates must be obtained through trusted channels.
  The client is installed locally; it is not mutable JavaScript served by
  the relay. A malicious client update can defeat encryption.
- There is no in-call key ratchet or post-compromise recovery. A compromised
  active session key exposes its direction for that session.

## Credential Separation

`VPCOMM_ACCESS_TOKEN` is a server-wide bearer credential. It is supplied in the
HTTP `Authorization` header inside TLS, and visible to the proxy and server.
It authorizes resource use only. Generate it from at least 32 random bytes.

An invitation is generated locally:

```text
vp1.<base64url-no-padding(16 random room bytes)>.<base64url-no-padding(32 random secret bytes)>
```

The room identifier alone goes to the relay. The invitation secret never does.
Do not replace the invitation secret with a memorable password: handshake
proofs permit offline guessing of low-entropy secrets.

Generate a new invitation for every call. The relay does not persist a spent
invitation database, so the one-time recommendation is a client/user policy,
not a server-enforced property. The GUI clears an invitation at hang-up;
terminal callers must avoid reuse themselves.

## Transport

### Optional QR Pairing

Pairing provisions relay access, not peer identity or audio keys. Only an
administrator with access to the relay user's private local Unix socket can
mint codes. The server must explicitly enable it with a public `wss` relay URL.

The QR is JSON: `{"type":"vpcomm-pair","v":1,"relay":"wss://host/relay","code":"..."}`.
The code is 32 random bytes encoded as canonical unpadded base64url. Only its
SHA-256 digest and monotonic two-minute deadline are stored in server memory.
At most 16 codes exist; restart and admin revocation invalidate outstanding codes.
The trusted SSH terminal/screen is the bootstrap authentication channel.
Anyone obtaining the QR before use can race the intended user and gain access.

The iPhone validates the payload, requires user confirmation of the destination,
and issues `GET https://host/pair` with `Authorization: Pair <code>`. This is a
native capability exchange over TLS, not a public token-discovery endpoint.
GET is used because the relay's HTTP handshake hook only accepts GET; possession
of the explicit authorization header is required and redemption is intentionally
non-idempotent. No code goes in the URL. Browser origins and WebSocket upgrades
are rejected, and there is no CORS allowance. Consumption is atomic before the
response: `{"v":1,"relay":"wss://host/relay","token":"..."}`.

TLS validates hostname/chain/expiry; redirects are rejected. Custom CA trust must
be established independently before pairing, never from the QR. Responses are
marked `no-store` and the client uses an ephemeral session, a ten-second deadline,
and an 8 KiB response limit. Request headers and response bodies must not be
logged. The proxy and server necessarily see the capability and token.
Cancellation or a lost response may burn a code; issue a fresh one.

The iPhone atomically saves the returned pair in its device-only Keychain only
after success. This remains a shared bearer token: an authorized phone can
disclose it, there is no per-device revocation or automatic rotation, and
revoking unused codes does not revoke tokens already obtained. Rotate the
server token and re-pair trusted clients if access is compromised.
Global pairing rate limiting is not DDoS protection.

### Calling Transport

- Production endpoint: `wss://<host>/relay`.
- `ws://` is accepted by the client only for the literal hostnames `localhost`,
  `127.0.0.1`, and `::1`, for development. Remote plaintext URLs are rejected.
- Server TLS certificates are validated with hostname verification. `--ca`
  chooses a private trust root; there is no insecure/skip-validation option.
- Client proxy auto-discovery is disabled. No external media service is called.
- WebSocket compression is disabled. The transport receive ceiling is 8192 bytes
  for group rosters; manual room frames and legacy lobby frames remain limited
  to 1024 bytes by their handlers. Manual room payloads must be binary after join.
- Initial join: `{"v":1,"room":"<room identifier>"}` as a text frame.
- Relay responses are `{"type":"waiting"}` followed by `{"type":"ready"}`, or
  just `{"type":"ready"}` for the second participant.
- Exactly two sockets occupy a room. Either socket closing ends both sides.
  The server reserves a closing room until socket closure completes, then
  removes it. No reconnect/resume state is retained.
- `/healthz` is intentionally unauthenticated and returns only `ok`.
- Browser-originated WebSocket requests are rejected. The protocol is for a
  locally installed native client, not a web page.

### Legacy Two-Person Lobby

This v1 path is retained for older clients and regression tests. The current
iPhone app uses group v2, specified next, not this single-winner flow.

The native iPhone lobby starts with `{"v":1,"lobby":true}` instead of a room join
on the same bearer-authenticated `/relay` WebSocket. Lobby frames are text JSON,
at most 1024 bytes. This is a separate state machine from the binary audio path.
It is foreground-only, with no push service, background ringing, or reconnect.
Existing desktop clients continue using manual invitations.

Each phone generates a persistent Ed25519 signing key. Its private bytes and
verified peer keys/names are stored in the unlocked, device-only, nonsynchronizing
Keychain. Peer trust is scoped to the exact relay URL and raw public signing key,
not a name. A changed key always appears unverified. Names are untrusted metadata;
the UI labels unknown keys explicitly and keeps a verified peer's original saved
name. Trust is established by independently comparing the full per-request
96-bit code on both phones. Both participants must perform that check for a new
peer; clicking a match button without checking does not establish safe identity.
No server-delivered certificate, name, access token, or key alone establishes trust.

For the following protocol, define:

```text
T(purpose, fields...) =
  ASCII("vpcomm/lobby/v1/") || ASCII(purpose) || 0x00 ||
  concat(uint32-big-endian(len(UTF8(field))) || UTF8(field))
```

All binary JSON values are canonical unpadded base64url. IDs are 16 bytes,
public keys 32 bytes, Ed25519 signatures 64 bytes. Names contain 1-40 printable
ASCII characters. Signatures bind these names but do not certify them.

1. Server sends a fresh 32-byte `challenge`. Client sends `register` with
   `identity`, `name`, and an Ed25519 signature over
   `T("register", challenge, identity, name)`. Duplicate connected identities
   and replayed registration signatures are rejected by the honest server.
2. Caller generates an independent random audio invitation, a fresh X25519
   ephemeral key, and a random call ID. It sends `offer` with `call`, `identity`,
   `ephemeral`, `name`, and signature over `T("offer", O...)`, where
   `O = [call, callerIdentity, callerEphemeral, callerName]`.
   The server broadcasts this metadata, not the invitation or its room ID.
3. Requester verifies the offer signature and generates a fresh ephemeral key
   and request ID. It sends `request` with `call`, `request`, `identity`,
   `ephemeral`, `name`, and signature over `T("request", O..., R...)`, where
   `R = [request, requesterIdentity, requesterEphemeral, requesterName]`.
   Server forwards it only to the caller, who verifies the signature and binding.
4. Both derive `binding = T("exchange", O..., R...)` and
   `material = HKDF-SHA256(X25519(localEphemeralPrivate, peerEphemeralPublic),
   salt=SHA256(binding), info=binding, length=64)`. The first 32 bytes form the
   invitation AES-256-GCM key; the last 32 form a separate confirmation HMAC key.
   The displayed code is the first 12 bytes of
   `SHA256(T("verify") || binding || material)`, formatted as six four-hex groups.
5. After verifying the caller (or matching a remembered key), the requester
   explicitly confirms. It sends `confirm` with call/request IDs and
   `proof = HMAC-SHA256(confirmationKey, T("confirmed") || binding)`.
   The caller must verify this key-possession proof before enabling approval.
   New trust is saved before sending confirmation or approval; storage failure
   blocks that operation.
6. After independently verifying the requester and explicitly approving, caller
   sends `approve` with call/request IDs and `box`. This is AES-GCM encryption of
   the 70-byte invitation, authenticating `binding`, with a fresh random 12-byte
   nonce. The encoded box is `nonce || ciphertext || 16-byte tag` (98 bytes).
   Only the selected requester can decrypt it. The honest server requires a
   pending, confirmed request and the offer's owning socket.
7. Without yielding, the server enqueues the box to the selected requester,
   `granted` to the caller, and closes the announcement and all requests. Only one
   approval wins. Each client accepts success only for its own current operation
   (and only after local confirmation/approval), clears pending state, leaves the
   lobby, and starts the existing authenticated audio handshake automatically.

The server cannot validate the HMAC or decrypt the box; the endpoints do that.
The server's grant/close events are coordination, not cryptographic authorization.
The clients authenticate using signatures, remembered keys/independent code
comparison, the confirmation HMAC, and invitation AEAD bound to both identities,
ephemeral keys, roles, names, and request/call IDs. A malicious relay can suppress,
replay announcements, reorder metadata, or terminate calls, but cannot deliver a
valid invitation to a substituted verified key. Recorded boxes do not authenticate
under a fresh request transcript. UI state consumes an approval only once.
Ephemeral invitation-transfer keys are not persisted and give forward secrecy
against later signing-key compromise, subject to the usual memory-erasure limits.

Offers expire after two minutes; cancel, rejection, disconnect, expiry, or
backgrounding clears pending state. Delivery is not transactional across phones:
an approval lost during disconnect may require a new call. A server acknowledgment
does not prove that the peer has opened its microphone. The existing audio
handshake and bidirectional key confirmation remain required before capture.

Lobby sockets share the server connection cap with audio. Each device has at most
one offer or outgoing request; each offer holds at most 16 requests. Outbound
queues hold 64 messages and slow peers are disconnected. Sends have three-second
deadlines; incoming messages have a 12-message burst / 2-per-second refill.
Client heartbeats run every 15 seconds, server inactivity limit is 45 seconds,
and sessions end after one hour. These are resource bounds, not DDoS protection.

The relay sees stable public device keys, names, availability, request/approval
timing, and encrypted invitation boxes. Every connected lobby client sees call
announcements, including newly connected clients while an offer is open. There
is no server-side contact list or per-device access revocation; possession of
the shared token permits lobby access. Removing peer trust is distinct from
revoking relay access. Protect the token and rotate it if compromised.

### Foreground Group Calls (v2)

The new iPhone UI uses `{"v":2,"group":true}` on the same authenticated `/relay`
endpoint. Legacy lobby and group discovery are separate. No extra port or
database is required. One relay/token defines one announcement group; this is
not a fine-grained group-membership directory or per-device authorization system.
Any token holder may discover group calls or request admission. Callers must verify
unknown device identities. Manual acceptance of each participant is the default.
The opt-in, locally persisted **Auto-accept verified family devices** preference
authorizes automatic admission of all device keys previously verified on the
current relay, not a separate family allowlist. A valid signed request and verified
confirmation proof are still required, and admission uses the same caller-signed
roster and six-person limit. Names and presence never qualify a device.
Rejected, ignored, and removed keys are blocked from automatic admission for the
remainder of that call. First-time trust still requires manual acceptance.
Join notifications are emitted after authenticated roster updates; enabling this
policy does not automatically answer incoming calls or enable microphone capture
on push receipt.

Registration, offers, requests, first-time code comparison and confirmation
HMAC reuse the v1 signed transcripts described above. No v1 invitation or
`approve` ciphertext is generated for group calls. On a known caller, tapping
**Join call** automatically sends the confirmation proof after the signed request.
Unknown callers still require independent code comparison and a one-time explicit
confirmation. The host verifies the HMAC and saves verified trust before Accept.
Reject removes the pending request; Ignore hides it locally until its two-minute
expiry. Neither permits access.

**Membership authority:** all participants trust the independently verified
caller to choose other members. This is a caller-controlled group, not consensus,
distributed administration, MLS, or individually verified full-mesh contacts.
Every phone displays the current authorized participants and public-key
fingerprints. Caller departure ends the call; there is no host migration.
As with any authorized endpoint, a malicious caller can record or forward audio.

On each acceptance, removal or departure the caller creates a signed roster:

```text
{
  "type": "roster", "call": callID, "revision": decimalUInt64,
  "epoch": base64url(32 random bytes),
  "members": JSON string containing an array of original offer/request objects,
  "signature": base64url(Ed25519 signature)
}

binding = T("group-roster", callID, revision, epoch, membersString)
signature = Ed25519.sign(callerSigningKey, binding)
```

The exact members string is signed, avoiding cross-language JSON canonicalization.
There must be one unchanged caller offer and up to five distinct signed requests
bound to it. Clients verify every entry's signature and the caller signature,
and check their own entry against their locally generated offer/request.
The caller accepts only its exact outstanding proposal echoed by the server.
An existing member requires revision + 1; a newly admitted member can enter at a
later revision. Non-increasing revisions fail closed. The honest server requires
the owner socket, unchanged existing entries, at most one new confirmed request,
and at most six members. The full decision is validated before mutating state.
A request that disappeared during approval produces a retry without admission.
Removing a member sends them the signed exclusion and immediately disables
their server routing. Disconnects pause media until a caller-signed update.

**Pairwise keys:** every call participant has a fresh X25519 ephemeral private
key corresponding to their signed offer/request. For each distinct pair, sort
their canonical base64url signing-key identity strings lexicographically (ASCII):

```text
context = T("group-media", smallerIdentity, largerIdentity) || binding
digest = SHA256(context)
material = HKDF-SHA256(
    X25519(ownEphemeralPrivate, peerEphemeralPublic),
    salt=digest, info=context, length=64)
```

The smaller identity sends with material[0:32] and receives with material[32:64];
the larger uses the reverse. Group media reuses `CallKeys` AES-256-GCM counter
framing with `digest` as the authenticated binding, but starts audio at counter
zero (there is no v1 room confirmation message). Signed keys, the requester's
ephemeral-possession proof to the host, verified host authority, and the signed
roster authenticate admission. After accepting the roster the app opens the
microphone; acceptance does not guarantee every other phone's microphone is ready.

```text
client -> relay: recipient signing key (32 bytes) || revision (8 bytes BE) ||
                 counter (8 bytes BE) || encrypted audio (641 bytes) || tag (16 bytes)
relay -> client: sender signing key (32 bytes) || same remaining bytes
```

Each frame is exactly 705 bytes. The server supplies the sender from the
authenticated socket and routes only within the current roster. Clients select
the pairwise receiving key by sender and authenticate the frame with the complete
roster binding. A third member has no key for either direction of another pair.
Counter replay, tampering and future epochs fail closed. Old-epoch in-flight
frames are dropped. On membership change clients replace keys/counters and clear
all old playback queues. Different revisions and roster bindings prevent nonce
reuse under the same key. Phones decrypt and mix locally, never at the relay.

No shared group audio secret is sent to new members. A late joiner has no pairwise
secret for older members' prior conversations. A removed member is excluded from
new rosters and has no pairwise secret between remaining participants. The public
roster alone provides no decryption ability. Existing members may of course
disclose prior audio or their secrets. Every pair's media key changes with each
roster, but the per-call X25519 private keys are retained for later joins.
Consequently this is **not** an epoch forward-secure ratchet: compromise of a
participant's per-call private key exposes that participant's recorded links for
that call. There is no post-compromise recovery. Fresh per-call X25519 keys provide
protection against later compromise of long-term signing keys alone, subject to
memory-erasure limitations.

The caller's announcement remains discoverable while the call runs. Unanswered
offers expire in two minutes; after first admission the call lifetime is bounded
by the host's one-hour connection lifetime. Each pending request independently
expires in two minutes. One socket per phone shares the server's total connection
budget. Group text frames are capped at 8192 bytes; media at 705. Each sender has
a 600-frame burst and 300 frames/second refill (up to five 50-fps destinations).
Control messages retain the 12-message burst / 2-per-second refill. Queues hold
64 outbound messages; blocked peers are disconnected, not silently dropped within
an epoch. Sends time out at three seconds. Fifteen-second heartbeats and
45-second inactivity deadlines remain. These bounds do not prevent DDoS.

Optional APNs VoIP delivery and CallKit provide background/lock-screen ringing.
Apple receives signed public offer metadata, relay URL, recipient public key and
expiry, but no bearer credentials, private keys or audio. Registrations use
authenticated device sessions, a private bounded SQLite store, seven-day expiry,
access-token rotation revocation, and invalid-token removal. Delivery is bounded
and best-effort. See [Background Calls](iphone/BACKGROUND_CALLS.md).
Configured iPhones automatically open
the authenticated group connection while active on Calls, retrying disconnected
listeners every five seconds. Settings pauses automatic attempts; backgrounding
disconnects idle sockets. Accepted CallKit audio continues while locked.
Reconnection never restores call membership or starts the microphone.
Keychain credentials, public CA trust, identity and verified peers are now
device-only, accessible after first unlock, to support push-launched call answering.
CallKit answer does not bypass first-time identity verification or caller admission
policy (manual by default, optionally automatic for already verified devices).
The relay learns identities, roster
membership, names, call timing and traffic volume. A malicious relay can deny
service or suppress updates; authentication does not guarantee delivery, a
globally consistent view, or instant revocation to disconnected endpoints.
Use an established, independently reviewed group/media protocol before treating
this implementation as production-grade secure communications.

### Individual Calls (v2 Extension)

The relay advertises `"direct":"1"` in its registration challenge. New clients
send `{"type":"direct-enable"}` after registration; unsupported clients are never
sent individual offers. Missing capability disables individual calling, without
falling back to group broadcasting.

An individual offer adds `target`, the selected recipient's 32-byte signing key.
Its signature is `T("direct-offer", O..., target)`, not `T("offer", O...)`.
Removing or replacing the target invalidates the signature. Request signatures,
exchange key derivation, confirmation proofs and verification codes include the
target by appending it to the offer fields. Both clients and the relay reject
requests from any other identity. Signed rosters must contain exactly the original
caller and selected recipient, with their original offer/request entries.

An honest relay sends the offer and closure only to these two capable clients,
including an offline recipient that later connects and opts in. APNs delivery is
filtered to the selected identity. The selected recipient can decline before
joining. Decline, withdrawal, rejection, expiry or either party disconnecting ends
the individual call. Audio uses the existing pairwise encrypted transport.

Explicitly selecting an already verified device authorizes its automatic admission
after a signed request and valid confirmation, independently of the group
auto-accept preference. The receiver must explicitly Answer. Unknown keys still
require independent code comparison and manual verification. The two-person
restriction is also checked at the endpoints, not just by relay routing.

This is not metadata anonymity: the relay and Apple see public offer metadata,
and other group members can still see generic presence/calling state. A malicious
relay could disclose offer metadata but cannot forge a different signed target or
authorize an outsider in a roster accepted by an honest client. Either authorized
endpoint can still record or forward audio.

## Authenticated Key Exchange (Manual Calls)

All byte concatenations below have fixed-width components except the fixed
context string. Both endpoints independently generate fresh X25519 private
keys per connection. Public keys are 32 raw bytes.

Context is exactly the following ASCII byte string, without a newline:

```text
vpcomm/v1/x25519-hkdf-sha256-aes256gcm/pcm16le-16000-320
```

After `ready`, each client sends one binary UTF-8 JSON frame containing:

```json
{"v":1,"public":"<32-byte public key, base64url>","proof":"<32-byte HMAC, base64url>"}
```

Proof:

```text
HMAC-SHA256(invitation_secret, context || room_bytes || public_key)
```

Each client requires version 1, canonical encodings, a valid proof, a peer
public key different from its own, and a valid nonzero X25519 shared secret.
Sort the two public keys lexicographically by their raw byte values:

```text
transcript = context || room_bytes || smaller_public || larger_public
material = HKDF-SHA256(
    IKM = X25519(local_private, peer_public),
    salt = invitation_secret,
    info = transcript,
    length = 64
)
```

The endpoint with the smaller public key sends using the first 32 material
bytes and receives using the last 32. The other endpoint uses the reverse
assignment. Distinct directional keys prevent reflection and nonce sharing.

Clients send an encrypted confirmation plaintext of exactly:

```text
0x00 || ASCII("vpcomm/v1/confirmed")
```

Both sides must successfully decrypt the peer confirmation before audio
devices are opened. This provides fresh shared-key possession confirmation;
a recorded valid hello alone cannot establish a call.

The displayed verification code is the first 24 hexadecimal characters
(96 bits) of:

```text
SHA256(ASCII("verification") || transcript || material)
```

It is grouped into six four-character groups. It is not an encryption key.

Ephemeral X25519 keys provide forward secrecy against later invitation-secret
disclosure, assuming the ephemeral private/session keys are no longer
recoverable. Python memory behavior means secure erasure is not guaranteed.

## Encrypted Frames

AES-256-GCM with a 128-bit authentication tag:

```text
counter = unsigned 64-bit big-endian integer, starts at 0 independently per direction
nonce   = 4 zero bytes || counter
AAD     = SHA256(transcript) || counter
packet  = counter || AESGCM.encrypt(nonce, plaintext, AAD)
```

Each directional key is fresh for a call. Counters must match the next
expected value exactly. Authentication failures do not advance counters.
Counter exhaustion at 2^32 frames is rejected; default server call limits
expire much earlier.

The confirmation consumes counter zero. Each subsequent audio plaintext is:

```text
0x01 || 640 bytes of PCM16 little-endian mono, 16000 Hz, 320 samples
```

Encrypted audio packets are 665 bytes. There is no codec negotiation in v1.
Any wrong encrypted payload type, size, order, authentication, or peer
confirmation ends the call. Muted frames contain encrypted silence at the same
nominal rate. Device scheduling and TCP behavior mean this is not rigorous
constant-rate traffic padding.

## Resource and Logging Policy

Group clients may opt into relay presence after capability discovery in the
registration challenge. Authenticated group devices can then see other connected
group devices' public keys, registered names, and calling/joining/admitted states.
Snapshots are bounded to 32 entries, coalesced, and sent only when changed.
Presence is relay-asserted metadata, not end-to-end proof of identity or audio
activity, and never grants admission or bypasses peer verification. Discovered
names are cached in memory (up to 128); saved verified names remain relay-scoped.
The group directory prefers current, then session-cached names over saved verified
names. A differing original verified name remains visible in identity details;
presence updates never overwrite saved trust or change admission decisions.
Disconnected devices may still be reachable by APNs. No push tokens, access
tokens, or private keys are included in presence messages.

The manual relay path has a connection admission limit, per-socket 60-frame/s replenishing
budget with a 100-frame burst, 1024-byte message limit, bounded WebSocket queues,
bounded sends, wait/call timeouts, and ping-based liveness. Audio device queues
hold at most five frames per direction. Full queues discard the oldest
untransmitted/unplayed audio. Encrypted stream counters remain contiguous.

These controls do not stop network floods, TLS exhaustion, or cost attacks.
Use security-group restrictions and protect the relay token.

The server does not persist audio, invitations, rooms, or contacts. The iPhone
does persist its lobby signing identity and verified peer keys in the Keychain.
Operational
warnings/errors can be logged. Caddy access logs are disabled in the supplied
configuration. Administrators can still enable packet capture or logging;
encryption does not make those capabilities disappear.

## Before Production

Obtain an independent protocol and implementation review, assess using a
well-reviewed established secure media protocol, add interoperability vectors,
test actual desktop hardware and hostile network conditions, harden abuse
controls, introduce authenticated contact identities and signed updates, and
define an explicit vulnerability-response/update process.
