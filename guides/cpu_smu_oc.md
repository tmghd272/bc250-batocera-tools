# Batocera Setup for [bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc)

To install the script, simply run:

```
curl -sSLO https://raw.githubusercontent.com/tmghd272/bc250-batocera-tools/main/batocera-install-smu-oc.sh && chmod +x batocera-install-smu-oc.sh && ./batocera-install-smu-oc.sh
```

This will automatically install, set up everything, and enable the service.

---

Once installed, it will create a service file in:

`/userdata/system/services/`

named:

`bc250_smu_oc`

This service will automatically load `bc250_smu_oc` on boot.

---
## Usage
```
bc250-detect  --frequency MHz --vid mV [--temp degC] [--keep]
 -f, --frequency   target boost clock in MHz  (valid: 3500-4500)
 -v, --vid         max CPU core voltage in mV (valid: 950-1325)
 -t, --temp        CPU temp limit in degC (default: 90)
 -k, --keep        keep overclock applied after detect finishes
Note: --config is baked in, no need to pass a path.
```
```
bc250-apply   --apply
bc250-reset   wipe overclock.conf + overclock.pending; reboot to restore BIOS stock
```
> **Note:** These commands have been reconfigured from the original to work properly with Batocera.

---

To get started, pick an overclock target and type, e.g.:
```
bc250-detect --frequency 3500 --vid 1000 --keep
```
or
```
bc250-detect -f 3500 -v 1000 -k
```

Once the command finishes, it creates a pending overclock at `/userdata/system/bc250-smu-oc/overclock.pending`. Your config is saved, but it won't be applied on reboot yet.

If you're satisfied with the overclock, run:
```
bc250-apply --apply
```
This promotes `overclock.pending` to `overclock.conf`, and the `bc250_smu_oc` Batocera service applies it on every boot from then on.

To verify the overclock is active after reboot, you can stress test the CPU by running:
```
bash -c 'stress -c "$(nproc)" & pid=$!; trap "kill $pid 2>/dev/null" EXIT; watch -n 0.2 "grep \"cpu MHz\" /proc/cpuinfo"'
```
Then press `CTRL + C` to exit the test.

---

To remove the overclock entirely:
```
bc250-reset
```
The overclock stops taking effect after `reboot`.

It's recommended to restart the Batocera service or reboot the system for changes to take effect.

---

## Managing the service

### Batocera UI

MAIN MENU → SYSTEM SETTINGS → SERVICES → bc250_smu_oc (toggle on/off)

### Shell commands

```
batocera-services start bc250_smu_oc
batocera-services enable bc250_smu_oc
batocera-services stop bc250_smu_oc
batocera-services disable bc250_smu_oc
```
---

## About stress (Optional / Advanced)

`bc250_smu_oc` depends on the `stress` binary for load testing during `bc250-detect`. It's stored at `/userdata/system/bc250-smu-oc/bin/stress`.

Batocera has no proper package manager, so `stress` can't be installed directly on the system. You'll need to obtain the binary from a Linux distribution with a working package manager (e.g. Debian/Ubuntu via `apt`, Arch via `pacman`) and copy it over manually.

> The `stress` binary included in this repo is version 1.0.7, built on an Ubuntu Linux system.

**1. Install `stress` on another Linux machine (or WSL):**
```
sudo apt install -y stress
```
Once installed, it's located at `/usr/bin/stress`.

**2. Copy it out to a location accessible from Batocera**, for example via WSL to a Windows folder:
```
cp /usr/bin/stress /mnt/c/Users/<USERNAME>/Downloads/stress
```

**3. Transfer the binary to Batocera** and place it at:
```
/userdata/system/bc250-smu-oc/bin/stress
```

Once in place, the install script and service will pick it up automatically and keep it linked at `/usr/bin/stress` on every boot.
