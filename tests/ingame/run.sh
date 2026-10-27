#!/usr/bin/env bash
# Host side of the in-game check: builds the files the OpenComputers computer
# installs (prepare.sh), then serves them along with ws:// and wss:// echo
# servers on 127.0.0.1 until Ctrl+C. See tests/ingame/README.md.
#
# Usage: nix develop -c tests/ingame/run.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
cache="$PWD/tests/ingame/.cache"
tests/ingame/prepare.sh
(cd tests/server && pnpm install --frozen-lockfile --silent)

cat <<'EOF'

In the OpenComputers computer, run:

  wget -f http://127.0.0.1:8000/install.lua /home/install.lua
  /home/install.lua
  /home/check.lua

Re-run install.lua after changing src/ws.lua; this script copies it fresh
each start. Ctrl+C stops the servers.

EOF
exec node tests/server/ingame.js "$cache/files" "$cache/certs"
