#!/usr/bin/env bash
# Host side of the in-game check: builds the files the OpenComputers computer
# installs (this checkout's src/ws.lua, libtls13, check.lua and the
# certificate pins), then serves them along with ws:// and wss:// echo
# servers on 127.0.0.1 until Ctrl+C. See tests/ingame/README.md.
#
# Usage: nix develop -c tests/ingame/run.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
cache="$PWD/tests/ingame/.cache"
files="$cache/files"
certs="$cache/certs"
libtls=$(tests/support/libtls13.sh "$cache")

mkdir -p "$certs"
if [ ! -f "$certs/rsa.pem" ]; then
	openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj /CN=127.0.0.1 \
		-keyout "$certs/rsa.key" -out "$certs/rsa.pem" 2>/dev/null
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -nodes -days 365 -subj /CN=127.0.0.1 \
		-keyout "$certs/p256.key" -out "$certs/p256.pem" 2>/dev/null
fi
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

rm -rf "$files"
mkdir -p "$files/tls13"
cp src/ws.lua tests/ingame/install.lua tests/ingame/check.lua "$files/"
cp -rL "$libtls/tls13/." "$files/tls13/"
cat >"$files/pins.lua" <<EOF
return {
  ws = "ws://127.0.0.1:8080/",
  rsa = { url = "wss://127.0.0.1:8443/", fingerprint = "$(fingerprint "$certs/rsa.pem")" },
  p256 = { url = "wss://127.0.0.1:8444/", fingerprint = "$(fingerprint "$certs/p256.pem")" },
}
EOF
{
	echo "ws.lua /lib/ws.lua"
	echo "check.lua /home/check.lua"
	echo "pins.lua /home/pins.lua"
	(cd "$files" && find tls13 -name '*.lua' | sort | sed 's|.*|& /lib/&|')
} >"$files/manifest.txt"

(cd tests/server && pnpm install --frozen-lockfile --silent)

cat <<'EOF'

In the OpenComputers computer, run:

  wget -f http://127.0.0.1:8000/install.lua /home/install.lua
  /home/install.lua
  /home/check.lua

Re-run install.lua after changing src/ws.lua; this script copies it fresh
each start. Ctrl+C stops the servers.

EOF
exec node tests/server/ingame.js "$files" "$certs"
