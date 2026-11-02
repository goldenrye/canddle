# iPhone Client

The installed app is named **canddle** and uses the supplied six-can-and-flame
artwork for its icon and in-app branding. The Xcode project and target are named
`Canddle`; the bundle identifier is unchanged, preserving existing Keychain
settings when updating with the same signing identity.

A fresh native SwiftUI implementation for iOS 16+, using only Apple frameworks.
Manual calls work with the existing Python desktop client and relay. The
group calls require the updated server and iPhone app on every phone.
Background/lock-screen ringing uses optional APNs provisioning; see
[Background Calls](BACKGROUND_CALLS.md) for setup, limitations and device tests.
Optional QR pairing requires the updated relay and proxy configuration below.
The source project is self-contained: no package downloads or project generator
are needed.

## Install

1. Open `iphone/Canddle.xcodeproj` in Xcode 15 or newer.
2. Select the **Canddle** target and open **Signing & Capabilities**.
3. Select your development team. Change `com.jpi.canddle` to a unique bundle
   identifier if required for your account.
4. Connect your iPhone, select it as the run destination, enable Developer Mode
   when prompted, and click Run.
5. Grant microphone access when starting a call.

No signing credentials are stored here. Local personal-device provisioning is
subject to Apple's current personal-team restrictions and expiry. App Store or
TestFlight distribution generally requires Apple Developer Program membership.
This is a development project, not an App Store-ready release:
distribution signing, privacy declarations, export compliance, and submission
review remain release tasks.

## Call a Desktop or Another iPhone

Use a relay deployed according to [`../deploy/README.md`](../deploy/README.md).

### Pair Without Typing a Token

1. Ask your server administrator to enable pairing and run
   `docker compose exec -T relay vpcomm-pair` over authenticated SSH.
2. For a private-CA server, import its public CA and verify the fingerprint first
   using the TLS instructions below. Publicly trusted servers need no import.
3. Open **Settings > Pair with QR** and allow camera access. Scan the terminal's QR within
   two minutes. Keep the QR private; whoever redeems it first gets relay access.
4. Confirm the displayed server is yours, then tap **Pair and save**. The app
   retrieves the token over verified HTTPS and saves the address/token together
   in the device-only Keychain. No invitation or audio is sent during pairing.
5. Return to **Calls**. The app connects automatically to receive calls.

The QR is single-use, contains no permanent token, and does not change certificate
trust. The app never follows pairing redirects or opens the QR in a browser.
Camera frames are used only for local scanning and are not recorded/uploaded.
Backgrounding cancels pairing. If it fails, previous settings are preserved;
request a fresh QR because the previous one may already have been consumed.
Pairing replaces the saved relay only after successful Keychain storage.

This is one-time credential provisioning, not ongoing automatic synchronization.
If the administrator rotates the shared relay token, pair again.

### Group Calls Without Copying Invitations

1. Upgrade the relay (`docker compose up -d --build`) and install the updated app
   on every phone. Keep the same WSS address and saved access token.
2. Set a recognizable device name in **Settings**, then tap **Save name**. On **Calls**, receivers
   connect automatically and keep the app open. The caller taps **Start call**, which
   connects automatically if needed and announces the call.
3. Other connected clients receive an in-app banner and a system alert sound
   (subject to device sound settings). A phone connecting later also sees the
   ongoing call. Tap **Join call** to request admission.
4. For a previously verified caller, Join call is the only requester action.
   The caller chooses **Accept**, **Reject**, or **Ignore** for each request.
   Ignore hides the request locally; it expires without granting access.
5. On a first call with an **unverified** device, compare the entire displayed
   security code in person or over an independent trusted channel. The requester
   confirms the match once and the caller chooses **Codes match: verify and
   accept**. Each phone remembers the other's device key in its Keychain.
   A name alone is not identity. A changed key requires verification again.
6. Once accepted, the microphone starts and everyone listed under
   **Participants** can hear and talk. Grant microphone access if prompted.
   The announcement stays open and the caller can accept later joiners while
   talking. Up to **six participants**, including the caller, are supported.
7. Participants can **Leave call**; the caller can expand a participant's row to
   **Remove participant**, or use **End for everyone** in the bottom bar. The caller must remain connected. If the caller
   disconnects, the whole call ends. Accepted CallKit calls continue while locked. Another
   participant leaving does not end the remaining participants' call.

The group is the set of people provisioned with this relay's access token,
not a separate contacts database or named-group feature. Use separate relay
instances for independently managed groups. Every online group client can see
announcements, but only accepted participants receive authenticated media links.
Participants trust the verified caller to authorize the roster; they do not
individually verify every other member. Always check the participant list.

Unanswered announcements and individual join requests expire after two minutes.
The first acceptance keeps the announcement open for the call. Connections
have a one-hour maximum lifetime from going online, so a caller already online
for a long time has less call time remaining. The app automatically reconnects
to receive future calls on launch, foreground return, and return from Settings.
While active, it checks every five seconds and retries disconnected listening
connections. It never automatically restarts or rejoins a call; there is no host migration.
With APNs configured and the app properly provisioned, PushKit wakes a
backgrounded/locked iPhone and CallKit presents the incoming call. Without APNs,
announcements remain foreground-only. See [Background Calls](BACKGROUND_CALLS.md).

Group v2 uses a persistent socket and caller-signed membership epochs with
separate encryption keys between each pair of phones. Phones mix audio locally;
the relay cannot decrypt or mix it. No shared audio invitation needs copying.
Old two-person lobby clients and desktop clients do not appear in group v2;
desktop/manual-invitation calling remains compatible on the same server.

The main screen only shows call actions, relevant requests and participants.
Mute and leave/end controls stay in a bottom bar during calls. Device keys are
expandable; unknown-device verification stays visible when approval requires it.
After confirming a new caller, the requester can still expand **Compare security
code** to help the caller complete their comparison.

Use **Settings > Go offline** before editing connection settings. Settings are
unavailable while a call or join request is active; finish or cancel it first.
Automatic connection attempts pause in Settings and resume when you return to Calls.
Device names can be edited without first going offline: **Save name** replaces the
idle connection and remembers the name locally across launches. Use 1-40 printable
English characters. Names cannot change during a call or pending join request.
Previously verified peers may continue displaying the name they saved for your key.
**Advanced > Reset saved settings >**
**Forget verified peers** removes all saved peer trust (up to 100 keys across
relays) while retaining your own device identity. In the same section, **Forget saved relay** deletes
the relay address/token, not the separate device identity or peer trust. These
Keychain entries may survive reinstall, are not synced to iCloud, and are
accessible after the first unlock following reboot. Invitations and ephemeral
encryption keys are never stored. Failed trust writes prevent confirmation or
approval, rather than silently treating the peer as verified.

### Manual Connection Setup

1. Open **Settings > Enter connection manually**.
2. Enter the exact relay URL, for example
   `wss://voice.example.com/relay` or `wss://voice.example.com:8443/relay`.
3. Enter the relay access token. It is different from the invitation. The
   address and token save automatically and are restored next time.
4. Return to **Calls**. No invitation needs to be generated or pasted.

The legacy **Start / Join**, **New invitation**, paste and copy controls have been
removed from the iPhone interface. Legacy transport remains in the codebase for
compatibility tests; desktop manual calls still work with the relay. The current
iPhone interface is group-call only.

The address and token are stored together in the iPhone Keychain, accessible
after the first unlock following reboot, without iCloud synchronization or migration to another
device. Use **Forget saved relay** to delete them. Keychain data may survive
app deletion, so explicitly forget it before removing the app when needed.
If saving fails, the app displays a warning instead of claiming it was saved.
Invitations and session keys are never saved. Imported public CA certificates
persist with the relay credentials so a push-launched app can validate its server.

Accepted CallKit group calls continue when switching apps or locking the phone.
Keep the caller foregrounded while waiting for the first admission.

## TLS and Private Certificates

The app accepts only `wss://` and never bypasses TLS validation. A custom port,
including 8443, is supported. No App Transport Security exceptions are enabled.

For a normal publicly trusted certificate, leave certificate trust unchanged.

For the Caddy private-CA deployment:

1. Export the server's **public root certificate** following the deployment
   guide. Never transfer a private key to the iPhone.
2. Transfer that certificate securely to Files on your phone.
3. Open **Settings > Advanced > Certificate trust > Choose private CA certificate**.
   Choose one PEM or DER root certificate.
4. Verify the displayed SHA-256 fingerprint against a trusted computer:

   ```bash
   openssl x509 -in vpcomm-root.crt -outform DER | openssl dgst -sha256
   ```

   The app inserts colons between fingerprint bytes; the bytes must match.

5. Use the exact hostname or IP covered by the server certificate.

The imported CA is trusted only inside this app and persists until removed.
With a private CA selected, system trust roots are not
used for the connection. Hostname, validity, and chain verification still apply.
Network fetching during private-CA evaluation is disabled; the server must
send its necessary intermediate certificates.

An iPhone's `127.0.0.1` is the iPhone, not your Mac. Use a reachable server
address with TLS. Only the test-only macOS probe permits plaintext loopback.
No relay address, access token, invitation, or CA private key is bundled.

## Behavior and Privacy

- Accepted group calls use CallKit-managed background audio. Incoming locked-screen
  ringing requires APNs configuration and Apple push provisioning.
- Audio interruptions, removal of an audio device, and audio-service resets end the call.
  Connect your preferred headphones before starting.
- A brief inactive state obscures the interface but does not alone hang up.
  Backgrounding closes idle signaling sockets, not accepted CallKit audio.
- No system contacts, automatic call rejoining, or accounts.
- The lobby exposes call availability, public device keys, names, and request/
  approval timing to the relay. All online lobby peers see announcements.
- No app-managed recording, analytics, or cloud storage. Relay details persist
  in the device-only Keychain, along with lobby identity and verified peer keys;
  invitations and session keys exist only in memory.
  Secure memory erasure is not
  guaranteed. OS diagnostics, clipboard recipients, or compromised devices
  remain outside these protections.
- End-to-end encryption uses the project's existing experimental protocol.
  It is not independently audited. The relay sees IPs, timing, duration, and
  traffic volume. Your partner can record or retransmit the conversation.

## Audio

The client converts device audio to mono 16 kHz PCM16 little-endian, 320 samples
per 20 ms frame. It uses AVAudioEngine voice processing on supported hardware
for echo cancellation. Headphones are still recommended.

The microphone tap uses its delivered PCM format, including changes negotiated
after voice processing starts. A changed sample rate/channel layout rebuilds the
resampler and discards partial/queued old-format capture without changing network
keys or counters. Empty startup buffers do not count as conversion failures.
Engine stops, PCM conversion errors (including numeric codes/format), allocation
failures, and the capture watchdog have distinct alerts. These contain no audio
samples, relay credentials, or keys.

The engine is created after session activation. A stopped engine is not immediately
treated as a hang-up: capture/playback checks rebuild the tap and playback graph
against the current I/O formats and attempt restart, at most three times per call,
spaced by 250 ms with a two-second window per stop. While recovering, playback is
dropped and capture waits; the encrypted connections and mute setting remain.
Old graph queues are discarded. Interruption, device removal, audio-service loss/
reset, and explicit shutdown prohibit restart. Legacy non-CallKit audio also
stops on backgrounding. Exhausting the
budget ends the call with a distinct error instead of an unlimited retry loop.
Native tests exercise the recovery policy with a simulated engine; physical
voice-processing route changes still require device acceptance testing.

Capture and scheduled playback queues are bounded to five frames. Full capture
queues discard old unsent audio; full playback queues discard incoming audio.
Muting clears queued microphone frames and sends encrypted silence. Previously
sent frames cannot be recalled.

Group playback mixes one frame per speaker every 20 ms with saturation to PCM16.
Each speaker has a five-frame queue; missing frames contribute silence.
Membership changes discard queued old-epoch audio and create fresh media keys
and counters. A brief gap during a join/leave is possible.

This is not an adaptive real-time transport: WebSocket/TCP packet loss can
cause delay. Five seconds without microphone frames or a blocked send ends the
local call. Manual calls also end after ten seconds without received audio.
Group signaling has a 45-second receive timeout, kept alive by 15-second heartbeats.
Group media uses 705-byte frames for each directed pair, about 127 MB/hour of
relay egress per directed link before transport overhead: approximately 3.81 GB/hour
for six participants (30 directed links), and about 1.41 Mbit/s upload per phone.
Opus compression and a reviewed real-time media transport remain future work.

## Tests

From the repository root:

```bash
# Simulator build
xcodebuild -project iphone/Canddle.xcodeproj -scheme Canddle \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vpcomm-iphone-build CODE_SIGNING_ALLOWED=NO build

# Native protocol checks, without recording or playing audio
xcrun swiftc -parse-as-library iphone/Core/*.swift \
  iphone/Tests/ProtocolChecks.swift -o /tmp/vpcomm-iphone-checks
/tmp/vpcomm-iphone-checks

# Live Swift/Python encrypted audio and TLS tests
xcrun swiftc -parse-as-library iphone/Core/*.swift \
  iphone/Tests/Probe.swift -o /tmp/vpcomm-iphone-probe
VPCOMM_IPHONE_PROBE=/tmp/vpcomm-iphone-probe \
  python -m pytest iphone/Tests/test_interop.py tests -q

# Native observable lobby state with in-memory test storage (no user Keychain)
xcrun swiftc -parse-as-library iphone/Core/*.swift iphone/App/LobbyStore.swift \
  iphone/Tests/LobbyStoreChecks.swift -o /tmp/vpcomm-lobby-state
VPCOMM_LOBBY_STORE_PROBE=/tmp/vpcomm-lobby-state \
  python -m pytest iphone/Tests/test_lobby_state.py -q

# Group lifecycle and encrypted all-to-all synthetic audio, 2-6 native clients
xcrun swiftc -parse-as-library iphone/Core/*.swift iphone/App/LobbyStore.swift \
  iphone/App/GroupStore.swift iphone/Tests/GroupChecks.swift -o /tmp/vpcomm-group-checks
VPCOMM_GROUP_PROBE=/tmp/vpcomm-group-checks \
  python -m pytest tests/test_group_server.py iphone/Tests/test_group.py -q

# Actual AVAudioConverter on macOS with synthetic buffers, no microphone access
xcrun swiftc -parse-as-library iphone/Core/Protocol.swift iphone/App/AudioIO.swift \
  iphone/Tests/AudioChecks.swift -o /tmp/vpcomm-audio-checks
VPCOMM_AUDIO_PROBE=/tmp/vpcomm-audio-checks \
  python -m pytest iphone/Tests/test_audio_native.py -q
```

Install the root project's `test` dependencies in your Python environment first.
Interop tests are skipped unless `VPCOMM_IPHONE_PROBE` is set. The probe reads
test credentials from stdin rather than command-line arguments.

Run the UI test with Command-U in Xcode using an installed iPhone simulator.
It checks the compact interface, insecure-address rejection, automatic connection
attempts after setup/relaunch/backgrounding, pausing retries in Settings, saved
relay restoration, and deletion. Test outputs and
builds should live outside the repository, using `-derivedDataPath /tmp/...`.
UI tests require signing for Keychain access. For command-line simulator tests,
use `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` (local ad-hoc signing), not
the unsigned build-only setting above.

Verification covers real Swift-to-Python key exchange and encrypted PCM in both
directions, matching verification codes, private-CA TLS, rejection of expired/
untrusted/wrong-host certificates and bad tokens, stalled-connection deadlines,
and hang-up cancellation. Separate native checks cover tampering, replay,
reflection, wrong secrets, ordering, frame limits, and URL policy.
Lobby checks cover signed registration/announcements/requests, transcript binding,
encrypted invitation transfer over TLS, matching verification codes, authorization,
single-winner approval, expiry, replayed registration, cancellation, trust reload,
and fail-closed behavior when trust storage fails. Injected-storage tests do not
verify actual device Keychain permissions or persistence.
Group tests cover pairwise encryption, epoch binding, tampering/replay, local
mixing, late joins, removal/rejoin, caller departure, capacity, ignore/reject,
membership-update races, and live all-to-all traffic over TLS.

## Physical-Device Acceptance

Build and simulator tests do not verify real microphone/speaker quality. Before
relying on this client, run iPhone-to-desktop and iPhone-to-iPhone calls and check:

- Both audio directions, echo, volume, latency, and a ten-minute call.
- Built-in audio, wired headphones, and Bluetooth HFP.
- Permission denial, later permission grant, mute, and hang-up.
- Backgrounding, screen lock, headphone removal, and incoming phone calls.
- Wi-Fi/cellular interruption, relay restart, and token rotation.
- Public certificate and private-CA deployments, including a nonstandard port.
- Scan a real terminal QR, confirm the expected host, relaunch and make a call.
- Camera denial/cancellation, expired/reused QR rejection, and pairing with
  untrusted/wrong-host certificates. Never accept a TLS-bypass workaround.
- Two iPhones: first-time code comparison, requester confirmation, caller
  approval, and automatic bidirectional audio; repeat with remembered peer keys.
- Three to six iPhones: verify everyone hears everyone else, including later
  joiners. Check foreground alert banners/sounds, mute, participant lists,
  reject/ignore/expiry, removal and one-tap verified rejoin.
- Keep a call running while participants join and leave; caller departure must
  end it for everyone. Test network loss during admission and audio streaming.
- Relaunch and confirm verified keys persist; a different device with the same
  name must still show as unverified. Test **Forget verified peers**.

Independent security review remains necessary before high-sensitivity use.
