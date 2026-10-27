# In-game check

Runs `check.lua` on a real OpenComputers computer in single-player, against
echo servers on this machine. It covers what the automated tiers can't: the
`internet_ready` signal, OC's memory limits with libtls13 loaded, and P-256
through a real tier 3 data card.

## Once: the Minecraft instance

```sh
nix develop -c tests/ingame/instance.sh    # prints the zip's path
nix run nixpkgs#prismlauncher
```

In Prism Launcher: **Add Instance > Import**, pick the zip, sign in with your
Microsoft account, and launch "oc-ws test". It is Minecraft 1.12.2 with Forge
and OpenComputers 1.8.10. Its OpenComputers config lets computers reach
`127.0.0.1` and run without power.

Create a **Creative** world. From the OpenComputers creative tab, place a
**Computer Case (Creative)** with a **Screen (Tier 3)** next to it and a
**Keyboard** on the screen. Put in the case:

* CPU (Tier 3), two Memory (Tier 3.5), Hard Disk Drive (Tier 3)
* Graphics Card (Tier 3), Internet Card, Data Card (Tier 3)
* EEPROM (Lua BIOS), and the floppy "OpenOS (Operating System)"

Turn it on, run `install` to copy OpenOS onto the hard disk, and reboot.

## Each run

On this machine, from the worktree with the code to test:

```sh
nix develop -c tests/ingame/run.sh
```

In the computer:

```sh
wget -f http://127.0.0.1:8000/install.lua /home/install.lua
/home/install.lua
/home/check.lua
```

`check.lua` prints each result and saves them to `/home/check.txt`. Things
worth trying:

* **Less memory:** swap the RAM for Tier 1 or 2 sticks and rerun. The output
  shows how much oc-ws and libtls13 take and what is left.
* **Tier 2 data card:** the P-256 check is skipped, and RSA must still pass.
* **No data card:** both wss:// checks are skipped.

The `internet_ready` line reports whether the card's signal was seen. 0 means
oc-ws fell back to polling every 0.1 s.
