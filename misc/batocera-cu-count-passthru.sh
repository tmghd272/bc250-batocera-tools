#!/bin/bash
# batocera-cu-count-passthru.sh
#
# Batocera-specific companion to bc250-cu-manager. A batocera-services
# background loop periodically reads the live SPI dispatch mask via the
# bundled umr binary (same one bc250-cu-manager already installed) and
# writes the active CU count to /tmp/bc250_cu_count — a world-readable
# file any unprivileged reader (startup.py, MangoHud, etc.) can consume
# without root/sudo/umr of its own.
#
# Requires bc250-cu-manager already installed via
# batocera-install-cu-manager.sh (uses its umr binary + database).
#
# Usage:
#   bash batocera-cu-count-passthru.sh install
#   bash batocera-cu-count-passthru.sh uninstall
#   bash batocera-cu-count-passthru.sh write     # internal: single read/write pass

set -e

CU_MGR_DIR="/userdata/system/bc250-cu-manager"
BIN_DIR="$CU_MGR_DIR/bin"
UMR_BIN="$BIN_DIR/umr"
DB_DIR="$CU_MGR_DIR/database"
UMR_ASIC="cyan_skillfish.gfx1013"

INSTALL_DIR="/userdata/system/bc250-cu-count-passthru"
SCRIPT_DEST="$INSTALL_DIR/batocera-cu-count-passthru.sh"
SERVICE_NAME="bc250_cu_count"
SERVICE="/userdata/system/services/$SERVICE_NAME"
PIDFILE="/tmp/bc250_cu_count.pid"
OUT_FILE="/tmp/bc250_cu_count"
INTERVAL=30

require_cu_manager() {
    if [ ! -x "$UMR_BIN" ]; then
        echo "bc250-cu-manager isn't installed (missing $UMR_BIN)."
        echo "Run batocera-install-cu-manager.sh first."
        exit 1
    fi
}

dmesg_fallback() {
    # Only accurate for the kernel-patched unlock (bc250-40cu-unlock), where
    # the CU count is set at driver init. Stale/wrong for live umr-remask
    # setups, where this would still show the boot-time (usually 24) value.
    val=$(dmesg 2>/dev/null | grep -oP 'active_cu_number \K[0-9]+' | tail -1 || true)
    if [ -n "$val" ]; then
        echo "$val" > "$OUT_FILE"
        chmod 644 "$OUT_FILE"
        return 0
    fi
    echo "0" > "$OUT_FILE"
    chmod 644 "$OUT_FILE"
    return 1
}

write_cu_count() {
    if [ ! -x "$UMR_BIN" ]; then
        dmesg_fallback
        return $?
    fi
    total=0
    for args in "0 0 0" "0 1 0" "1 0 0" "1 1 0"; do
        val=$(UMR_DATABASE_PATH="$DB_DIR" LD_LIBRARY_PATH="$BIN_DIR" \
            "$UMR_BIN" -r "$UMR_ASIC.mmSPI_PG_ENABLE_STATIC_WGP_MASK" -b $args 2>/dev/null \
            | grep -oP '0x[0-9a-f]+' || true)
        if [ -z "$val" ]; then
            dmesg_fallback
            return $?
        fi
        bits=$(python3 -c "print(bin($val).count('1'))")
        total=$((total + bits * 2))
    done
    echo "$total" > "$OUT_FILE"
    chmod 644 "$OUT_FILE"
}

loop_forever() {
    while true; do
        write_cu_count || true
        sleep "$INTERVAL"
    done
}

install_passthru() {
    require_cu_manager

    mkdir -p "$INSTALL_DIR"
    cp "$0" "$SCRIPT_DEST"
    chmod +x "$SCRIPT_DEST"

    cat > "$SERVICE" << SVCEOF
#!/bin/bash
# Batocera background service: bc250_cu_count
SCRIPT="$SCRIPT_DEST"
PIDFILE="$PIDFILE"

start() {
    bash "\$SCRIPT" loop &
    echo \$! > "\$PIDFILE"
}

stop() {
    if [ -f "\$PIDFILE" ]; then
        kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
        rm -f "\$PIDFILE"
    fi
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    *) echo "Usage: \$0 {start|stop}"; exit 1 ;;
esac
SVCEOF
    chmod +x "$SERVICE"

    batocera-services enable "$SERVICE_NAME"
    batocera-services restart "$SERVICE_NAME"

    echo "Installed. Checking output..."
    sleep 2
    cat "$OUT_FILE" 2>/dev/null || echo "(no output yet, check /tmp/bc250_cu_count shortly)"
}

uninstall_passthru() {
    batocera-services disable "$SERVICE_NAME" 2>/dev/null || true
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    rm -f "$SERVICE" "$PIDFILE" "$OUT_FILE"
    rm -rf "$INSTALL_DIR"

    echo "Uninstalled."
}

case "$1" in
    install)
        install_passthru
        ;;
    uninstall)
        uninstall_passthru
        ;;
    write)
        write_cu_count
        ;;
    loop)
        loop_forever
        ;;
    *)
        echo "Usage: $0 {install|uninstall|write}"
        exit 1
        ;;
esac
