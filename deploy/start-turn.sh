#!/bin/sh
set -eu
umask 077

# Never place the shared secret in turnserver's argv or print it to logs.
: "${VPCOMM_TURN_SECRET:?}"
: "${VPCOMM_TURN_REALM:?}"
: "${VPCOMM_TURN_PUBLIC_IP:?}"
: "${VPCOMM_TURN_PRIVATE_IP:?}"
case "$VPCOMM_TURN_SECRET" in *[!A-Za-z0-9_-]*) echo "Use a hex or URL-safe TURN secret" >&2; exit 1;; esac
[ "${#VPCOMM_TURN_SECRET}" -ge 32 ] || exit 1
case "$VPCOMM_TURN_REALM" in *[!A-Za-z0-9.-]*) exit 1;; esac
case "$VPCOMM_TURN_PUBLIC_IP$VPCOMM_TURN_PRIVATE_IP" in *[!0-9.]*) exit 1;; esac

printf '%s\n' \
    'listening-port=3478' \
    'min-port=49160' \
    'max-port=49259' \
    "listening-ip=$VPCOMM_TURN_PRIVATE_IP" \
    "relay-ip=$VPCOMM_TURN_PRIVATE_IP" \
    "external-ip=$VPCOMM_TURN_PUBLIC_IP/$VPCOMM_TURN_PRIVATE_IP" \
    "realm=$VPCOMM_TURN_REALM" \
    'use-auth-secret' \
    "static-auth-secret=$VPCOMM_TURN_SECRET" \
    'fingerprint' \
    'no-cli' \
    'no-tls' \
    'no-dtls' \
    'no-tcp-relay' \
    'no-multicast-peers' \
    'stale-nonce=600' \
    'user-quota=12' \
    'total-quota=128' \
    'relay-threads=2' \
    'max-bps=250000' \
    'bps-capacity=4000000' \
    'denied-peer-ip=0.0.0.0-0.255.255.255' \
    'denied-peer-ip=10.0.0.0-10.255.255.255' \
    'denied-peer-ip=100.64.0.0-100.127.255.255' \
    'denied-peer-ip=127.0.0.0-127.255.255.255' \
    'denied-peer-ip=169.254.0.0-169.254.255.255' \
    'denied-peer-ip=172.16.0.0-172.31.255.255' \
    'denied-peer-ip=192.168.0.0-192.168.255.255' \
    'denied-peer-ip=::1' \
    'denied-peer-ip=::ffff:0:0-::ffff:ffff:ffff' \
    'denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' \
    'denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff' \
    'log-file=stdout' \
    'simple-log' \
    'userdb=/tmp/turnserver.sqlite' \
    'pidfile=/tmp/turnserver.pid' > /tmp/canddle-turn.conf

exec turnserver -c /tmp/canddle-turn.conf
