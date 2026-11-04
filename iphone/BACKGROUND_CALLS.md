# Background and Lock-Screen Calls

The iPhone app now integrates PushKit and CallKit. The relay optionally sends
VoIP pushes for new group calls. An idle app closes its WebSocket in the
background; Apple push wakes it and presents the native incoming-call screen.
Accepted CallKit audio sessions can continue with the screen locked.

## Enable on iPhone

1. Use a paid Apple Developer team and an explicit App ID with Push Notifications
   enabled. Regenerate the provisioning profile after enabling the capability.
2. Set the Xcode bundle identifier to that App ID. The project includes the
   `aps-environment` entitlement and the `voip` and `audio` background modes.
3. Match `APS_ENVIRONMENT` to the actual provisioning profile: `development` for
   development installs, `production` for TestFlight/App Store. The build setting
   also selects the server-side APNs endpoint through the registration message.
   Release defaults to production; override for development-signed Release builds.
4. Install and open the app, configure the upgraded relay, and wait for Settings
   to show **Background ringing registered with this relay.**
5. In Settings, tap **Allow microphone access** and allow the iOS prompt. The page
   then shows **Microphone access allowed**. If access was previously denied, use
   **Open iPhone Settings** and enable Microphone; the status refreshes on return.
   This permission does not itself enable push notifications or start recording.
   Make a foreground call and complete the existing first-time device verification.

Simulator builds do not establish that remote VoIP delivery or physical audio
works. Personal-team provisioning does not provide the required push capability.
Before the first unlock after reboot, protected credentials are unavailable.
Force-quitting, notification/Focus policy, network reachability, APNs delivery,
and OS resource limits can prevent ringing; delivery is not guaranteed.

## Enable on the Relay

Create an APNs token-signing key in the Apple Developer portal. Keep its `.p8`
file outside this repository. The key never belongs in the iPhone app.

Set these variables in the deployment environment:

| Variable | Value |
| --- | --- |
| `VPCOMM_APNS_KEY_FILE` | Absolute path to the private `.p8` key |
| `VPCOMM_APNS_KEY_ID` | Apple 10-character key ID |
| `VPCOMM_APNS_TEAM_ID` | Apple 10-character team ID |
| `VPCOMM_APNS_BUNDLE_ID` | Exact signed app bundle ID, without `.voip` |
| `VPCOMM_PUSH_DATA_DIR` | Absolute path to a private persistent data directory |

Make the data directory writable by the container user, UID/GID `10001:10001`,
with mode `0700`. Make the key readable by that user without making it
world-readable. Then build and start:

```sh
docker compose -f compose.yaml -f deploy/compose.push.yaml up -d --build
```

The optional override adds outbound networking for APNs on TCP 443 and a
persistent SQLite database. Keep existing relay TLS/reverse-proxy settings.
There is no new public HTTP endpoint. Non-Docker deployments set
`VPCOMM_PUSH_DB` to a private SQLite path instead of `VPCOMM_PUSH_DATA_DIR`.
All five APNs/database settings must be present; otherwise push is either
disabled (all absent) or startup fails (partially configured).

Upgrade the relay before deploying the app: token-bearing clients negotiate
the new `push-capabilities` extension, which older relays do not understand.
Old clients continue to work with the upgraded relay.

## Call Behavior

- A signed announcement rings registered devices, excluding the caller.
  Delivery is limited to one new ringing attempt per caller per 30 seconds.
- A VoIP push is promptly reported to CallKit, before network work. The app then
  validates its signed offer, relay scope, recipient, expiry and duplicate status.
  Invalid/stale calls are ended. No cancellation or generic notification pushes
  are sent as VoIP pushes.
- Answer requests admission for a previously verified caller. The caller
  accepts manually by default. The optional **Auto-accept verified family devices**
  setting permits automatic admission only for devices already verified by the
  caller on this relay. It does not automatically answer incoming calls.
  No microphone starts on receipt of a push.
- Unknown callers or missing microphone permission require opening the app;
  answering on the lock screen does not bypass either requirement.
- Ringing times out after 30 seconds. Admission after answering is bounded to
  25 seconds. Cancellation is delivered over the reconnected signaling socket;
  if unavailable, the local timeout clears the incoming-call screen.
- Accepted calls continue in the background. A caller still waiting for the
  first admission must keep the app foregrounded. Interrupted/failed calls end;
  membership is never automatically restored.
- System mute/end controls are connected to the call. Hold and call merging
  are not supported. Calls are not added to system Recents.

## Storage and Privacy

Relay credentials, imported public CA certificates, device identity and verified
peer keys use device-only Keychain storage accessible **after the first unlock**.
Existing items migrate on load. This is a deliberate change from unlocked-only
storage to allow answering while locked. Nothing syncs to iCloud. Imported public
CA trust now survives process exit; it is still hostname-checked and never
bypasses TLS verification.

The relay stores at most 128 device registrations. Each expires after seven days
without renewal on connection. Relay access-token rotation clears old registrations
on restart. APNs invalid-token responses remove the corresponding endpoint.
Changing or forgetting relay credentials attempts signed revocation at the old
relay; failures show a warning. To revoke sooner when a device cannot connect,
stop the relay and remove its registration from the private SQLite database, or
rotate the group access token and restart.

APNs receives the signed public call announcement, recipient public key, relay URL,
and short expiry, but no relay bearer token, private keys, or audio. This introduces
Apple as a notification dependency and metadata processor. The SQLite database
contains sensitive device push tokens; protect backups and do not publish it.

## Verification

Automated server tests cover authenticated registration, invalid input, storage
bounds/expiry/rotation, offline delivery, revocation, stale/cancelled suppression,
rate limiting, invalid APNs tokens, APNs headers/payload, and ES256 JWT signatures.
Native group tests exercise the unchanged admission and encrypted-media flow.

Before shipping, test two physical provisioned iPhones:

1. Open/configure both; verify registration and peer keys; grant microphone access.
2. Lock the receiver; start a call; confirm the native incoming-call screen.
3. Answer and approve on the caller; verify two-way audio and lock both screens.
4. Repeat after backgrounding, process termination by the OS, and device reboot
   followed by one unlock. Do not use force-quit as a guaranteed-delivery case.
5. Test decline, timeout, caller cancellation, caller disconnection, network loss,
   Focus, denied microphone access, unknown caller, system mute/end, and interruption.
6. Test both sandbox development and production TestFlight APNs environments.
7. Rotate/revoke tokens, change relay settings, forget the relay, restart the server,
   and verify old registrations no longer cause usable incoming calls.

Real APNs delivery and hardware audio must be verified separately; a successful
build or mock APNs response is not evidence of lock-screen ringing.
