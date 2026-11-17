# WebRTC Audio

Group and individual calls can now use native WebRTC with Opus, adaptive jitter
buffering, packet-loss concealment, echo processing, congestion control and
DTLS-SRTP encryption. WebSocket/TLS remains the authenticated signaling channel.
Audio normally uses UDP directly between admitted devices, or through TURN when
direct connectivity fails. TURN over TCP is a fallback, not a guarantee that TCP
will never be used.

## Rollout

1. Upgrade the relay and configure TURN as below.
2. Upgrade every participating iPhone. Open each app once to refresh its
   capability-aware push registration.
3. **Settings > Use WebRTC audio** is on by default for new outgoing calls.
   Offers show **WebRTC / Opus** or **Legacy / TCP**. An older/unconfigured relay
   offers an explicit **Start legacy group call** (or individual call) choice
   instead of blocking startup. Cancel sends no invitation; confirming uses
   encrypted TCP audio for this call without changing the WebRTC preference.
   A call already announced as WebRTC never silently changes its audio mode.
4. To call older apps, turn that setting off before starting the call.
   Incoming calls retain their signed media mode regardless of this preference.

An older app cannot see, join or receive a push for a WebRTC call. Upgraded apps
continue to receive legacy calls. The desktop/manual-invitation path is unchanged.
Do not remove existing APNs configuration: WebRTC does not wake a suspended app.
See [Background Calls](BACKGROUND_CALLS.md) for provisioning and push setup.

### Trickle ICE Updates

Upgrade the relay and participating iPhones to enable authenticated trickle ICE.
No new TURN credentials or ports are needed. The relay advertises `trickle=1`;
each updated device then includes `a=x-canddle-trickle:1` inside its signed SDP.
Candidate updates are sent only after both peers' signed descriptions opt in.
An older WebRTC app ignores the extra SDP attribute and continues using the
SDP-only path. An older relay receives no candidate-update messages.

The initial offer keeps bounded gathering for compatibility with unknown peers:
it publishes when gathering completes, a relay candidate is ready, or after four
seconds if candidates exist. A trickle-capable answerer can publish immediately.
Once negotiated, new candidates continue to be delivered, including UDP candidates
discovered after that initial cutoff. Updates arriving before the remote
description is applied are queued until the native SDK is ready.

On trickle-capable relays, native gathering now continues as interfaces change,
including after connection. The signed candidate stream stays open for later
routes. Native ICE can move the existing connection onto a preferred working
direct path without creating a second media session. Selection considers
writability, network cost, priority and RTT, not just RTT.

Discovery retains at most 64 distinct candidates per link/roster epoch,
including candidates already in initial SDP. At that limit, queued updates drain
and the signed end marker closes the stream. Existing audio continues, but
further candidates are ignored until a new epoch/call. Candidate removals are
not separately signaled; the bound also limits retained remote history.
Older relays use gather-once behavior. Peers without signed trickle support
still receive only the initial SDP.

This does not force UDP, guarantee a direct route or a switch from TURN/TCP,
or implement ICE restart. Keep fallback available. Update both iPhones and use
a relay advertising `trickle=1`; no new server protocol or credentials are needed.

### Lower-Delay Audio

- STUN binding discovery also uses the **same configured plain UDP TURN
  listeners**, helping find direct NAT paths. No third-party server is added.
  TLS/TCP-only listeners are not probed with plaintext UDP.
- All network types remain eligible. Surviving backup ICE paths are checked at
  a five-second interval. Ongoing discovery/checks cost some extra battery/data;
  native ICE still prunes inferior paths.
- NetEq fast acceleration helps queued audio catch up. The packet buffer is
  limited to 30 packets, while adaptive jitter buffering remains active. At
  20 ms per packet this holds 600 ms of encoded packets, **not** a 600 ms target
  or a microphone-to-speaker latency guarantee. Severe bursts may drop audio
  rather than build a longer queue.
- The device I/O buffer requests 10 ms. iOS and the active route, especially
  Bluetooth, may use another duration.
- Audio RTCP reports use a one-second interval. Each sender starts with a
  32 kbit/s ceiling; native congestion control and Opus loss protection remain
  active. Adaptive packet batching is disabled so the app does not increase
  packet duration to save bandwidth.
- At the ten-second stats cadence, two consecutive outbound-loss readings of
  at least 5%, or an RTT increase of at least 100 ms above the observed route
  baseline, lower that ceiling from 32 to 24 to 16 kbit/s. Three healthy readings
  raise it one step. Healthy means outbound loss at most 1% and RTT within 50 ms
  of baseline. Missing data is not recovery. Mute/no transmission and selected
  pair changes reset the evidence; incoming loss/jitter alone does not throttle
  the outgoing stream. Native congestion control can adapt below the ceiling
  between these app-level samples.

No duplicate audio is sent over parallel paths: that can add congestion and
requires deduplication/handoff support. When every path is lost, upgraded clients
can rebuild authenticated media connections as described below.

For deployment, keep UDP reachable and place TURN close to callers. Multiple
configured TURN URLs can offer alternative relay routes (all must accept the
configured REST secret); this is not automatic geographic routing. Symmetric
NAT/firewalls can still require TURN. Preserve TCP fallback.

Compare `rtt_ms` and `jb_ms` on **both** phones. High RTT with low buffer delay
suggests network distance/routing; low RTT with high buffer delay suggests
jitter/buffering. Neither includes the full audio-device pipeline. Compare
built-in audio against Bluetooth, enable iOS Local Network access for same-Wi-Fi
calls, and verify speech on real devices before concluding the delay is fixed.

### Wi-Fi/Cellular Handoff

Upgrade the relay and the iPhone apps, including the caller, to enable recovery
for already-admitted WebRTC calls. The relay advertises `recovery=1`, and clients
opt in after enabling WebRTC. No new TURN ports or APNs settings are needed.
Legacy calls and older relays retain their previous disconnect behavior.

- A call-scoped iOS path monitor detects interface/availability changes, ignores
  its initial reading and coalesces changes for 500 ms. Socket errors also trigger
  recovery. Five-second heartbeats and a 15-second receive timeout during eligible
  calls detect a silent signaling path (an already-pending read can take 45 seconds).
- The phone keeps its CallKit call and mute state, but suspends audio while
  reconnecting. It authenticates a new signaling socket using its existing device
  key, a fresh server challenge, and a random in-memory resume token.
- The relay retains admitted membership for up to 40 seconds after a recoverable
  loss. A resume can replace a still-live old socket. Old SDP/candidates are never
  replayed: the client verifies the last committed signed roster, then the caller
  signs a new revision/epoch. Every participant rebuilds ICE/DTLS links, preserving
  membership and refreshing credentials. This can briefly pause the whole group.
- An established media link disconnected for eight seconds, or reporting failure,
  also requests a fresh signed epoch. This is a full authenticated mesh rebuild,
  not an unsigned SDP renegotiation or a native `restartIce()` call.
- Signaling/epoch recovery has a 30-second client deadline. New media links then
  have the usual 25-second setup deadline. Repeated resume/refresh requests are
  bounded to eight per minute; refreshes are at least two seconds apart.
- Explicit hangup, removal, protocol/authentication failure, relay restart, and
  prolonged loss remain terminal. Hangup while completely offline stops local
  retries immediately; remote cleanup may wait for the relay grace period.
  There is no host migration, automatic readmission, or silent legacy downgrade.

Expect a brief audio gap, not guaranteed seamless speech. Local native integration
tests cover caller/recipient/simultaneous handoffs, abrupt socket loss, fresh
signaling budgets, and hangup. They do not simulate cellular radios or prove
locked-screen CallKit/microphone continuity; test those on signed physical iPhones.

## Self-Hosted TURN

The Python relay issues two-hour coturn REST credentials after authenticated
device registration. The shared TURN secret stays on the servers, never in the
app. Calls/signaling connections are still limited to one hour.

Generate a separate random secret:

```sh
openssl rand -hex 32
```

Set these deployment environment values (or add them to the deployment `.env`,
which must remain private and untracked):

```dotenv
VPCOMM_TURN_SECRET=<generated-secret>
VPCOMM_TURN_REALM=turn.example.com
VPCOMM_TURN_PUBLIC_IP=<public-ipv4>
VPCOMM_TURN_PRIVATE_IP=<ipv4-on-the-server-interface>
VPCOMM_TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp
```

The public/private IPs are equal on a host with a directly assigned public IPv4.
For a NATed cloud host, specify its interface IP separately and forward the full
port range below without rewriting port numbers. Point the TURN hostname's DNS
A record at the public IP. This supplied configuration listens on IPv4 only;
do not advertise an unreachable AAAA record.

Open inbound **3478/UDP**, **3478/TCP**, and **49160-49259/UDP** in the cloud
firewall and host firewall. Allow TURN's outbound UDP to internet peers.
These are additional media ports, separate from the existing HTTPS relay.

On the Linux deployment host:

```sh
docker compose -f compose.yaml -f deploy/compose.webrtc.yaml \
  -f deploy/compose.push.yaml up -d --build
```

Omit the push override only if APNs is not configured. Retain any other existing
deployment overrides. The TURN container uses **Linux host networking** so its
advertised relay ports match the actual sockets; this is not a Docker Desktop
networking recipe. No production deployment is performed by adding these files.

The supplied TURN service requires authentication, limits allocations/bandwidth,
disables the management CLI, and denies common private/loopback/link-local peer
ranges. Review deny rules for your network; quotas are not DDoS protection.
Credentials cannot be revoked individually before expiry. Rotate the TURN secret
to revoke them all, and rotate the relay bearer token if it was compromised.
Keep the secret out of logs, command history and shared `docker compose config`
output; the startup script puts it in a private tmpfs config, not process argv.

This recipe supports TURN over UDP/TCP on port 3478, **not TURN over TLS**.
Its `no-tls`/`no-dtls` settings refer to TURN listeners, not to WebRTC's
end-to-end DTLS-SRTP encryption inside relayed packets. For restrictive networks
that permit only TLS/443, configure a separate coturn TLS listener with a publicly
trusted certificate and use, for example, `turns:turn.example.com:5349?transport=tcp`
(or a dedicated IP with port 443). The HTTPS relay's private CA setting does not
configure TURN certificate trust. Do not disable TURN TLS certificate validation.

An independently managed coturn installation can also be used: give it the same
REST shared secret, set only `VPCOMM_TURN_URLS` and `VPCOMM_TURN_SECRET` on the
Python relay, and omit the supplied TURN container. With both variables absent,
WebRTC is disabled; partially configured values fail startup.

## Authentication and Lifecycle

- Offers bind `media=webrtc` and any individual target into a separate Ed25519
  signature domain. Stripping the mode/target invalidates the offer.
- Existing verification codes, explicit answers, caller admission, verified-device
  auto-accept policy, and the two/six-person limits still apply.
- Each full SDP is signed by its sending device and bound to call ID, roster
  revision, random epoch, sender, recipient and offer/answer role. The signature
  covers the DTLS certificate fingerprint and ICE credentials/candidates.
- Only admitted pairs may exchange SDP. The relay and recipients reject
  tampering, wrong recipients, duplicate descriptions and invalid epochs.
  PCM media frames are rejected for WebRTC calls.
- The lower sorted public identity offers, avoiding negotiation collisions.
  There is one signed description per directed pair/epoch. Negotiated trickle
  adds up to 64 signed candidate updates plus an end marker in each direction,
  bound to that exact description, pair and epoch. Replays, sequence gaps and
  updates after the end marker are rejected. Remaining late candidates are not
  discarded merely because the first description has already been sent.
- Each signed membership change closes all old peer connections and creates
  fresh connections/certificates. This revokes removed participants' links but
  creates a brief renegotiation gap for remaining participants.
- The microphone starts only after admission, permission and CallKit activation.
  WebRTC owns audio capture/playback; the legacy AVAudioEngine pipeline is not
  run alongside it. Mute disables the local WebRTC track.
- Leaving, call cancellation or audio interruption closes the peer connections.
  Eligible signaling loss suspends media and preserves the call for bounded
  authenticated recovery. Failed setup ends the call after 25 seconds; established
  disconnected media gets eight seconds before requesting a fresh signed epoch.
  There is no automatic downgrade.

The relay can see signed SDP, including candidates, and TURN can see traffic
metadata but cannot decrypt audio. Direct peers learn network addresses.
No public third-party STUN/TURN server is hardcoded. The device identity and
signaling protocol remain experimental and have not been independently audited.

## Connection Timeouts

Admission and an advertised WebRTC capability do not prove TURN reachability:
the relay checks TURN configuration syntax, not the running service or firewall.
The call screen now reports its current media-setup stage. Timeout alerts include
a stage code and redacted local/remote SDP candidate counts, not SDP, IPs or secrets:

- `RTC_GATHERING`: the initial description is still waiting for candidates.
  Before peer trickle support is known, the bounded compatibility gather above
  applies. Once trickle is negotiated, full gathering no longer gates sending
  an answer or delivering late candidates. Check listener access, DNS and
  TURN responses; a zero relay count does not by itself prove bad credentials.
- `RTC_WAIT_OFFER` / `RTC_WAIT_ANSWER`: the other device has not supplied its
  description. Check its error too; it may be stalled in gathering or audio setup.
- `RTC_CONNECTIVITY`: descriptions were exchanged but the media route/DTLS has
  not connected (or was lost). Check public/private IP mapping, TURN allocation
  and permission errors, and UDP relay ports 49160-49259 as well as listener 3478.
- `RTC_LOCAL_SDP`, `RTC_REMOTE_SDP`, `RTC_SIGNAL_SEND`: description generation,
  application, or delivery is incomplete, respectively.

Collect TURN logs immediately after one attempt, on the deployment host:

```sh
docker compose -f compose.yaml -f deploy/compose.webrtc.yaml logs --since=5m turn
```

Retain any additional deployment-specific overrides if needed. Do not share
`.env`, TURN credentials or unredacted SDP. Logs may contain endpoint addresses
and usernames; redact those before sharing. Compare the complete alert messages
on both phones and record whether they use the same Wi-Fi or different networks.
These diagnostics do not change timeouts or silently fall back to legacy audio.

## Dependency and Validation

The Xcode target pins the community-distributed `stasel/WebRTC` package to
**157.0.0**, source revision `c6cde72c7638acf8dc2b070aaecca054e9e20720`.
Its binary ZIP SHA-256 is:

```text
ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328
```

This is a community build of upstream WebRTC, not an official Google mobile
binary. Review dependency provenance, updates, licensing and App Store privacy
requirements before distribution. The supplied binary license is bundled and
available under Settings > About > WebRTC license.

`tests/test_webrtc.py` covers authorization, replay/tampering, mode compatibility,
TURN credentials, push capability migration and bounds. The existing native
group harness additionally covers individual/group WebRTC signaling, six-peer
membership, removal and old-relay behavior.

To test real ICE/DTLS with the matching macOS framework slice:

```sh
WEBRTC_FRAMEWORK=/path/to/WebRTC.xcframework
xcrun swiftc -parse-as-library \
  -F "$WEBRTC_FRAMEWORK/macos-x86_64_arm64" -framework WebRTC \
  -Xlinker -rpath -Xlinker "$WEBRTC_FRAMEWORK/macos-x86_64_arm64" \
  iphone/Core/*.swift iphone/App/WebRTCTrack.swift iphone/Tests/WebRTCChecks.swift \
  -o /tmp/canddle-webrtc-checks
/tmp/canddle-webrtc-checks
/tmp/canddle-webrtc-checks --answerer-sends
/tmp/canddle-webrtc-checks --route-upgrade
```

`--answerer-sends` checks that the answering phone's SDP is `sendrecv`. Each
phone attaches its microphone with `addTrack` (`App/WebRTCTrack.swift`). A
transceiver from `addTransceiver` is not reused for a remote offer, so the
answer used to be `recvonly` and that phone sent no audio. The check creates
SDP only and never opens a microphone.

`--route-upgrade` establishes ICE/DTLS through a test-only local UDP forwarder
that adds 80 ms in each direction, then delivers signed direct candidates.
It verifies that both peers leave the forwarding path, sampled connection state
remains connected, and selected RTT falls by at least half. It uses the production
ICE configuration, without microphone capture or ICE restart. This tests native
route switching, not real coturn allocation, cellular handoff, TCP-to-UDP recovery,
or end-to-end speech latency.

This probe uses receive-only transceivers: it does not record or play sound.
Successful negotiation does not establish physical audio quality.
Run `/tmp/canddle-webrtc-checks --trickle` and
`/tmp/canddle-webrtc-checks --trickle-stalled-turn` to test signed UDP candidates
delivered five seconds after candidate-free initial SDP. Both verify actual
UDP ICE/DTLS connectivity; the second verifies gathering is still incomplete
at candidate delivery because a local TURN endpoint is deliberately silent.
Run `/tmp/canddle-webrtc-checks --stalled-turn` to reproduce incomplete gathering
against a silent loopback TURN endpoint. With the pinned SDK, gathering remains
incomplete after 26 seconds despite available host candidates, outlasting the
app's 25-second setup deadline. This is a local failure-path test, not evidence
about any particular deployed TURN server.

Before rollout, test on two signed iPhones:

- Wi-Fi-to-Wi-Fi, Wi-Fi-to-cellular, and cellular-to-cellular calls.
- Confirm TURN allocation when direct connectivity is unavailable. Test UDP
  blocked with TURN/TCP allowed, then all media ports blocked (clear call failure).
- Delay UDP candidate availability beyond four seconds with TCP also available;
  check candidate delivery and selected-route logs. Include older WebRTC apps
  in a mixed-version group, and test against a relay without trickle support.
- Ring and answer while locked/backgrounded. Confirm no microphone before answer
  and admission; verify two-way audio, mute/unmute, speaker and Bluetooth routes.
- Add/remove group members, including six participants; removed devices must
  lose audio and remaining peers must reconnect.
- Switch Wi-Fi off/on during a call, on the caller and recipient separately and
  together, including while locked. Confirm the same CallKit call survives,
  two-way audio returns, and a muted microphone stays muted after recovery.
- Cancel during negotiation, hang up from either side (including while offline),
  block recovery beyond its deadline, and deny microphone permission. Confirm
  teardown, no automatic readmission, and no lingering microphone.
- Compare speech under packet loss/jitter with legacy mode and confirm acceptable
  latency and battery use. No WeChat-equivalent quality claim is made.
- Start relayed, then allow a direct path without redialing. Verify two-way speech
  continuity, real TURN/TCP-to-UDP recovery, repeated Wi-Fi/cellular changes,
  candidate-budget exhaustion, and cases where no direct route is reachable.
- Inject jitter/loss and check whether faster catch-up and reduced buffering
  cause unacceptable choppiness. Verify bitrate ceilings recover gradually.

## Call Quality Diagnostics

### In-Call Indicators

The call header shows transport arrows with **UDP**, **TCP**, or both for a
mixed group, plus a labeled quality icon. Each remote participant has its own
indicator; expand the participant to see round-trip delay, jitter, inbound and
outbound packet loss, concealed audio, and jitter-buffer delay.

- Transport comes from the selected audio candidate, not the signaling
  WebSocket. It describes the local leg from this iPhone; for TURN, this is
  the phone-to-TURN connection. TURN/TLS is displayed as TCP. The other
  phone's TURN transport can differ.
- Quality is a local estimate. The group header uses the worst measured link,
  not an average. Missing links prevent an all-Good result; a known Fair/Poor
  result is marked **partial** when other links cannot yet be evaluated.
- Samples update about every 10 seconds, with an initial warm-up of roughly
  20 seconds. **Measuring** means insufficient data; **Connecting** means the
  media link is not connected. **Stale** means no fresh interval report for
  more than 25 seconds. `?` means unknown transport, including stale readings.
- Roster changes, disconnects, and hangup clear previous readings. Indicators
  work locally even when the relay does not support quality logging.
- Legacy calls show **TCP** with quality **Unavailable**. Muting, silence,
  low bitrate, and TCP transport alone do not lower the WebRTC quality estimate.

Any available metric at or above a threshold sets the corresponding grade:

| Metric | Fair | Poor |
| --- | ---: | ---: |
| Round-trip delay | 300 ms | 600 ms |
| Jitter | 30 ms | 60 ms |
| Inbound or outbound packet loss | 2% | 5% |
| Concealed audio | 5% | 10% |
| Jitter-buffer delay | 150 ms | 300 ms |

**Good** additionally requires valid round-trip, jitter, inbound-loss, and
concealment measurements. These are heuristic thresholds, not a speech-quality
score or proof that the other person can hear you. Physical-device validation
should include a mixed-route group, a degraded peer, reconnects, and large text.

### Operator Logs

Relays with TURN configured advertise a `quality` capability. Updated iPhones
sample WebRTC `getStats()` every 10 seconds and, when supported, send one `rtc-quality`
message per interval over the authenticated group socket. Older relays never
receive it, and the relay drops malformed or stale reports without ending the
call. Each connected link is logged on the relay:

```text
INFO quality call=1a2b3c4d from=5e6f7a8b to=9c0d1e2f route=relay/tcp>srflx/udp muted=0 secs=10.0 rtt_ms=248.0 jitter_ms=14.2 loss_in=0.4 loss_out=1.0 conceal=2.1 jb_ms=96.3 rx_pps=50.0 tx_pps=50.0 rx_kbps=36.4 tx_kbps=36.8 mic_db=-38.5 spk_db=-41.2
```

```sh
docker compose logs -f relay | grep ' quality '
```

- `route`: the selected candidate pair as local>remote. For a local `relay`
  candidate, the transport is the phone-to-TURN leg; `relay/tcp` means TURN over
  TCP, which turns packet loss into delay.
- `loss_in`: the share of incoming RTP packets lost in this interval. `loss_out`
  is the peer's RTCP report of loss on this phone's stream.
- `conceal`: the share of playout samples synthesized by packet-loss concealment.
  Above roughly 5%, audio sounds noticeably choppy.
- `jb_ms`: average jitter-buffer delay. `rtt_ms` comes from ICE consent checks.
- `tx_pps` near 0 with `muted=0`, or `mic_db` near -127, means this phone is
  not sending speech.

`from`/`to` are the first 8 hex digits of SHA-256 over the device key. Both
directions of a pair appear as separate lines. Set `VPCOMM_QUALITY_LOG=0` on the
relay to stop logging. The app keeps only the latest in-memory readings for
the call; reports are not persisted on the phone.

## Direct Paths

ICE checks direct and relayed paths and normally prefers working direct paths,
but a relay may connect first or remain preferred by native selection rules.
A route with `relay` at either end goes through TURN; known `host`, `srflx` or
`prflx` candidates at both ends indicate a direct path. Unknown candidates do
not prove either. The call details screen shows this as **Path**.

- **Same Wi-Fi:** phones connect over their local addresses (`host>host`), but
  only with iOS **Local Network** access. Without it, iOS silently drops those
  packets. The app asks at launch (a Bonjour browse for `_canddle._udp`,
  listening only) and shows a hint during calls while access is off. Wi-Fi
  "client isolation" on guest or mesh networks also blocks this path.
- **Different networks:** hole punching through each router (`srflx>srflx`)
  usually works with home routers. It fails when a router gives each
  destination a different public port, or behind some carrier-grade NAT.
- **IPv6:** WebRTC gathers IPv6 addresses by default, and nothing in the app
  or relay filters them. When both phones have global IPv6, they can usually
  connect directly with no address translation; a stateful firewall may still
  block it. The TURN server does not need IPv6 for this.

Relays that advertise `quality_path` also receive path counts (never
addresses) in each quality report. Older relays never receive them.

| Field | Meaning |
|---|---|
| `l_host`, `l_srflx`, `l_relay` | This phone's candidates: local, public (from TURN/STUN), TURN relay |
| `r_host`, `r_srflx`, `r_prflx`, `r_relay` | The other phone's candidates; `prflx` was learned from its checks |
| `l_v6`, `r_v6` | How many of those are IPv6 |
| `d_ok`, `d_fail` | Direct (non-TURN) candidate pairs whose checks succeeded / failed |
| `v6` | 1 when the selected route is IPv6 |
| `lan` | iOS Local Network access: 1 on, 0 off; omitted when unknown |

Reading them for a relayed call:

- `lan=0`: Local Network access is off on that phone. Turn it on in Settings.
- `r_host` or `l_host` is 0: no local addresses were exchanged at all.
- `l_srflx=0`: no server-reflexive candidate is present in the report. Check
  UDP/STUN access; this alone does not prove direct connectivity is impossible,
  since local, IPv6 or peer-reflexive paths may still work.
- `d_fail` > 0 and `d_ok=0`: direct paths were tried and blocked, by a router,
  firewall or Wi-Fi isolation.
- `l_v6=0` or `r_v6=0`: at least one phone has no IPv6, so there is no IPv6 path.

Counts come from the current stats report, so long-finished pairs may have
been pruned.
