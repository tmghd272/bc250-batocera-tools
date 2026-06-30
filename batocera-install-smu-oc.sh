#!/bin/bash
set -e

C=$(printf '\033[96m')
Y=$(printf '\033[93m')
R=$(printf '\033[0m')

INSTALL_DIR="/userdata/system/bc250-smu-oc"
BIN_DIR="$INSTALL_DIR/bin"
REPO_DIR="$INSTALL_DIR/bc250_smu_oc"
VENV_DIR="$INSTALL_DIR/venv"
CONF="$INSTALL_DIR/overclock.conf"
PENDING="$INSTALL_DIR/overclock.pending"
SERVICE_NAME="bc250_smu_oc"
SERVICE="/userdata/system/services/$SERVICE_NAME"
REPO_URL="https://github.com/bc250-collective/bc250_smu_oc/tarball/main"

echo "${C}==> Stopping any existing bc250_smu_oc instances...${R}"
if [ -x "$SERVICE" ]; then
    "$SERVICE" stop 2>/dev/null || true
fi
rm -f /var/run/bc250_smu_oc.pid

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# ── fetch repo ─────────────────────────────────────────────────────────────────
echo "${C}==> Downloading bc250_smu_oc from GitHub...${R}"
curl -fsSL "$REPO_URL" -o /tmp/bc250-smu-oc.tar.gz
mkdir -p "$REPO_DIR"
tar -xzf /tmp/bc250-smu-oc.tar.gz -C "$REPO_DIR" --strip-components=1
rm -f /tmp/bc250-smu-oc.tar.gz
echo "    ${C}OK${R}: $REPO_DIR"

# ── stress binary ──────────────────────────────────────────────────────────────
echo "${C}==> Checking for stress binary...${R}"
STRESS_BIN="$BIN_DIR/stress"
if [ ! -x "$STRESS_BIN" ]; then
    echo "    stress not found — downloading prebuilt binary..."
    curl -fsSL "https://github.com/tmghd272/bc250-batocera-tools/raw/main/dependencies/stress" \
        -o "$STRESS_BIN" 2>/dev/null || {
        echo "${Y}    WARNING: Could not download stress binary.${R}"
        echo "${Y}    bc250-detect will fail — build stress manually or skip detection.${R}"
    }
    chmod +x "$STRESS_BIN" 2>/dev/null || true
else
    echo "    ${C}OK${R}: stress already at $STRESS_BIN"
fi
if [ -x "$STRESS_BIN" ]; then
    rm -f /usr/bin/stress
    ln -sf "$STRESS_BIN" /usr/bin/stress
    echo "    ${C}OK${R}: /usr/bin/stress → $STRESS_BIN"
fi

# ── pip + venv ─────────────────────────────────────────────────────────────────
echo "${C}==> Bootstrapping pip...${R}"
python -m ensurepip --upgrade 2>/dev/null || true
echo "    ${C}OK${R}: pip ready"

echo "${C}==> Creating virtual environment...${R}"
if [ ! -d "$VENV_DIR" ]; then
    python -m venv "$VENV_DIR"
fi
echo "    ${C}OK${R}: $VENV_DIR"

echo "${C}==> Installing bc250_smu_oc package into venv...${R}"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet "$REPO_DIR"
echo "    ${C}OK${R}: bc250-smu-oc installed"

# ── /etc symlink (recreated on boot by service) ────────────────────────────────
echo "${C}==> Creating /etc symlink...${R}"
rm -f /etc/bc250-smu-oc.conf
ln -sf "$CONF" /etc/bc250-smu-oc.conf
echo "    ${C}OK${R}: /etc/bc250-smu-oc.conf → $CONF"

# ── Batocera service ───────────────────────────────────────────────────────────
echo "${C}==> Installing Batocera service...${R}"
cat > "$SERVICE" << SVCEOF
#!/bin/bash
# Batocera oneshot service: bc250-smu-oc
# Applies saved CPU overclock config on every boot.

VENV_DIR="/userdata/system/bc250-smu-oc/venv"
REPO_DIR="/userdata/system/bc250-smu-oc/bc250_smu_oc"
CONF="/userdata/system/bc250-smu-oc/overclock.conf"
LOGFILE="/userdata/system/bc250-smu-oc/smu-oc.log"

start() {
    # Recreate /etc symlink (tmpfs, wiped on reboot)
    rm -f /etc/bc250-smu-oc.conf
    ln -sf "\$CONF" /etc/bc250-smu-oc.conf

    # Recreate /usr/bin symlinks (tmpfs, wiped on reboot)
    BIN_DIR="/userdata/system/bc250-smu-oc/bin"
    for cmd in stress bc250-apply bc250-detect bc250-reset; do
        if [ -x "\$BIN_DIR/\$cmd" ]; then
            rm -f "/usr/bin/\$cmd"
            ln -sf "\$BIN_DIR/\$cmd" "/usr/bin/\$cmd"
        fi
    done

    if [ ! -x "\$VENV_DIR/bin/python" ]; then
        echo "bc250-smu-oc: venv not found at \$VENV_DIR" >&2; exit 1
    fi
    if [ ! -f "\$CONF" ]; then
        echo "bc250-smu-oc: no config at \$CONF — run bc250-detect first" | tee -a "\$LOGFILE" >&2
        exit 0
    fi
    echo "bc250-smu-oc: applying overclock config..." | tee -a "\$LOGFILE"
    "\$VENV_DIR/bin/python" "\$REPO_DIR/bc250_apply.py" --apply "\$CONF" >> "\$LOGFILE" 2>&1
    echo "bc250-smu-oc: done" | tee -a "\$LOGFILE"
}

stop() {
    echo "bc250-smu-oc: oneshot service, nothing to stop"
}

case "\$1" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "Usage: \$0 {start|stop}"; exit 1 ;;
esac
SVCEOF
chmod +x "$SERVICE"

echo "${C}==> Enabling service...${R}"
batocera-services enable "$SERVICE_NAME"

# ── command wrappers ───────────────────────────────────────────────────────────
# Written to persistent BIN_DIR, symlinked into /usr/bin (tmpfs).
# Service recreates symlinks on every boot.
echo "${C}==> Installing bc250-detect / bc250-apply / bc250-reset...${R}"

cat > "$BIN_DIR/bc250-detect" << WEOF
#!/bin/bash
# Writes to overclock.pending (staged). Use bc250-apply --apply to promote and apply.
# Usage: bc250-detect --frequency MHz --vid mV [--temp degC] [--keep]
exec "$VENV_DIR/bin/python" "$REPO_DIR/bc250_detect.py" --config "$PENDING" "\$@"
WEOF
chmod +x "$BIN_DIR/bc250-detect"
rm -f /usr/bin/bc250-detect
ln -sf "$BIN_DIR/bc250-detect" /usr/bin/bc250-detect

cat > "$BIN_DIR/bc250-apply" << WEOF
#!/bin/bash
# Promotes overclock.pending to overclock.conf, then applies it.
# Usage: bc250-apply --apply
CONF="$CONF"
PENDING="$PENDING"
VENV="$VENV_DIR"
REPO="$REPO_DIR"

if [ "\$1" != "--apply" ]; then
    echo "Usage: bc250-apply --apply"
    echo ""
    echo "  Promotes overclock.pending to overclock.conf (if present),"
    echo "  then applies the resulting overclock.conf via the SMU."
    echo ""
    echo "  Config:  \$CONF"
    echo "  Pending: \$PENDING"
    exit 0
fi
shift

if [ ! -f "\$PENDING" ] && [ ! -f "\$CONF" ]; then
    echo "bc250-apply: no config found — run bc250-detect first" >&2
    exit 1
fi
if [ -f "\$PENDING" ]; then
    mv "\$PENDING" "\$CONF"
    echo "bc250-apply: promoted overclock.pending -> overclock.conf"
fi
exec "\$VENV/bin/python" "\$REPO/bc250_apply.py" "\$CONF" "\$@"
WEOF
chmod +x "$BIN_DIR/bc250-apply"
rm -f /usr/bin/bc250-apply
ln -sf "$BIN_DIR/bc250-apply" /usr/bin/bc250-apply

cat > "$BIN_DIR/bc250-reset" << WEOF
#!/bin/bash
CONF="$CONF"
PENDING="$PENDING"

echo "bc250-reset: removing overclock.conf and overclock.pending..."
rm -f "\$CONF" "\$PENDING"
echo ""
echo "Done. Reboot now to let the BIOS restore true stock SMU settings:"
echo "  reboot"
WEOF
chmod +x "$BIN_DIR/bc250-reset"
rm -f /usr/bin/bc250-reset
ln -sf "$BIN_DIR/bc250-reset" /usr/bin/bc250-reset

echo "    ${C}OK${R}: bc250-detect → $BIN_DIR/bc250-detect"
echo "    ${C}OK${R}: bc250-apply  → $BIN_DIR/bc250-apply"
echo "    ${C}OK${R}: bc250-reset  → $BIN_DIR/bc250-reset"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo "${C}========================================${R}"
echo "${C} bc250-smu-oc — Batocera ready${R}"
echo "${C}========================================${R}"
echo "${C} Venv:${R}    $VENV_DIR"
echo "${C} Config:${R}  $CONF"
echo "${C} Logs:${R}    $INSTALL_DIR/smu-oc.log"
echo "${C}========================================${R}"
echo ""
echo "Commands:"
echo ""
echo "  ${C}bc250-detect${R}  --frequency MHz --vid mV [--temp degC] [--keep]"
echo "  ${C}bc250-apply${R}   --apply"
echo "  ${C}bc250-reset${R}   wipe overclock.conf + overclock.pending; reboot to restore BIOS stock"
echo ""
echo "   -f, --frequency   target boost clock in MHz  (valid: 3500-4500)"
echo "   -v, --vid         max CPU core voltage in mV (valid: 950-1325)"
echo "   -t, --temp        CPU+GPU temp limit in degC (default: 90)"
echo "   -k, --keep        keep overclock applied after detect finishes"
echo ""
echo "  Note: --config is baked in, no need to pass a path."
echo ""
echo "Quick start:"
echo ""
echo "  1. Detect stable overclock (writes overclock.pending, keeps OC for this session):"
echo "     bc250-detect --frequency 3500 --vid 1000 --keep"
echo ""
echo "  2. Review config:"
echo "     nano $CONF"
echo "       frequency:       3500-4500 MHz"
echo "       scale:           0 to -50  (0=stock VID curve, negative=undervolt)"
echo "       max_temperature: 0-100 degC (90 recommended)"
echo ""
echo "  3. Promote pending config and apply (no reboot needed):"
echo "     bc250-apply --apply"
echo ""
echo "  4. Wipe config and reboot to restore true BIOS stock:"
echo "     bc250-reset && reboot"
echo ""
echo "${Y}  !! WARNING: Read the upstream disclaimer before overclocking !!${R}"
echo "${Y}     Vid must NEVER exceed 1325 mV. Stress test after every change.${R}"
echo "${Y}     Raising frequency WITHOUT undervolting = uncapped Vid = brick risk.${R}"
echo "${Y}     https://github.com/bc250-collective/bc250_smu_oc${R}"
echo "${C}========================================${R}"