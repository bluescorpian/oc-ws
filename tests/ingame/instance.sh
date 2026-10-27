#!/usr/bin/env bash
# Builds a Prism Launcher instance (Minecraft 1.12.2, Forge, OpenComputers
# 1.8.10) for the in-game check, as a zip to import with Add Instance >
# Import. Its OpenComputers config allows 127.0.0.1, which the default
# config blocks, so the computer can reach tests/ingame/run.sh.
#
# Usage: tests/ingame/instance.sh   -> prints the zip's path
set -euo pipefail

cd "$(dirname "$0")"
cache="$PWD/.cache"
oc_jar=OpenComputers-MC1.12.2-1.8.10+258943363.jar
oc_url="https://github.com/MightyPirates/OpenComputers/releases/download/1.12.2-forge%2F1.8.10/OpenComputers-MC1.12.2-1.8.10%2B258943363.jar"
oc_sha256=9ba075d1bbdebe0c253bd6594deedcb81cdec3158ec7afc6c76ff8f5986c6816

mkdir -p "$cache"
if [ ! -f "$cache/$oc_jar" ]; then
	curl -sfL -o "$cache/$oc_jar.part" "$oc_url"
	mv "$cache/$oc_jar.part" "$cache/$oc_jar"
fi
echo "$oc_sha256  $cache/$oc_jar" | sha256sum -c --quiet

inst="$cache/instance"
rm -rf "$inst"
mkdir -p "$inst/.minecraft/mods" "$inst/.minecraft/config/opencomputers"
cp "$cache/$oc_jar" "$inst/.minecraft/mods/"

cat >"$inst/instance.cfg" <<'EOF'
InstanceType=OneSix
name=oc-ws test
EOF

cat >"$inst/mmc-pack.json" <<'EOF'
{
  "components": [
    { "uid": "net.minecraft", "version": "1.12.2", "important": true },
    { "uid": "net.minecraftforge", "version": "14.23.5.2860" }
  ],
  "formatVersion": 1
}
EOF

# Merged over OpenComputers' defaults: computers need no power, and the
# internet filter lets them reach 127.0.0.1. The version must match the mod's,
# or OC treats the file as pre-1.8.3 and migrates the filter rules away.
cat >"$inst/.minecraft/config/opencomputers/settings.conf" <<'EOF'
opencomputers {
  version: "1.8.10"
  power {
    ignorePower: true
  }
  internet {
    filteringRules: [
      "allow ip:127.0.0.1",
      "deny private",
      "deny bogon",
      "allow default"
    ]
  }
}
EOF

rm -f "$cache/oc-ws-test.zip"
(cd "$inst" && zip -qr "$cache/oc-ws-test.zip" instance.cfg mmc-pack.json .minecraft)
echo "$cache/oc-ws-test.zip"
