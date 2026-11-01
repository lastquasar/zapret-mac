#!/bin/sh
# Runs as root. Stopping the helper makes it restore DNS and routes first.

BASE="/Library/Application Support/Zapret"
LABEL="local.zapret.helper"

launchctl bootout "system/$LABEL" 2>/dev/null
sleep 1

# Safety net in case the helper could not clean up after itself.
route -q -n delete -net 0.0.0.0/1 -interface utun225 2>/dev/null
route -q -n delete -net 128.0.0.0/1 -interface utun225 2>/dev/null
for ifc in $(ifconfig -l); do
    route -q -n delete -ifscope "$ifc" -net 0.0.0.0/1 2>/dev/null
    route -q -n delete -ifscope "$ifc" -net 128.0.0.0/1 2>/dev/null
done
pkill -9 -f "$BASE/bin/" 2>/dev/null
if [ -f "$BASE/state/dns-backup.json" ]; then
    networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while read -r svc; do
        if [ "$(networksetup -getdnsservers "$svc")" = "127.0.0.1" ]; then
            networksetup -setdnsservers "$svc" Empty
        fi
    done
fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" /var/run/zapret.sock
rm -rf "$BASE" /Library/Logs/Zapret
exit 0
