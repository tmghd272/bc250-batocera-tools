# Batocera Setup for [bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)

To install the script, simply run:

```
curl -sSLO https://raw.githubusercontent.com/tmghd272/bc250-batocera-tools/main/batocera-install-cu-manager.sh && chmod +x batocera-install-cu-manager.sh && ./batocera-install-cu-manager.sh
```

This will automatically install, set up everything, and enable the service.

---

Once installed, it will create a service file in:

`/userdata/system/services/`

named:

`bc250_cu_manager`

This service will automatically load `bc250_cu_manager` on boot.

---

## Modifying the Compute Units table

Simply run:

```
cu-menu
```

Running the `cu-menu` command will automatically run `bc250-cu-live-manager.sh` with the required arguments for Batocera.

---

Once inside the Live Manager, press `[e] Edit WGP table` or `[f] Enable all CUs`.

This will open the WGP Table Editor.

In the editor, follow the instructions:
`Arrows / h j k l` move selection, `Space` toggles selected entries.

Once satisfied, press `Enter` or `a` to apply.

Follow the prompts:
`Type 'accept' to continue or 'no' to cancel:` and `Apply changes? [y/n]:`

Once you are back in the CU Dashboard, after making any changes, you must press `[w] Write table`.

Once done, simply press `[q] Quit`.

Note: `[i] Install service` and `[u] Uninstall service` are obsolete on Batocera systems because it already uses batocera services instead of standard systemd service management. These options can be safely ignored.

It is recommended to restart the Batocera service or reboot the system for changes to take effect.

---

## Managing the service

### Batocera UI

MAIN MENU → SYSTEM SETTINGS → SERVICES → bc250_cu_manager (toggle on/off)

### Shell commands

```
batocera-services start bc250_cu_manager
batocera-services enable bc250_cu_manager
batocera-services stop bc250_cu_manager
batocera-services disable bc250_cu_manager
```
