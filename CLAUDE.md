# oc-ws

Done gate: `nix develop -c luacheck .` and `nix develop -c busted tests/unit`.
The `tests/{autobahn,tls,ocemu}/run.sh` runs are slower tiers that CI runs;
run them locally only to fix a failure there.

- `src/ws.lua` stays one file: OpenComputers users install it with a single
  `wget` or `oppm` line.
- Every OpenComputers call goes through `ws.platform`, which the test tiers
  replace (`tests/support/`). Keep new OC access behind it.
- Lua 5.3 only (native bitwise operators, `string.pack`). OC's Lua 5.2
  architecture cannot even parse the file.
