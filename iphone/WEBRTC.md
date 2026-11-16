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
  Non-trickle ICE sends one complete description per directed pair/epoch.
- Each signed membership change closes all old peer connections and creates
  fresh connections/certificates. This revokes removed participants' links but
  creates a brief renegotiation gap for remaining participants.
- The microphone starts only after admission, permission and CallKit activation.
  WebRTC owns audio capture/playback; the legacy AVAudioEngine pipeline is not
  run alongside it. Mute disables the local WebRTC track.
- Leaving, call cancellation, signaling loss or audio interruption closes the
  peer connections. A failed setup ends the call after 25 seconds; a disconnected
  media link gets 10 seconds to recover. There is no automatic downgrade or ICE
  restart yet. Wi-Fi/cellular handoff may require redialing.

The relay can see signed SDP, including candidates, and TURN can see traffic
metadata but cannot decrypt audio. Direct peers learn network addresses.
No public third-party STUN/TURN server is hardcoded. The device identity and
signaling protocol remain experimental and have not been independently audited.

## Connection Timeouts

Admission and an advertised WebRTC capability do not prove TURN reachability:
the relay checks TURN configuration syntax, not the running service or firewall.
The call screen now reports its current media-setup stage. Timeout alerts include
a stage code and redacted local/remote SDP candidate counts, not SDP, IPs or secrets:

- `RTC_GATHERING`: no candidates were gathered. This non-trickle implementation
  sends its SDP once gathering completes, once a TURN relay candidate exists, or
  after a 4-second cutoff with whatever candidates exist, because a silent TURN
  endpoint or interface can otherwise leave gathering incomplete indefinitely. Check listener access, DNS and
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
  iphone/Core/*.swift iphone/Tests/WebRTCChecks.swift -o /tmp/canddle-webrtc-checks
/tmp/canddle-webrtc-checks
```

This probe uses receive-only transceivers: it does not record or play sound.
Successful negotiation does not establish physical audio quality.
Run `/tmp/canddle-webrtc-checks --stalled-turn` to reproduce incomplete gathering
against a silent loopback TURN endpoint. With the pinned SDK, gathering remains
incomplete after 26 seconds despite available host candidates, outlasting the
app's 25-second setup deadline. This is a local failure-path test, not evidence
about any particular deployed TURN server.

Before rollout, test on two signed iPhones:

- Wi-Fi-to-Wi-Fi, Wi-Fi-to-cellular, and cellular-to-cellular calls.
- Confirm TURN allocation when direct connectivity is unavailable. Test UDP
  blocked with TURN/TCP allowed, then all media ports blocked (clear call failure).
- Ring and answer while locked/backgrounded. Confirm no microphone before answer
  and admission; verify two-way audio, mute/unmute, speaker and Bluetooth routes.
- Add/remove group members, including six participants; removed devices must
  lose audio and remaining peers must reconnect.
- Cancel during negotiation, hang up from either side, lose signaling, change
  networks, and deny microphone permission. Confirm teardown and no lingering mic.
- Compare speech under packet loss/jitter with legacy mode and confirm acceptable
  latency and battery use. No WeChat-equivalent quality claim is made.

## Call Quality Diagnostics

Relays with TURN configured advertise a `quality` capability. Updated iPhones
then sample WebRTC `getStats()` every 10 seconds and send one `rtc-quality`
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
relay to stop logging. Reports are not stored apart from container logs.
