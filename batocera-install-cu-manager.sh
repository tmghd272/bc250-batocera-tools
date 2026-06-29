#!/bin/bash
set -e

C=$'\033[96m'
R=$'\033[0m'

INSTALL_DIR="/userdata/system/bc250-cu-manager"
BIN_DIR="$INSTALL_DIR/bin"
UMR_BIN="$BIN_DIR/umr"
MANAGER_BIN="$BIN_DIR/bc250-cu-live-manager.sh"
MANAGER_URL="https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/main/bc250-cu-live-manager.sh"
CONF="$INSTALL_DIR/bc250-cu-live-manager.conf"
DB_DIR="$INSTALL_DIR/database"
SERVICE_NAME="bc250_cu_manager"
SERVICE="/userdata/system/services/$SERVICE_NAME"

mkdir -p "$BIN_DIR" "$DB_DIR"

# ── debugfs ────────────────────────────────────────────────────────────────────
echo "${C}==> Ensuring debugfs is mounted...${R}"
if ! mount | grep -q debugfs; then
    mount -t debugfs none /sys/kernel/debug
    echo "    Mounted."
else
    echo "    Already mounted."
fi
FSTAB="/userdata/system/fstab"
if ! grep -q debugfs "$FSTAB" 2>/dev/null; then
    echo "none /sys/kernel/debug debugfs defaults 0 0" >> "$FSTAB"
    echo "    Added debugfs to $FSTAB (persists on boot)"
fi

# ── umr ────────────────────────────────────────────────────────────────────────
echo "${C}==> Checking for umr...${R}"

UMR_BUNDLE_URL="https://github.com/tmghd272/bc250-batocera-tools/raw/main/umr-bc250.tar.gz"

download_umr_bundle() {
    echo "    Downloading umr BC-250 bundle..."
    curl -fsSL "$UMR_BUNDLE_URL" -o /tmp/umr-bc250.tar.gz
    echo "    Extracting..."
    tar -xzf /tmp/umr-bc250.tar.gz -C /tmp/
    cp /tmp/umr-bc250/bin/umr "$UMR_BIN"
    cp /tmp/umr-bc250/bin/libncurses.so.6 "$BIN_DIR/"
    cp /tmp/umr-bc250/bin/libtinfo.so.6 "$BIN_DIR/"
    cp -r /tmp/umr-bc250/database/* "$DB_DIR/"
    chmod +x "$UMR_BIN"
    rm -rf /tmp/umr-bc250 /tmp/umr-bc250.tar.gz
    echo "    ${C}OK${R}: umr bundle installed"
}

verify_umr() {
    UMR_DATABASE_PATH="$DB_DIR" LD_LIBRARY_PATH="$BIN_DIR" \
        "$UMR_BIN" -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 2>&1 \
        | grep -q "SPI_PG_ENABLE_STATIC_WGP_MASK =>"
}

if [ ! -x "$UMR_BIN" ]; then
    download_umr_bundle
else
    echo "    Found: $UMR_BIN — verifying..."
    chmod +x "$UMR_BIN"
    if ! verify_umr; then
        echo "    Existing umr failed verify — redownloading bundle..."
        rm -f "$UMR_BIN"
        rm -rf "$DB_DIR"
        mkdir -p "$DB_DIR"
        download_umr_bundle
    else
        echo "    ${C}OK${R}: already working"
    fi
fi

echo "${C}==> Verifying umr GPU register access...${R}"
RESULT=$(UMR_DATABASE_PATH="$DB_DIR" LD_LIBRARY_PATH="$BIN_DIR" \
    "$UMR_BIN" -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 2>&1) || true
if echo "$RESULT" | grep -q "SPI_PG_ENABLE_STATIC_WGP_MASK =>"; then
    echo "    ${C}OK${R}: $RESULT"
else
    echo "    ${C}ERROR${R}: $RESULT"
    exit 1
fi

# ── manager script ─────────────────────────────────────────────────────────────
echo "${C}==> Downloading latest bc250-cu-live-manager.sh...${R}"
curl -fsSL "$MANAGER_URL" -o "$MANAGER_BIN"
chmod +x "$MANAGER_BIN"
echo "    ${C}OK${R}: $MANAGER_BIN"

# ── Batocera service ───────────────────────────────────────────────────────────
echo "${C}==> Installing Batocera service...${R}"
cat > "$SERVICE" << 'SVCEOF'
#!/bin/bash
# Batocera oneshot service: bc250-cu-live-manager
# Applies saved WGP table on boot + creates cu-menu command.

BIN_DIR="/userdata/system/bc250-cu-manager/bin"
MANAGER="$BIN_DIR/bc250-cu-live-manager.sh"
CONF="/userdata/system/bc250-cu-manager/bc250-cu-live-manager.conf"
LOGFILE="/userdata/system/bc250-cu-manager/cu-manager.log"

export UMR="$BIN_DIR/umr"
export UMR_DATABASE_PATH="/userdata/system/bc250-cu-manager/database"
export LD_LIBRARY_PATH="$BIN_DIR"
export UMR_ASIC="cyan_skillfish.gfx1013"
export SERVICE_CONF="$CONF"
export SERVICE_BIN="$MANAGER"

start() {
    # Recreate /etc symlink (tmpfs, wiped on reboot)
    rm -f /etc/bc250-cu-live-manager.conf
    ln -sf "$CONF" /etc/bc250-cu-live-manager.conf

    # Recreate cu-menu in /usr/bin (tmpfs, wiped on reboot)
    cat > /usr/bin/cu-menu << 'MENUEOF'
#!/bin/bash
exec env \
  UMR=/userdata/system/bc250-cu-manager/bin/umr \
  UMR_DATABASE_PATH=/userdata/system/bc250-cu-manager/database \
  LD_LIBRARY_PATH=/userdata/system/bc250-cu-manager/bin \
  UMR_ASIC=cyan_skillfish.gfx1013 \
  SERVICE_CONF=/userdata/system/bc250-cu-manager/bc250-cu-live-manager.conf \
  SERVICE_BIN=/userdata/system/bc250-cu-manager/bin/bc250-cu-live-manager.sh \
  bash /userdata/system/bc250-cu-manager/bin/bc250-cu-live-manager.sh menu
MENUEOF
    chmod +x /usr/bin/cu-menu

    mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug

    if [ ! -x "$MANAGER" ]; then
        echo "bc250-cu-manager: manager not found at $MANAGER" >&2; exit 1
    fi
    if [ ! -f "$CONF" ]; then
        echo "bc250-cu-manager: no saved WGP table at $CONF" >&2
        echo "  Run cu-menu and use [w] Write table first." >&2
        exit 1
    fi

    echo "bc250-cu-manager: waiting for DRI device..." | tee -a "$LOGFILE"
    waited=0
    while [ $waited -lt 30 ]; do
        ls /dev/dri/renderD* >/dev/null 2>&1 && break
        sleep 1; waited=$((waited + 1))
    done
    if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
        echo "bc250-cu-manager: DRI not ready after 30s, aborting" | tee -a "$LOGFILE"
        exit 1
    fi

    echo "bc250-cu-manager: applying saved WGP table..." | tee -a "$LOGFILE"
    bash "$MANAGER" --yes apply-service >> "$LOGFILE" 2>&1
    echo "bc250-cu-manager: done" | tee -a "$LOGFILE"
}

stop() {
    echo "bc250-cu-manager: oneshot service, nothing to stop"
}

case "$1" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "Usage: $0 {start|stop}"; exit 1 ;;
esac
SVCEOF
chmod +x "$SERVICE"

rm -f "/userdata/system/services/bc250-cu-live-manager"
rm -f "/userdata/system/services/bc250-cu-manager"

echo "${C}==> Enabling service...${R}"
batocera-services enable "$SERVICE_NAME"

# ── immediate setup (recreate what the service does on boot, right now) ────────
echo "${C}==> Setting up for immediate use...${R}"

# /etc symlink
rm -f /etc/bc250-cu-live-manager.conf
ln -sf "$CONF" /etc/bc250-cu-live-manager.conf

# cu-menu in /usr/bin (in PATH on Batocera)
cat > /usr/bin/cu-menu << 'MENUEOF'
#!/bin/bash
exec env \
  UMR=/userdata/system/bc250-cu-manager/bin/umr \
  UMR_DATABASE_PATH=/userdata/system/bc250-cu-manager/database \
  LD_LIBRARY_PATH=/userdata/system/bc250-cu-manager/bin \
  UMR_ASIC=cyan_skillfish.gfx1013 \
  SERVICE_CONF=/userdata/system/bc250-cu-manager/bc250-cu-live-manager.conf \
  SERVICE_BIN=/userdata/system/bc250-cu-manager/bin/bc250-cu-live-manager.sh \
  bash /userdata/system/bc250-cu-manager/bin/bc250-cu-live-manager.sh menu
MENUEOF
chmod +x /usr/bin/cu-menu

echo "    ${C}OK${R}: cu-menu installed to /usr/bin/cu-menu"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo "${C}========================================${R}"
echo "${C} bc250-cu-live-manager — Batocera ready${R}"
echo "${C}========================================${R}"
echo "${C} UMR:${R}     $UMR_BIN"
echo "${C} Manager:${R} $MANAGER_BIN"
echo "${C} Config:${R}  $CONF"
echo "${C} Logs:${R}    $INSTALL_DIR/cu-manager.log"
echo "${C}========================================${R}"
echo ""
echo "Open the interactive menu:"
echo ""
echo "  ${C}cu-menu${R}"
echo ""
echo "Or manually:"
echo "  UMR=$UMR_BIN \\"
echo "  UMR_DATABASE_PATH=$DB_DIR \\"
echo "  LD_LIBRARY_PATH=$BIN_DIR \\"
echo "  UMR_ASIC=cyan_skillfish.gfx1013 \\"
echo "  SERVICE_CONF=$CONF \\"
echo "  bash $MANAGER_BIN menu"
echo ""
echo "Workflow:"
echo "  [e] Edit WGP table"      
echo "  [f] Enable all CUs"
echo "  [w] Write table (saves for boot)"
echo "  [q] Quit"
echo "  Reboot — table auto-applied on every boot."
echo ""
Y=$'\033[93m'  # bright yellow for warnings
echo "${Y}  !! NOTE: [i] install service is not needed !!${R}"
echo "${Y}     [i] attempts to install a systemd service — Batocera does not use systemd services.${R}"
echo "${Y}     /userdata/system/services/bc250_cu_manager already handles boot automatically. Use [w] to apply changes.${R}"
echo "${Y}     If needed, restart with: batocera-services restart bc250_cu_manager${R}"
echo "${C}========================================${R}"
