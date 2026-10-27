#!/usr/bin/env bash
# Runs a ready-made test world for the in-game check: a Forge 1.12.2 server
# with OpenComputers in Docker, a flat creative world, and a computer at
# spawn (case, screen, keyboard, tier 3 parts, internet card, tier 3 data
# card, Lua BIOS) whose hard drive already holds OpenOS, this checkout's
# oc-ws, libtls13 and check.lua. Join localhost with the instance from
# instance.sh, turn the computer on, and check.lua runs.
#
# Each start copies the current src/ws.lua and check.lua onto the drive.
# Ctrl+C stops the echo servers; `tests/ingame/server.sh stop` stops
# Minecraft; `--reset` deletes the world first.
#
# Usage: nix develop -c tests/ingame/server.sh [--reset | stop]
set -euo pipefail

cd "$(dirname "$0")/../.."
cache="$PWD/tests/ingame/.cache"
data="$cache/server"
world="$data/world"
name=oc-ws-mc
image=itzg/minecraft-server:2026.10.0-java8
hdd=0c0c0c0c-0000-4000-8000-0000000000aa
oc_jar=OpenComputers-MC1.12.2-1.8.10+258943363.jar

# Stop first: OpenComputers writes its buffered copy of the drive back on save,
# which would overwrite the files copied below.
if docker container inspect "$name" >/dev/null 2>&1; then
	echo "stopping the running Minecraft server"
	docker stop -t 60 "$name" >/dev/null
	docker rm "$name" >/dev/null 2>&1 || true
fi
[ "${1:-}" = stop ] && exit 0
[ "${1:-}" = --reset ] && rm -rf "$world"

tests/ingame/instance.sh >/dev/null
tests/ingame/prepare.sh

mkdir -p "$data/mods" "$data/config/opencomputers"
rm -f "$data"/mods/OpenComputers-*.jar
cp "$cache/$oc_jar" "$data/mods/"
cp "$cache/settings.conf" "$data/config/opencomputers/settings.conf"

# The hard drive: OpenOS from the mod jar, then the files install.lua would
# fetch, and a .shrc that runs the check when the shell starts.
drive="$world/opencomputers/$hdd"
if [ ! -f "$drive/init.lua" ]; then
	tmp=$(mktemp -d)
	unzip -q "$cache/$oc_jar" 'assets/opencomputers/loot/openos/*' -d "$tmp"
	mkdir -p "$drive"
	cp -r "$tmp/assets/opencomputers/loot/openos/." "$drive/"
	rm -rf "$tmp"
fi
while read -r src dest; do
	mkdir -p "$(dirname "$drive$dest")"
	cp "$cache/files/$src" "$drive$dest"
done <"$cache/files/manifest.txt"
echo "/home/check.lua" >"$drive/home/.shrc"

# The setup function places and fills the computer. It runs from a function
# file because the BIOS byte array is longer than an RCON command may be.
bios=$(unzip -p "$cache/$oc_jar" assets/opencomputers/lua/bios.lua | od -An -v -td1 | tr -s ' \n' ' ' |
	sed 's/^ //; s/ $//; s/ /b,/g; s/$/b/')
case_at="0 4 2"
mkdir -p "$world/data/functions/ocws"
cat >"$world/data/functions/ocws/setup.mcfunction" <<EOF
gamerule spawnRadius 0
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
time set 6000
weather clear
setworldspawn 0 4 -2
fill -3 4 -1 3 7 4 air
setblock $case_at opencomputers:casecreative facing=north
setblock 0 5 2 opencomputers:screen3 pitch=north,yaw=north
setblock 1 5 2 opencomputers:keyboard pitch=north,yaw=north
replaceitem block $case_at slot.container.0 opencomputers:card 1 3
replaceitem block $case_at slot.container.1 opencomputers:card 1 8
replaceitem block $case_at slot.container.2 opencomputers:card 1 12
replaceitem block $case_at slot.container.3 opencomputers:component 1 11
replaceitem block $case_at slot.container.4 opencomputers:component 1 11
replaceitem block $case_at slot.container.5 opencomputers:storage 1 4 {"oc:data":{node:{address:"$hdd"}}}
replaceitem block $case_at slot.container.8 opencomputers:component 1 2
replaceitem block $case_at slot.container.9 opencomputers:storage 1 0 {"oc:data":{"oc:label":"EEPROM (Lua BIOS)","oc:eeprom":[B;$bios],"oc:readonly":0b}}
EOF

echo "starting Minecraft (the first start downloads Forge and takes a few minutes)"
docker run -d --name "$name" --network host -v "$data:/data" \
	-e EULA=TRUE -e TYPE=FORGE -e VERSION=1.12.2 -e FORGE_VERSION=14.23.5.2860 \
	-e LEVEL_TYPE=FLAT -e MODE=creative -e DIFFICULTY=peaceful \
	-e SPAWN_MONSTERS=false -e SPAWN_ANIMALS=false -e MOTD="oc-ws test" \
	-e MEMORY=3G -e UID="$(id -u)" -e GID="$(id -g)" \
	"$image" >/dev/null

for _ in $(seq 600); do
	if docker logs "$name" 2>&1 | grep -q 'Done ('; then break; fi
	if ! docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
		docker logs "$name" 2>&1 | tail -40
		echo "the Minecraft server exited"
		exit 1
	fi
	sleep 1
done
docker exec "$name" rcon-cli "function ocws:setup" | tail -1

(cd tests/server && pnpm install --frozen-lockfile --silent)
cat <<'EOF'

Ready. In Prism Launcher, launch the "oc-ws test" instance (import it once
from tests/ingame/.cache/oc-ws-test.zip), choose Multiplayer, and join
localhost. The computer is in front of you at spawn: open the case, press
the power button, and check.lua runs once OpenOS starts. Results are also
saved to /home/check.txt.

Ctrl+C stops the echo servers. Stop Minecraft with:
  nix develop -c tests/ingame/server.sh stop

EOF
exec node tests/server/ingame.js "$cache/files" "$cache/certs"
