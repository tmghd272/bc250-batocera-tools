# Batocera Setup for [cyan_skillfish_governor_smu](https://github.com/filippor/cyan-skillfish-governor)

To install the script, simply run:

```
curl -sSLO https://raw.githubusercontent.com/tmghd272/bc250-batocera-tools/main/batocera-install-governor_smu.sh && chmod +x batocera-install-governor_smu.sh && ./batocera-install-governor_smu.sh
```

This will automatically install, set up everything, and enable the service.

---

Once installed, it will create a service file in:

`/userdata/system/services/`

named:

`cyan_skillfish_governor_smu`

This service will automatically load `cyan_skillfish_governor_smu` on boot.

---

## Changing the config.toml

The config file should be stored in:

`/userdata/system/cyan-skillfish-governor/config.toml`

It uses the default configuration from the [cyan_skillfish_governor_smu](https://github.com/filippor/cyan-skillfish-governor/blob/smu/default-config.toml) repo. You will need to modify it manually if you want to customize APU clock and voltage settings.

After making any changes, you will need to restart the service for them to take effect.

---

## Managing the service

### Batocera UI

MAIN MENU → SYSTEM SETTINGS → SERVICES → cyan_skillfish_governor_smu
(toggle on/off)

### Shell commands

```
batocera-services start cyan_skillfish_governor_smu
batocera-services enable cyan_skillfish_governor_smu
batocera-services stop cyan_skillfish_governor_smu
batocera-services disable cyan_skillfish_governor_smu
```
