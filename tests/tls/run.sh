#!/usr/bin/env bash
# Checks wss:// on desktop Lua: oc-ws + libtls13 against a Node TLS 1.3 echo
# server, once with an RSA certificate and once with a P-384 one (OC's data
# card is needed for P-256, so these are the key types the pure-Lua path
# verifies).
#
# Usage: tests/tls/run.sh   (from the repo root, inside `nix develop`)
set -euo pipefail

cd "$(dirname "$0")/../.."
cache="$PWD/tests/tls/.cache"
LIBTLS13_DIR=$(tests/support/libtls13.sh "$cache")
export LIBTLS13_DIR

(cd tests/server && pnpm install --frozen-lockfile --silent)

status=0
port=9443
for keytype in rsa:2048 ec:secp384r1; do
	dir="$cache/cert-${keytype/:/-}"
	mkdir -p "$dir"
	if [ "$keytype" = rsa:2048 ]; then
		openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
			-keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
	else
		# Signed with SHA-384 like real P-384 chains: libtls13 does not offer
		# ecdsa_secp256r1_sha256 for certificates without a data card.
		openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -nodes -days 1 -subj /CN=localhost \
			-keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
	fi

	node tests/server/echo.js "$port" "$dir/key.pem" "$dir/cert.pem" &
	server=$!
	for _ in $(seq 50); do
		if (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then break; fi
		sleep 0.1
	done

	echo "== $keytype certificate"
	FINGERPRINT=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2) \
		WSS_URL="wss://localhost:$port/" lua tests/tls/client.lua || status=1
	kill "$server"
	wait "$server" 2>/dev/null || true
	port=$((port + 1))
done
exit $status
