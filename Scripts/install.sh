#!/bin/sh
# Runs as root (via the app's administrator prompt).
# Copies the helper out of the app bundle into a root-owned folder,
# so nothing the user can write is ever executed as root.
set -e

SRC="$1"
BASE="/Library/Application Support/Zapret"
LABEL="local.zapret.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p "$BASE/bin" "$BASE/data" "$BASE/lists-default" "$BASE/state" /Library/Logs/Zapret
cp -f "$SRC/zapret-helper" "$SRC/ciadpi" "$SRC/tun2socks" "$BASE/bin/"
cp -f "$SRC"/data/* "$BASE/data/"
cp -f "$SRC"/lists/* "$BASE/lists-default/"
cp -f "$SRC/uninstall.sh" "$BASE/"
chown -R root:wheel "$BASE"
chmod -R go-w "$BASE"
chmod 755 "$BASE"/bin/* "$BASE/uninstall.sh"
xattr -dr com.apple.quarantine "$BASE" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BASE/bin/zapret-helper</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/Library/Logs/Zapret/helper.log</string>
    <key>StandardOutPath</key><string>/Library/Logs/Zapret/helper.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
