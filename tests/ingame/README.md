# In-game check

Runs `check.lua` on a real OpenComputers computer against echo servers on
this machine. It covers what the automated tiers can't: the `internet_ready`
signal, OC's memory limits with libtls13 loaded, and P-256 through a real
tier 3 data card.

## Client (once)

```sh
nix develop -c tests/ingame/instance.sh    # prints the zip's path
nix run nixpkgs#prismlauncher
```

In Prism Launcher: **Add Instance > Import**, pick the zip, and sign in with
your Microsoft account. The instance is Minecraft 1.12.2 with Forge and
OpenComputers 1.8.10.

## Ready-made world (recommended)

```sh
nix develop -c tests/ingame/server.sh          # --reset for a fresh world
```

This starts a Forge server in Docker (`oc-ws-mc`, flat creative world) and
the echo servers. The first start downloads Forge and takes a few minutes.
Launch the instance, join `localhost`, and the computer is in front of you:
open the case, press the power button, and `check.lua` runs once OpenOS
starts.

The computer is a Computer Case (Creative) with a tier 3 screen, a keyboard,
a tier 3 CPU, two tier 3.5 memory sticks, a tier 3 graphics card, an internet
card, a tier 3 data card and the Lua BIOS. Its hard drive already holds
OpenOS, this checkout's `src/ws.lua`, libtls13 and `check.lua`, and its
`.shrc` starts the check. Each `server.sh` start copies the current files
onto the drive.

Ctrl+C stops the echo servers. `nix develop -c tests/ingame/server.sh stop`
stops Minecraft.

## Your own world

Create a creative single-player world in the instance (its config lets
computers reach `127.0.0.1` and run without power) and build the computer
above, with the floppy "OpenOS (Operating System)" in place of the prepared
drive. Run `install` to copy OpenOS onto the hard disk and reboot. Then:

```sh
nix develop -c tests/ingame/run.sh             # on this machine
```

```sh
wget -f http://127.0.0.1:8000/install.lua /home/install.lua   # in the computer
/home/install.lua
/home/check.lua
```

## Reading the results

`check.lua` prints each result and saves them to `/home/check.txt`. Things
worth trying:

* **Less memory:** swap the RAM for Tier 1 or 2 sticks and rerun. The output
  shows how much oc-ws and libtls13 take and what is left.
* **Tier 2 data card:** the P-256 check is skipped, and RSA must still pass.
* **No data card:** both wss:// checks are skipped.

The `internet_ready` line reports whether the card's signal was seen. 0 means
oc-ws fell back to polling every 0.1 s.
