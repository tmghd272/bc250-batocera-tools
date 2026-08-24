#!/bin/bash
set -e

C=$(printf '\033[96m')
Y=$(printf '\033[93m')
R=$(printf '\033[0m')

INSTALL_DIR="/userdata/system/bc250-8core"
BIN_DIR="$INSTALL_DIR/bin"
TOOL="$BIN_DIR/bc250-8core"
SERVICE_NAME="bc250_8core"
SERVICE="/userdata/system/services/$SERVICE_NAME"
GOV_SERVICE="cyan_skillfish_governor_smu"

echo "${C}==> Verifying this is a BC-250...${R}"
if ! lspci -nn 2>/dev/null | grep -qi '13fe'; then
    echo "${Y}ERROR: Cyan Skillfish GPU [1002:13fe] not found. This may not be a BC-250. Aborting.${R}" >&2
    exit 1
fi
if [ ! -e /sys/bus/pci/devices/0000:00:00.0/config ]; then
    echo "${Y}ERROR: PCI device 00:00.0 config space not found. Aborting.${R}" >&2
    exit 1
fi
if ! command -v setpci >/dev/null 2>&1; then
    echo "${Y}ERROR: setpci (pciutils) not found. Aborting.${R}" >&2
    exit 1
fi
echo "    ${C}OK${R}: BC-250 confirmed"

# may be absent on a fresh install
mkdir -p /userdata/system/services
mkdir -p "$BIN_DIR"

# ── core tool ──────────────────────────────────────────────────────────────────
echo "${C}==> Installing bc250-8core tool...${R}"
cat > "$TOOL" << 'TOOLEOF'
#!/bin/bash
# bc250-8core -- enable all 8 CPU cores on the BC-250 (runtime SMU method).
# Usage: bc250-8core {status|apply [--force] [--reboot]|boot|autoreboot {on|off|status}|reset}
# Volatile: a warm reboot keeps the mask, a cold boot reverts to factory (0x77 on most boards).
set -uo pipefail

DEV=00:00.0
IDX=0xB8            # SMN address (index) register
DAT=0xBC            # SMN data register

MASK_REG=0115A870   # core-enable bitmask
RSP_REG=03B10A80    # SMU mailbox response
ARG0_REG=03B10A88   # SMU mailbox arg0
ARG1_REG=03B10A8C   # SMU mailbox arg1
MSG_REG=03B10A20    # SMU mailbox message id
MSG_UNLOCK=98       # register-write backdoor

STOCK_MASK=0x77
UNLOCKED_MASK=0xff

GOV_SERVICE="cyan_skillfish_governor_smu"
GOV_PROC="cyan-skillfish-governor-smu"
REBOOT_MODE=/sys/kernel/reboot/mode
SERVICE_NAME="bc250_8core"

STATE_DIR="/userdata/system/bc250-8core"
MARKER="$STATE_DIR/.reboot-pending"     # bounds the boot-time reboot to once per cold boot
AUTOREBOOT_FLAG="$STATE_DIR/autoreboot" # present = boot service warm-reboots once to enumerate
FORCE_FLAG="$STATE_DIR/force"           # present = unlock a non-standard (non-0x77) mask

die() { echo "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# ── SMN access (governor drives the same 0xB8/0xBC pair, so callers stop it) ──
smn_read() { setpci -s "$DEV" "$IDX.L=$1" 2>/dev/null; setpci -s "$DEV" "$DAT.L" 2>/dev/null; }
save_index() { setpci -s "$DEV" "$IDX.L" 2>/dev/null; }
restore_index() { setpci -s "$DEV" "$IDX.L=$1" 2>/dev/null; }
hex2dec() { printf '%d' "0x${1#0x}" 2>/dev/null || echo 0; }
read_mask() { echo $(( $(hex2dec "$(smn_read "$MASK_REG")") & 0xff )); }

describe() {
    local m=$1 on="" off="" i
    for i in 0 1 2 3 4 5 6 7; do
        if (( (m >> i) & 1 )); then on="$on$i "; else off="$off$i "; fi
    done
    printf '0x%02X enabled=[%s] disabled=[%s]' "$m" "${on% }" "${off% }"
}

# whole mailbox write in ONE setpci call so nothing else can split the index/data pairs
send_unlock() {
    setpci -s "$DEV" \
        "$IDX.L=$RSP_REG"  "$DAT.L=00000000" \
        "$IDX.L=$ARG0_REG" "$DAT.L=$MASK_REG" \
        "$IDX.L=$ARG1_REG" "$DAT.L=00000000" \
        "$IDX.L=$MSG_REG"  "$DAT.L=000000$MSG_UNLOCK" 2>/dev/null
    local i resp
    for i in $(seq 1 200); do
        resp=$(hex2dec "$(smn_read "$RSP_REG")")
        if [ "$resp" -eq 1 ] || { [ "$resp" -ge 252 ] && [ "$resp" -le 255 ]; }; then break; fi
    done
    echo "$resp"
}

gov_running() { pgrep -f "$GOV_PROC" >/dev/null 2>&1; }
gov_stop() {
    pkill -f "$GOV_PROC" 2>/dev/null || true
    rm -f /var/run/${GOV_SERVICE}.pid 2>/dev/null || true
    sleep 0.3
}
gov_start() { batocera-services start "$GOV_SERVICE" >/dev/null 2>&1 || true; }

core_count() { grep '^core id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l; }

# write the mask with the governor safely parked; returns via globals RESP/AFTER
do_write() {
    local was_running=0
    gov_running && was_running=1
    [ "$was_running" -eq 1 ] && gov_stop
    local saved; saved=$(save_index)
    RESP=$(send_unlock)
    AFTER=$(read_mask)
    restore_index "$saved"
    [ "$was_running" -eq 1 ] && gov_start
}

cmd_status() {
    local mask cores
    if gov_running; then
        # park the governor for an accurate read (it drives the same index register)
        gov_stop; mask=$(read_mask); gov_start
    else
        mask=$(read_mask)
    fi
    cores=$(core_count)
    echo "SMN 0x$MASK_REG = $(describe "$mask")"
    case $mask in
        $((UNLOCKED_MASK))) echo "state: UNLOCKED (all 8 cores)";;
        $((STOCK_MASK)))    echo "state: STOCK (6 cores) -- run 'bc250-8core apply' to unlock";;
        *)                  echo "state: UNKNOWN mask";;
    esac
    echo "physical cores visible to kernel: $cores   (nproc=$(nproc))"
    if [ "$mask" -eq $((UNLOCKED_MASK)) ] && [ "$cores" -lt 8 ]; then
        echo "note: mask is set but firmware has not re-enumerated -- WARM reboot needed"
    fi
}

cmd_apply() {
    need_root
    local force=0 do_reboot=0 a
    for a in "$@"; do
        case "$a" in
            --force)  force=1;;
            --reboot) do_reboot=1;;
        esac
    done
    local before; before=$( { gov_running && { gov_stop; read_mask; gov_start; } || read_mask; } )
    echo "before: $(describe "$before")"
    if [ "$before" -eq $((UNLOCKED_MASK)) ]; then
        echo "already unlocked, nothing to do (reboot if you still see 6 cores)"; return 0
    fi
    if [ "$before" -ne $((STOCK_MASK)) ]; then
        if [ "$force" -ne 1 ]; then
            echo "refusing: non-standard mask $(printf '0x%02X' "$before") (the usual factory mask is 0x77)." >&2
            echo "Your board has a DIFFERENT core pair disabled than most. It can still be" >&2
            echo "unlocked, but non-standard masks are likelier to hide a genuinely bad core." >&2
            echo "Re-run with --force to proceed, then MANDATORY: run test-8core.sh and stress-" >&2
            echo "test before trusting the new cores." >&2
            exit 1
        fi
        echo "--force: proceeding on non-standard mask $(printf '0x%02X' "$before")"
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        touch "$FORCE_FLAG" 2>/dev/null || true   # so the boot service also forces on cold boot
    fi
    local RESP AFTER; do_write
    if [ "$RESP" -eq 1 ]; then echo "SMU response: 0x1 (OK)"; else echo "SMU response: $(printf '0x%x' "$RESP") (ERROR/timeout)"; fi
    echo "after:  $(describe "$AFTER")"
    [ "$AFTER" -eq $((UNLOCKED_MASK)) ] || die "unlock FAILED -- mask unchanged, nothing broken"
    echo
    echo "unlocked. all 8 cores appear after a WARM reboot."
    if [ "$do_reboot" -eq 1 ]; then
        [ -w "$REBOOT_MODE" ] && echo warm > "$REBOOT_MODE" 2>/dev/null || true
        echo "warm-rebooting now..."; sync; reboot
    else
        echo "run:  reboot        (a normal Batocera restart is warm and keeps the mask)"
        echo "a cold boot / power cycle reverts to $( [ "$before" -eq $((STOCK_MASK)) ] && echo 6 || echo 'the factory' ) cores."
    fi
}

# Boot path: set the mask, then (if autoreboot on) do ONE marker-guarded warm
# reboot so firmware enumerates all 8 cores. The MARKER makes it impossible to loop.
cmd_boot() {
    local cores mask
    cores=$(core_count)
    if [ "$cores" -ge 8 ]; then
        rm -f "$MARKER" 2>/dev/null || true   # enumerated -> arm for the next cold boot
        echo "bc250-8core: $cores cores active, nothing to do"
        return 0
    fi

    mask=$(read_mask)
    if [ "$mask" -ne $((UNLOCKED_MASK)) ]; then
        if [ "$mask" -eq $((STOCK_MASK)) ] || [ -f "$FORCE_FLAG" ]; then
            local RESP AFTER; do_write; mask=$AFTER
            if [ "$mask" -eq $((UNLOCKED_MASK)) ]; then
                echo "bc250-8core: mask set to 0xFF"
            else
                echo "bc250-8core: unlock failed (SMU $(printf '0x%x' "$RESP")) -- staying at $cores cores" >&2
                return 0
            fi
        else
            echo "bc250-8core: non-standard mask $(printf '0x%02X' "$mask") and no force flag -- not touching (run 'bc250-8core apply --force' once)" >&2
            return 0
        fi
    fi

    # mask is 0xFF but firmware has not enumerated the extra cores yet
    if [ ! -f "$AUTOREBOOT_FLAG" ]; then
        echo "bc250-8core: mask 0xFF set -- reboot to bring up all 8 cores (autoreboot off)"
        return 0
    fi
    if [ -f "$MARKER" ]; then
        echo "bc250-8core: already warm-rebooted once and still <8 cores -- giving up, staying at $cores cores" >&2
        rm -f "$MARKER" 2>/dev/null || true
        return 0
    fi
    touch "$MARKER" 2>/dev/null || true
    [ -w "$REBOOT_MODE" ] && echo warm > "$REBOOT_MODE" 2>/dev/null || true
    echo "bc250-8core: mask set, warm-rebooting ONCE to enumerate all 8 cores..."
    sync
    reboot
}

cmd_autoreboot() {
    need_root
    case "${1:-status}" in
        on)  mkdir -p "$STATE_DIR"; touch "$AUTOREBOOT_FLAG"
             echo "autoreboot: ON  -- the box warm-reboots itself once per cold boot to reach 8c";;
        off) rm -f "$AUTOREBOOT_FLAG" "$MARKER"
             echo "autoreboot: OFF -- after a cold boot, run 'bc250-8core apply --reboot' yourself";;
        status|*) [ -f "$AUTOREBOOT_FLAG" ] && echo "autoreboot: ON" || echo "autoreboot: OFF";;
    esac
}

cmd_reset() {
    need_root
    batocera-services disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$MARKER" 2>/dev/null || true
    echo "boot service disabled. The mask is volatile:"
    echo "  - a COLD boot (remove power / PSU switch) reverts to stock cores."
    echo "  - a warm reboot alone will NOT revert it."
    echo "Power the board fully off and on to return to stock 6c/12t."
}

case "${1:-}" in
    status)     cmd_status ;;
    apply)      shift; cmd_apply "$@" ;;
    boot)       cmd_boot ;;
    autoreboot) cmd_autoreboot "${2:-}" ;;
    reset)      cmd_reset ;;
    *) echo "Usage: bc250-8core {status|apply [--force] [--reboot]|boot|autoreboot {on|off|status}|reset}"; exit 1 ;;
esac
TOOLEOF
chmod +x "$TOOL"
echo "    ${C}OK${R}: $TOOL"

# ── Batocera service (boot path: set mask, no reboot) ───────────────────────────
echo "${C}==> Installing Batocera service...${R}"
cat > "$SERVICE" << SVCEOF
#!/bin/bash
# Batocera oneshot service: bc250_8core
# Sets the core-enable mask each boot (one guarded warm reboot if autoreboot is on).
TOOL="$TOOL"
LOGFILE="$INSTALL_DIR/8core.log"

start() {
    # recreate /usr/bin symlink (tmpfs, wiped on reboot)
    rm -f /usr/bin/bc250-8core
    ln -sf "\$TOOL" /usr/bin/bc250-8core
    if [ -x "\$TOOL" ]; then
        echo "\$(date): bc250_8core boot" >> "\$LOGFILE"
        "\$TOOL" boot >> "\$LOGFILE" 2>&1
    fi
}

stop() { echo "bc250_8core: oneshot service, nothing to stop"; }

case "\$1" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "Usage: \$0 {start|stop}"; exit 1 ;;
esac
SVCEOF
chmod +x "$SERVICE"

echo "${C}==> Enabling service...${R}"
batocera-services enable "$SERVICE_NAME"

# default: autoreboot ON so the box reaches 8c hands-off across cold power cycles
echo "${C}==> Enabling autoreboot (hands-off across cold boots)...${R}"
touch "$INSTALL_DIR/autoreboot"

echo "${C}==> Creating /usr/bin/bc250-8core symlink...${R}"
rm -f /usr/bin/bc250-8core
ln -sf "$TOOL" /usr/bin/bc250-8core

echo ""
echo "${C}========================================${R}"
echo "${C} bc250-8core — Batocera ready${R}"
echo "${C}========================================${R}"
echo "${C} Tool:${R}    $TOOL"
echo "${C} Service:${R} $SERVICE_NAME (sets mask each boot; autoreboot ON by default)"
echo "${C} Log:${R}     $INSTALL_DIR/8core.log"
echo "${C}========================================${R}"
echo ""
echo "Commands:"
echo "  ${C}bc250-8core status${R}              show mask + core count"
echo "  ${C}bc250-8core apply${R}               unlock now (governor-safe); reboot to enumerate"
echo "  ${C}bc250-8core apply --reboot${R}      unlock and warm-reboot immediately"
echo "  ${C}bc250-8core apply --force${R}       unlock a NON-standard mask (e.g. 0xD7)"
echo "  ${C}bc250-8core autoreboot on|off${R}   toggle hands-off reboot on cold boot"
echo "  ${C}bc250-8core reset${R}               disable service; cold boot to revert to 6c"
echo ""
echo "${Y}IMPORTANT${R}"
echo "  - All-or-nothing: the SMU primitive enables BOTH dormant cores or neither."
echo "    If a core is defective you cannot mask just one (unlike the CU unlock)."
echo "    STRESS-TEST after unlocking; a bad core corrupts results, not just speed."
echo "  - Cores appear only AFTER a reboot (firmware enumerates at reset)."
echo "  - Volatile: a COLD boot reverts to stock (escape hatch). With autoreboot ON"
echo "    (default) the box warm-reboots itself ONCE per cold boot to reach 8c; the"
echo "    reboot is marker-guarded and can never loop. Turn off with 'autoreboot off'."
echo "  - Non-standard mask (not 0x77, e.g. 0xD7 = cores 3+5 off): use 'apply --force'"
echo "    once; the boot service then handles it automatically on later boots."
echo "  - ACPI C-state fix for the 2 new threads is NOT applied (the community fix"
echo "    uses mkinitcpio, which Batocera does not have). CPUs 12-15 may lack idle"
echo "    states and draw a little more at idle."
echo "${C}========================================${R}"
