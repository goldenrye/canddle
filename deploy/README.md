# Deploy on One EC2 Instance

This guide does not provision or modify AWS resources automatically. Docker
builds and deployment must be validated on your chosen EC2 OS and architecture.

## 1. Prepare the Instance

Use a small Linux EC2 instance initially, such as an Ubuntu instance with at
least 1 GiB RAM. Pick a region near the participants. Benchmark before increasing
call volume; there is no measured production capacity claim.

Install Docker Engine and the Docker Compose plugin from their official
distribution instructions. Avoid public load balancers, API Gateway, managed
databases, NAT gateways, or third-party calling services; none is needed.

Security group:

- TCP 443: allow your participants' source networks where feasible.
- TCP 80: allow publicly if using ACME HTTP validation for a public certificate.
- TCP 22: allow only your own administration address.
- Do not expose TCP 8765. It is internal to Docker.
- No UDP ports are needed by this prototype.

Keep SSH keys protected and the OS patched. Docker-published ports can bypass
some host firewall configurations; rely on the EC2 security group as well.

Copy this repository to a directory on the instance. Use an existing domain,
for example `voice.example.com`, with an A record pointing at the public IPv4.
If an AAAA record exists, it must route to this instance as well.

## 2. Set the Relay Credential

Generate a cryptographically random token with:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Create `.env` in the project directory using a local editor and restrict its
permissions to the owner (`chmod 600 .env`). It must contain:

```dotenv
VPCOMM_DOMAIN=voice.example.com
VPCOMM_ACCESS_TOKEN=REPLACE_WITH_THE_RANDOM_TOKEN
```

Do not keep the example value. Give the random token only to intended users.
This shared token authorizes relay use, not audio decryption. It appears in the
container environment and is visible to instance/Docker administrators.
Do not paste output from `docker compose config` into logs or support chats:
it expands environment values.

## 3. Start the Services

Run from the project directory:

```bash
docker compose up -d --build
docker compose ps
curl --fail https://voice.example.com/healthz
```

The response should be `ok`. Caddy obtains and renews a free public TLS
certificate. DNS and inbound port 80 must be correct for initial issuance.
Certificate issuance contacts public certificate authorities, but does not
send them your audio or invitation. Public certificate names appear in
certificate-transparency records.

The relay has a Docker health check. Caddy starts after it becomes healthy.
No access-log directive is enabled. Container operational logs are size-bounded.
Do not enable WebSocket debug logs or HTTP header/body capture.

On each desktop:

```bash
vpcomm-desktop --server wss://voice.example.com/relay
```

Enter the relay token, then create or join a call using a fresh invitation.
Verify microphone permission and selected audio devices. Use headphones.

## Without a Domain

You can use the instance public IP and Caddy's private certificate authority,
at the cost of securely distributing a CA certificate to both desktops.
This is not a "skip TLS verification" mode.

Set `.env` as follows (the address below is a documentation example):

```dotenv
VPCOMM_DOMAIN=203.0.113.10
VPCOMM_ACCESS_TOKEN=REPLACE_WITH_THE_RANDOM_TOKEN
VPCOMM_CADDYFILE=./deploy/Caddyfile.private
```

Start services as above, then export **only the public root certificate**:

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./vpcomm-root.crt
```

Copy that certificate to each desktop over authenticated SSH or another trusted
channel. Verify the SSH host identity. Never copy the CA private key or the
entire Caddy data directory to clients.

```bash
vpcomm-desktop --server wss://203.0.113.10/relay --ca /path/to/vpcomm-root.crt
```

Health checking from a machine holding the root certificate:

```bash
curl --cacert ./vpcomm-root.crt https://203.0.113.10/healthz
```

For this private-CA mode, public ACME validation is not used; inbound TCP 80
is optional and can be removed from the security group and Compose ports.
The CA file is trusted only by this client process, not installed system-wide.
If the public IP changes, update `.env`, recreate Caddy, and update client URLs.
Preserve the Caddy data volume to keep the same CA. If you replace that volume,
securely distribute the new root certificate.

## Sharing a Host That Already Has a Certificate

If another web server already owns ports 80/443 and renews a certificate with
certbot, reuse that certificate and publish the relay on 8443:

```dotenv
VPCOMM_DOMAIN=voice.example.com
VPCOMM_ACCESS_TOKEN=REPLACE_WITH_THE_RANDOM_TOKEN
VPCOMM_CADDYFILE=./deploy/Caddyfile.host-cert
COMPOSE_FILE=compose.yaml:deploy/compose.alt-port.yaml:deploy/compose.host-cert.yaml
```

Clients connect with `--server wss://voice.example.com:8443/relay` and need no
`--ca`. Caddy does not reload certificate files on its own, so add a certbot
deploy hook (`/etc/letsencrypt/renewal-hooks/deploy/`) that runs
`docker compose restart caddy` from the project directory.

## One-Time iPhone QR Pairing

Pairing is optional and disabled unless `VPCOMM_PUBLIC_RELAY_URL` is set.
After deploying the updated code, add the exact client-facing address to `.env`:

```dotenv
VPCOMM_PUBLIC_RELAY_URL=wss://voice.example.com:8443/relay
```

Use your actual hostname/IP and public port (omit `:8443` if using normal 443).
The certificate must cover that host. Rebuild and restart the proxy to load
the new `/pair` route; this interrupts current calls:

```bash
docker compose up -d --build
docker compose restart caddy
```

Over authenticated SSH, run this in the project directory:

```bash
docker compose exec -T relay vpcomm-pair
```

Expand the terminal so the whole QR fits without line wrapping. In the updated
iPhone app, tap **Pair with QR**, allow camera access, scan, verify the displayed
server, and tap **Pair and save**. Generate a separate QR for each phone.
For private-CA servers, securely import and verify the public CA in the app
**before** scanning. The QR does not install a CA or bypass certificate checks.

The QR contains a random 256-bit, single-use capability, not the permanent token.
It expires two minutes after creation. Treat the screen/QR as sensitive: whoever
redeems it first gets relay access. Do not put it in tickets, chat archives, or
recorded terminal sessions. `--json` prints the same sensitive payload for
local tooling, not for public sharing.

Revoke all unused codes with:

```bash
docker compose exec -T relay vpcomm-pair --revoke
```

Restarting the relay also invalidates outstanding codes. Revoking QR codes does
not revoke tokens already obtained. Rotate `VPCOMM_ACCESS_TOKEN` and pair again
to remove previously granted access; per-device revocation and automatic
credential rotation are not implemented.

Pairing uses verified HTTPS on the same host/port, with the code only in an
Authorization header and responses marked `no-store`. Do not log request
headers or response bodies at any proxy. The admin command uses a mode-600
Unix socket in a mode-700, RAM-backed container directory; there is no public
admin endpoint, extra public port, database, or paid service. The public relay
port must still remain private behind the TLS proxy.

For non-Docker operation, create a mode-700 directory owned by the relay user,
set `VPCOMM_PAIRING_SOCKET` to a path inside it for both server and CLI, and set
`VPCOMM_PUBLIC_RELAY_URL` on the server. Route `/pair` to the relay through your
TLS proxy. Never expose the raw HTTP relay listener publicly.

There are at most 16 outstanding codes. Pairing requests share a global limit
of 20 burst / 2 per second; this bounds attempts but cannot prevent denial of
service. If pairing fails after redemption (lost response, cancellation, or
Keychain failure), generate a new QR. Codes are deliberately not reusable.

## Foreground Call Lobby

The updated iPhone client supports **Go online**, **New call**, **Request to join**,
and explicit caller approval, without copying invitations. Upgrade the server:

```bash
docker compose up -d --build
```

This can interrupt current calls. The lobby uses the existing authenticated
`/relay` WebSocket endpoint; no new proxy route, public port, database, environment
variable, or paid service is required. Old desktop/manual-invitation calls still
work. Both iPhones must install the updated app and remain in the foreground.
An old server will reject lobby registration; update it before using the feature.

All connected lobby clients receive announcements, but only the caller-approved
requester receives the end-to-end encrypted invitation. First-time peers must
compare the full security code independently before confirming/approving.
The relay access token does not establish a person's identity.

The server retains only transient signaling data in RAM. It sees device public
keys, names, announcements, request/approval metadata, and encrypted invitation
boxes, never the plaintext invitation. Do not enable WebSocket frame logging.
Restart clears all pending offers and requests. Run one relay replica.

Limits: the existing connection budget is shared by calls and lobby sockets;
one pending offer or outgoing request per device; at most 16 requests per offer;
two-minute offers; one-hour lobby sessions; 1024-byte messages; 64 queued outbound
messages per peer; three-second sends; and a 12-message burst / 2-per-second
incoming budget. Idle clients send application heartbeats every 15 seconds and
are disconnected after 45 seconds without messages. These limits do not stop
network floods or a token holder from disrupting the lobby.

The lobby does not use APNs/PushKit: locked or backgrounded iPhones do not ring.
See [`../iphone/README.md`](../iphone/README.md) for peer verification and usage.

## Routine Operations

- `docker compose logs --tail=50 relay caddy`: inspect operational failures.
  Review before sharing logs; do not add verbose protocol logging.
- `docker compose down`: disconnect calls and stop services. Rooms vanish.
- `docker compose up -d --build`: build changed source and recreate services
  as necessary. In-progress calls may be disconnected.
- Change the token in `.env`, then run
  `docker compose up -d --force-recreate relay` to revoke the old token.
  This disconnects calls; distribute the replacement credential securely.
- Maintain the OS, Docker, Caddy, and Python dependencies. The sample image
  tags are versioned but not pinned by digest.
- No audio backups are needed. Keep credentials and Caddy private keys secure.
  Instance snapshots, crash dumps, and memory inspection remain operator risks.

To change relay limits, add a `command` to the `relay` service, for example:

```yaml
command: ["vpcomm-server", "--host", "0.0.0.0", "--max-connections", "8",
          "--wait-timeout", "120", "--call-timeout", "1800"]
```

The service permits two participants per room. Once one leaves, both sockets
close. Relay state is in memory, so run **one replica**. Multiple replicas need
explicit room routing; adding replicas blindly can separate participants.

The relay bounds admitted connections, frame size/rate, queues, send time,
waiting time, and call duration. This is not DDoS protection. Invalid HTTP
handshakes and TLS setup still consume proxy resources. Restrict ingress where
possible and use a small trusted user population. Flooding can cause downtime
and bandwidth charges even when audio remains encrypted.

## Cost Boundaries

There are no per-minute communications charges or required paid APIs.
However, AWS may bill EC2 compute, EBS, public IPv4, and applicable data
transfer; a domain registrar may bill domain registration. Review current
regional pricing and your own account terms. An Elastic IP can also incur
charges. Do not assume a free tier covers this.

One two-person call causes roughly 240 MB/hour of relay audio egress before
transport overhead. PCM is deliberately simple but costly compared with Opus.
For long calls, compression should be prioritized in the next stage.

## Release Checklist

- Confirm `pytest`, Ruff checks, and image build on the deployment platform.
- Confirm `/healthz`, valid TLS, and rejection of the wrong relay token.
- Make a two-computer call across different networks and check both directions.
- Verify mute, hang-up, microphone permission denial, waiting timeout, and
  network interruption.
- Confirm security-group rules and that 8765 is not published.
- Review certificate trust and invitation delivery with both participants.
- Perform an independent security review before high-sensitivity use.
