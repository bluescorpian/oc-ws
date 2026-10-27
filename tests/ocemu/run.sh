#!/usr/bin/env bash
# Smoke test inside OCEmu, a standalone OpenComputers emulator: boots OpenOS
# with oc-ws in /lib and runs tests/ocemu/smoke.lua against a local echo
# server. Covers the real OpenOS event loop, component proxies and
# require paths, which the desktop runs stand in for.
#
# OCEmu never sends internet_ready, so only oc-ws's polling path runs here.
#
# Usage: nix develop .#ocemu -c tests/ocemu/run.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
repo=$PWD
cache="$repo/tests/ocemu/.cache"
ocemu_rev=c84a071d2495fcfd196817f06e55a0df1e6c3860
oc_rev=258943363ea8fc4ef14948e6bc6f67375061580c
assets=src/main/resources/assets/opencomputers
mkdir -p "$cache"

if [ ! -f "$cache/ocemu-$ocemu_rev.done" ]; then
	rm -rf "$cache/ocemu"
	git clone -q https://github.com/zenith391/OCEmu.git "$cache/ocemu"
	git -C "$cache/ocemu" checkout -q "$ocemu_rev"
	git -C "$cache/ocemu" submodule -q update --init
	(cd "$cache/ocemu/luaffifb" && luarocks --lua-version 5.3 make --tree "$cache/rocks" luaffi-scm-1.rockspec >/dev/null)
	# OCEmu shows fatal errors only in an SDL message box, which the dummy
	# video driver discards; print them as well.
	sed -i 's/^  if err and #err > 0 then SDL.showSimpleMessageBox/  if err and #err > 0 then io.stderr:write(err, "\\n") end\n  if err and #err > 0 then SDL.showSimpleMessageBox/' "$cache/ocemu/src/boot.lua"
	touch "$cache/ocemu-$ocemu_rev.done"
fi

if [ ! -f "$cache/oc-$oc_rev.done" ]; then
	rm -rf "$cache/oc"
	git clone -q --filter=blob:none --no-checkout https://github.com/MightyPirates/OpenComputers.git "$cache/oc"
	git -C "$cache/oc" sparse-checkout set --no-cone "/$assets/lua/" "/$assets/loot/openos/" "/$assets/font.hex"
	git -C "$cache/oc" checkout -q "$oc_rev"
	touch "$cache/oc-$oc_rev.done"
fi
ln -sfn "$cache/oc/$assets/lua" "$cache/ocemu/src/lua"
ln -sfn "$cache/oc/$assets/font.hex" "$cache/ocemu/src/font.hex"
mkdir -p "$cache/ocemu/src/loot"
ln -sfn "$cache/oc/$assets/loot/openos" "$cache/ocemu/src/loot/openos"

(cd tests/server && pnpm install --frozen-lockfile --silent)

# A writable hard drive holding OpenOS, oc-ws, and a .shrc that starts the
# smoke test once the shell comes up.
base="$cache/base"
hdd=0c0c0c0c-0000-4000-8000-000000000001
port=9555
rm -rf "$base"
mkdir -p "$base/$hdd"
cp -r "$cache/oc/$assets/loot/openos/." "$base/$hdd/"
cp src/ws.lua "$base/$hdd/lib/ws.lua"
mkdir -p "$base/$hdd/home"
cp tests/ocemu/smoke.lua "$base/$hdd/home/smoke.lua"
echo "ws://127.0.0.1:$port/" >"$base/$hdd/home/url"
echo "/home/smoke.lua" >"$base/$hdd/home/.shrc"
cat >"$base/ocemu.cfg" <<EOF
ocemu {
  emulator {
    components {
      {"gpu", nil, 0, 160, 50, 3},
      {"eeprom", nil, 9, "lua/bios.lua"},
      {"filesystem", "$hdd", 5, nil, "OpenOS", false, 4},
      {"filesystem", nil, -1, "tmpfs", "tmpfs", false, 5},
      {"internet", nil, 2},
      {"computer", nil, -1},
      {"ocemu", nil, -1},
      {"screen_sdl2", nil, -1, 80, 25, 3},
      {"keyboard_sdl2", nil, -1}
    }
    debug=${OCEMU_DEBUG:-false}
  }
  version=3
}
EOF

node tests/server/echo.js "$port" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 50); do
	if (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then break; fi
	sleep 0.1
done

export LUA_CPATH="$cache/rocks/lib/lua/5.3/?.so;;"
log="$cache/ocemu.log"
(cd "$cache/ocemu/src" && timeout 120 stdbuf -oL -eL lua boot.lua --basedir="$base" >"$log" 2>&1) || echo "OCEmu exited with status $? after ${SECONDS}s"
grep -E '^(ok  |FAIL|SMOKE)' "$log" || { echo "no smoke output; OCEmu log:"; cat "$log"; exit 1; }
grep -q '^SMOKE PASSED' "$log"
