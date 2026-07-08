#!/bin/bash
# batocera-install-sensors.sh
# Installs lm-sensors on Batocera persistently via a batocera-services entry.
# No custom.sh usage.

set -e

URL="https://github.com/tmghd272/bc250-batocera-tools/raw/main/misc/sensors.tar.gz"
INSTALL_DIR="/userdata/system/sensors"
SERVICE_DIR="/userdata/system/services"
SERVICE_NAME="sensors"
LIBDIR="/lib"

mkdir -p "$INSTALL_DIR"
curl -L "$URL" -o /tmp/sensors.tar.gz

# tarball has a sensors-pkg/ wrapper folder, extract to temp then
# pull the wrapper's contents up into INSTALL_DIR
TMP_EXTRACT="/tmp/sensors-extract"
rm -rf "$TMP_EXTRACT"
mkdir -p "$TMP_EXTRACT"
tar -xzf /tmp/sensors.tar.gz -C "$TMP_EXTRACT"

cp -r "$TMP_EXTRACT"/sensors-pkg/* "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR/bin/sensors"

rm -rf "$TMP_EXTRACT" /tmp/sensors.tar.gz

mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_DIR/$SERVICE_NAME" << EOF
#!/bin/bash
INSTALL_DIR="$INSTALL_DIR"
LIBDIR="$LIBDIR"

case "\$1" in
  start)
    ln -sf "\$INSTALL_DIR/bin/sensors" /usr/bin/sensors
    ln -sf "\$INSTALL_DIR/lib/libsensors.so.5" "\$LIBDIR/libsensors.so.5"
    ;;
  stop)
    rm -f /usr/bin/sensors
    rm -f "\$LIBDIR/libsensors.so.5"
    ;;
  *)
    echo "usage: \$0 {start|stop}"
    exit 1
    ;;
esac
EOF

chmod +x "$SERVICE_DIR/$SERVICE_NAME"
batocera-services enable "$SERVICE_NAME"
batocera-services start "$SERVICE_NAME"

echo "Installed. Test with: sensors"
