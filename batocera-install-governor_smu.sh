#!/bin/bash
set -e

C=$'\033[96m'
Y=$'\033[93m'
R=$'\033[0m'

REPO="filippor/cyan-skillfish-governor"
INSTALL_DIR="/userdata/system/cyan-skillfish-governor"
BIN="$INSTALL_DIR/bin/cyan-skillfish-governor-smu"
SERVICE_NAME="cyan_skillfish_governor_smu"
SERVICE="/userdata/system/services/$SERVICE_NAME"

echo "${C}==> Killing any existing cyan-skillfish-governor instances...${R}"
pkill -f cyan-skillfish-governor-smu 2>/dev/null && echo "    Killed existing instances." || echo "    None running."
rm -f /var/run/cyan_skillfish_governor_smu.pid

echo "${C}==> Fetching latest release info from GitHub...${R}"
RELEASE_JSON=$(curl -sf "https://api.github.com/repos/${REPO}/releases/latest")
VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url"' | grep 'x86_64-linux.tar.gz"' | grep -v sha256 | head -1 | cut -d'"' -f4)
SHA256_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url"' | grep 'x86_64-linux.tar.gz.sha256"' | head -1 | cut -d'"' -f4)

if [ -z "$VERSION" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "${Y}ERROR: Could not fetch release info from GitHub. Check your internet connection.${R}" >&2
    exit 1
fi

echo "    Latest version: $VERSION"
echo "    URL: $DOWNLOAD_URL"

echo "${C}==> Downloading $VERSION...${R}"
curl -L -o /tmp/governor.tar.gz "$DOWNLOAD_URL"

if [ -n "$SHA256_URL" ]; then
    echo "${C}==> Verifying checksum...${R}"
    curl -sf -L "$SHA256_URL" -o /tmp/governor.tar.gz.sha256
    EXPECTED=$(awk '{print $1}' /tmp/governor.tar.gz.sha256)
    echo "${EXPECTED}  /tmp/governor.tar.gz" | sha256sum -c -
    rm -f /tmp/governor.tar.gz.sha256
else
    echo "${Y}    WARNING: No sha256 file found, skipping checksum verification.${R}"
fi

echo "${C}==> Extracting...${R}"
mkdir -p /tmp/governor-extract
tar -xf /tmp/governor.tar.gz -C /tmp/governor-extract

echo "${C}==> Installing binary...${R}"
mkdir -p "$INSTALL_DIR/bin"
find /tmp/governor-extract -name "cyan-skillfish-governor-smu" -type f \
  -exec cp {} "$BIN" \;
chmod +x "$BIN"

echo "${C}==> Downloading default config.toml from upstream...${R}"
CONFIG_URL="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/refs/heads/smu/default-config.toml"
curl -fsSL "$CONFIG_URL" -o "$INSTALL_DIR/config.toml"
echo "    ${C}OK${R}: $INSTALL_DIR/config.toml"


echo "${C}==> Installing service script...${R}"
cat > "$SERVICE" << 'SVCEOF'
#!/bin/bash
BINARY="/userdata/system/cyan-skillfish-governor/bin/cyan-skillfish-governor-smu"
CONFIG="/userdata/system/cyan-skillfish-governor/config.toml"
PIDFILE="/var/run/cyan_skillfish_governor_smu.pid"
LOGFILE="/userdata/system/cyan-skillfish-governor/governor.log"

start() {
    if [ ! -x "$BINARY" ]; then
        echo "cyan-skillfish-governor: binary not found" >&2; exit 1
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "cyan-skillfish-governor: already running (PID $(cat "$PIDFILE"))"; return 0
    fi
    pkill -f cyan-skillfish-governor-smu 2>/dev/null || true
    rm -f "$PIDFILE"
    if [ -f "$CONFIG" ]; then
        "$BINARY" "$CONFIG" >> "$LOGFILE" 2>&1 &
    else
        "$BINARY" >> "$LOGFILE" 2>&1 &
    fi
    echo $! > "$PIDFILE"
    echo "cyan-skillfish-governor: started (PID $!)"
}

stop() {
    pkill -f cyan-skillfish-governor-smu 2>/dev/null && echo "cyan-skillfish-governor: stopped" || echo "cyan-skillfish-governor: not running"
    rm -f "$PIDFILE"
}

case "$1" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "Usage: $0 {start|stop}"; exit 1 ;;
esac
SVCEOF
chmod +x "$SERVICE"

if [ -f "/userdata/system/services/cyan-skillfish-governor" ]; then
    echo "${C}==> Removing old service (invalid name)...${R}"
    rm -f "/userdata/system/services/cyan-skillfish-governor"
fi

echo "${C}==> Enabling service...${R}"
batocera-services enable "$SERVICE_NAME"

echo "${C}==> Cleaning up...${R}"
rm -rf /tmp/governor.tar.gz /tmp/governor-extract

echo ""
echo "${C}==> Starting governor...${R}"
batocera-services start "$SERVICE_NAME"

sleep 2

echo ""
PID=$(cat /var/run/cyan_skillfish_governor_smu.pid 2>/dev/null || pgrep -f cyan-skillfish-governor-smu)

# Find the APU sclk file dynamically (works with any cardX)
SCLK_FILE=""
for card in /sys/class/drm/card*/device/pp_dpm_sclk; do
    [ -f "$card" ] && SCLK_FILE="$card" && break
done

CURRENT_FREQ="unavailable"
[ -n "$SCLK_FILE" ] && CURRENT_FREQ=$(grep '\*' "$SCLK_FILE" | awk '{print $2}')

echo "${C}========================================${R}"
echo "${C} cyan-skillfish-governor-smu $VERSION${R}"
echo "${C}========================================${R}"
echo "${C} Status:${R}  Running (PID $PID)"
echo "${C} Current APU Frequency:${R} ${Y}$CURRENT_FREQ${R}"
echo "${C} Config:${R}  $INSTALL_DIR/config.toml"
echo "${C} Logs:${R}    $INSTALL_DIR/governor.log"
echo "${C} Live:${R}    watch -n1 cat $SCLK_FILE"
echo "${C} Service:${R} batocera-services restart cyan_skillfish_governor_smu"
echo "${C}========================================${R}"

