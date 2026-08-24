# Batocera Setup for [bc250-core-unlock](https://github.com/rw-r-r-0644/bc250-core-unlock)

Unlocks the two dormant Zen 2 CPU cores on the BC-250 (**6c/12t → 8c/16t**). The
cores are not fused off, they are masked by a writable SMU register
(`SMN 0x0115A870`). This flips it from the factory `0x77` to `0xFF` at runtime
via SMU mailbox message `0x98`, no BIOS flash. It is fully reversible: a cold
power-off restores stock 6 cores.

> Method derived from [bc250-core-unlock](https://github.com/rw-r-r-0644/bc250-core-unlock)
> and [GabriWar/bc250-core-cu-unlock](https://github.com/GabriWar/bc250-core-cu-unlock),
> adapted to Batocera services and made governor-safe.

To install the script, simply run:

```
curl -sSLO https://raw.githubusercontent.com/tmghd272/bc250-batocera-tools/main/batocera-install-8core.sh && chmod +x batocera-install-8core.sh && ./batocera-install-8core.sh
```

This will automatically install, set up everything, and enable the service.

---

Once installed, it will create a service file in:

`/userdata/system/services/`

named:

`bc250_8core`

This service will automatically load `bc250_8core` on boot.

---

## Usage

```
bc250-8core status              show the core mask + how many cores the kernel sees
bc250-8core apply               unlock now (parks/restarts the GPU governor); reboot to enumerate
bc250-8core apply --reboot      unlock and warm-reboot immediately
bc250-8core apply --force       unlock a NON-standard mask (e.g. 0xD7 instead of 0x77)
bc250-8core autoreboot on|off   toggle the hands-off reboot on cold boot (default: on)
bc250-8core reset               disable the service; cold boot to revert to 6c
```

> **Note:** The unlock is **all-or-nothing**, it enables both dormant cores or
> neither. A defective core produces wrong results, not just lower speed, so
> stress-test after unlocking (e.g. `misc/test-8core.sh`) before trusting it.

Verify after the reboot:

```
nproc                                          # expect 16
grep '^core id' /proc/cpuinfo | sort -u | wc -l  # expect 8
```

---

## The reboot caveat (important)

The CPU core count is decided by the **firmware at power-on, before Linux
loads**. The tool runs from inside Linux, which is already too late: writing the
new mask only takes effect the **next** time the firmware counts cores. So the
board always comes up at **6 cores first**, and one reboot is needed to bring up
all 8.

- The `bc250_8core` service handles this automatically. With `autoreboot`
  **on** (default), on a cold boot it sets the mask and performs **one** guarded
  warm reboot so the firmware re-enumerates 8 cores. It is bounded by a marker
  file and cannot boot-loop.
- The mask is **volatile**: a **warm reboot / "Restart" preserves it** (stays at
  8 cores, no extra reboot), while a **full cold power-off reverts to 6 cores**
  (the built-in safety escape hatch), after which the one auto-reboot runs again.
- With `autoreboot off`, run `bc250-8core apply --reboot` yourself after a cold
  boot.

> **Note:** The 8-core ACPI C-state table fix used on desktop distros relies on
> `mkinitcpio`, which Batocera does not have, so the two new threads may lack
> idle C-states and draw slightly more at idle. This is cosmetic for gaming.

---

## Alternative: permanent unlock via modified BIOS

The runtime method here works around the firmware from inside Linux, which is
why every cold power cycle needs a reboot to bring the cores back. You can skip
that entirely by fixing the mask in the firmware itself, flashing a modified
BIOS ([Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script](https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script)).

Once flashed, the firmware counts all 8 cores on the very first boot, on every
boot, cold or warm. There is **no reboot dance and no cold-boot revert**, so
**this service is unnecessary** if you go the BIOS route (don't install both).

> **Note:** Flashing the BIOS is a firmware-level operation with real brick risk
> and is done outside Batocera. The runtime method in this guide is the
> reversible, no-flash alternative that leaves your stock firmware untouched.

---

## Managing the service

### Batocera UI

MAIN MENU → SYSTEM SETTINGS → SERVICES → bc250_8core (toggle on/off)

### Shell commands

```
batocera-services start bc250_8core
batocera-services enable bc250_8core
batocera-services stop bc250_8core
batocera-services disable bc250_8core
```
