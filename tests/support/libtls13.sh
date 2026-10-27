#!/usr/bin/env bash
# Fetches libtls13 at a pinned commit (once) and prints a directory that
# holds it as tls13/, ready for package.path or for copying into OpenOS.
# Usage: dir=$(tests/support/libtls13.sh <cache dir>)
set -euo pipefail

cache=$1
rev=a6f05614200b274b6d4f6d3cac83662c42bc227a

if [ ! -d "$cache/libtls/$rev" ]; then
	rm -rf "$cache/libtls"
	git clone -q --filter=blob:none --no-checkout https://github.com/OpenPrograms/Fingercomp-Programs.git "$cache/libtls/repo"
	git -C "$cache/libtls/repo" sparse-checkout set libtls13/src
	git -C "$cache/libtls/repo" checkout -q "$rev"
	mkdir -p "$cache/libtls/$rev"
	ln -s "$cache/libtls/repo/libtls13/src" "$cache/libtls/$rev/tls13"
fi
echo "$cache/libtls/$rev"
