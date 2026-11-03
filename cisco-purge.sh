#!/bin/bash
#
# cisco-purge.sh
# Removes Cisco Secure Client / AnyConnect and all related modules
# (VPN, Umbrella, DART, EVM, NVM, Cloud Management, Socket Filter),
# their receipts, launchd jobs, preferences, logs and TCC (privacy)
# entries, so a Mac can be used for clean, repeatable installer tests.
#
# Webex and Jabber (also com.cisco.*) are deliberately left alone.
#
# Usage:
#   sudo ./cisco-purge.sh          # asks for confirmation
#   sudo ./cisco-purge.sh --yes    # no prompt
#
# Not removed by design:
#   - Mosyle configuration profiles (System Extension / content filter /
#     PPPC). Those are MDM-managed and should stay for re-testing.
#   - /Library/Receipts/InstallHistory.plist entries (installers don't
#     use it to decide what is installed).
#
# A reboot is recommended afterwards so any Cisco system extension
# that was deactivated is fully unloaded.

set -u
shopt -s nullglob

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo."
  exit 1
fi

if [[ "${1:-}" != "--yes" ]]; then
  echo "This removes ALL Cisco Secure Client / AnyConnect components from this Mac."
  read -r -p "Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || { echo "Aborted."; exit 1; }
fi

LOG="/var/tmp/cisco-purge-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "=== Cisco purge started $(date) ==="
echo "Log: $LOG"

# Skip Webex / Jabber, which share the com.cisco.* namespace
EXCLUDE_RE='webex|jabber|spark'

is_target() {
  # $1 = a bundle id, receipt id or file name
  [[ "$1" =~ [Cc]isco ]] && ! [[ "$1" =~ $EXCLUDE_RE ]]
}

CONSOLE_USER=$(stat -f %Su /dev/console)
if [[ "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  CONSOLE_USER=""
  CONSOLE_UID=""
  USER_HOME=""
  echo "No user logged in at the console; per-user cleanup will be skipped."
else
  CONSOLE_UID=$(id -u "$CONSOLE_USER")
  USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
  echo "Console user: $CONSOLE_USER ($CONSOLE_UID), home: $USER_HOME"
fi

# ---------------------------------------------------------------------------
# 1. Record bundle IDs before anything is deleted (needed for TCC reset)
# ---------------------------------------------------------------------------
echo
echo "--- 1. Collecting Cisco bundle IDs"
BUNDLE_IDS_FILE=$(mktemp)
find /Applications/Cisco /opt/cisco \
  \( -name "*.app" -o -name "*.systemextension" \) -type d 2>/dev/null |
while IFS= read -r bundle; do
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$bundle/Contents/Info.plist" 2>/dev/null
done >> "$BUNDLE_IDS_FILE"

# Known IDs, in case the bundles are already gone
cat >> "$BUNDLE_IDS_FILE" <<'EOF'
com.cisco.secureclient.gui
com.cisco.anyconnect.macos.acsock
com.cisco.anyconnect.macos.acsockext
com.cisco.secureclient.evm
com.cisco.secureclient.nvmagent
EOF
grep -E '^[A-Za-z0-9]+\.[A-Za-z0-9.-]+$' "$BUNDLE_IDS_FILE" | sort -u -o "$BUNDLE_IDS_FILE"
sed 's/^/    /' "$BUNDLE_IDS_FILE"

# ---------------------------------------------------------------------------
# 2. Reset privacy (TCC) permissions for the Cisco bundle IDs.
#    This must run BEFORE the apps are deleted: tccutil looks the bundle ID
#    up through Launch Services and fails (-10814) once the app is gone.
#    Grants pushed by an MDM PPPC profile are not stored here and stay.
# ---------------------------------------------------------------------------
echo
echo "--- 2. Resetting TCC permissions"
while IFS= read -r bid; do
  [[ -z "$bid" ]] && continue
  is_target "$bid" || continue
  if out=$(tccutil reset All "$bid" 2>&1); then
    echo "    reset $bid"
  else
    echo "    FAILED $bid: $out"
  fi
  if [[ -n "$CONSOLE_USER" ]]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
      tccutil reset All "$bid" > /dev/null 2>&1
  fi
done < "$BUNDLE_IDS_FILE"
rm -f "$BUNDLE_IDS_FILE"

# ---------------------------------------------------------------------------
# 3. Run Cisco's own uninstall scripts (they deactivate the system extension
#    and network filter properly). Modules first, core VPN next, Cloud
#    Management last.
# ---------------------------------------------------------------------------
echo
echo "--- 3. Running Cisco uninstall scripts"
run_uninstaller() {
  local script="$1"
  [[ -f "$script" ]] || return 0
  echo "    Running $script"
  /bin/bash "$script" < /dev/null
  echo "    -> exit $?"
}

ALL_SCRIPTS=$(find /opt/cisco -type f -name "*uninstall*.sh" 2>/dev/null)

# Pass 1: module uninstallers
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  if ! [[ "$s" =~ (vpn|secure_client_uninstall|anyconnect_uninstall|cm_uninstall) ]]; then
    run_uninstaller "$s"
  fi
done <<< "$ALL_SCRIPTS"

# Pass 2: core VPN / main uninstaller
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  if [[ "$s" =~ (vpn|secure_client_uninstall|anyconnect_uninstall) ]]; then
    run_uninstaller "$s"
  fi
done <<< "$ALL_SCRIPTS"

# Pass 3: Cloud Management
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  [[ "$s" =~ cm_uninstall ]] && run_uninstaller "$s"
done <<< "$ALL_SCRIPTS"

# ---------------------------------------------------------------------------
# 4. Stop and remove any leftover launchd jobs and processes
# ---------------------------------------------------------------------------
echo
echo "--- 4. Removing launchd jobs and stopping processes"
for plist in /Library/LaunchDaemons/*.plist; do
  name=$(basename "$plist")
  is_target "$name" || continue
  echo "    Daemon: $name"
  launchctl bootout system "$plist" 2>/dev/null
  rm -f "$plist"
done

for plist in /Library/LaunchAgents/*.plist; do
  name=$(basename "$plist")
  is_target "$name" || continue
  echo "    Agent: $name"
  [[ -n "$CONSOLE_UID" ]] && launchctl bootout "gui/$CONSOLE_UID" "$plist" 2>/dev/null
  rm -f "$plist"
done

pkill -9 -f "/opt/cisco/" 2>/dev/null
pkill -9 -f "/Applications/Cisco/" 2>/dev/null

# ---------------------------------------------------------------------------
# 5. Delete files and folders
# ---------------------------------------------------------------------------
echo
echo "--- 5. Deleting files"
PATHS=(
  /opt/cisco
  /Applications/Cisco
  "/Applications/Cisco Secure Client.app"
  /Library/Cisco
  "/Library/Application Support/Cisco"
  "/Library/Application Support/Cisco Secure Client"
  /Library/Logs/Cisco
  /var/log/secureclient
  # Wrapper staging folder and the Cisco preinstall's own logs
  /Library/CSCDeploy
  /private/tmp/csc-deploy
  /private/tmp/preinstall.log
  /private/tmp/preinstall.log.err
  /private/tmp/postinstall.log
  /private/tmp/postinstall.log.err
)

for item in /Library/Preferences/*.plist /Library/PrivilegedHelperTools/*; do
  is_target "$(basename "$item")" && PATHS+=("$item")
done

if [[ -n "$USER_HOME" ]]; then
  PATHS+=("$USER_HOME/.cisco" "$USER_HOME/.anyconnect")
  for item in \
    "$USER_HOME/Library/Preferences/"* \
    "$USER_HOME/Library/Application Support/"* \
    "$USER_HOME/Library/Caches/"* \
    "$USER_HOME/Library/HTTPStorages/"* \
    "$USER_HOME/Library/Saved Application State/"*; do
    is_target "$(basename "$item")" && PATHS+=("$item")
  done
fi

for p in "${PATHS[@]}"; do
  if [[ -e "$p" || -L "$p" ]]; then
    echo "    rm $p"
    rm -rf "$p"
  fi
done

# ---------------------------------------------------------------------------
# 6. Forget package receipts (this is what fixes stale-receipt problems)
# ---------------------------------------------------------------------------
echo
echo "--- 6. Forgetting package receipts"
pkgutil --pkgs | while IFS= read -r pkg; do
  if is_target "$pkg"; then
    echo "    forget $pkg"
    pkgutil --forget "$pkg" > /dev/null
  fi
done

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
echo
echo "--- 7. Verification"
LEFT_RECEIPTS=$(pkgutil --pkgs | while read -r p; do is_target "$p" && echo "$p"; done)
if [[ -n "$LEFT_RECEIPTS" ]]; then
  echo "    Receipts still present:"
  echo "$LEFT_RECEIPTS" | sed 's/^/      /'
else
  echo "    Receipts: none"
fi

for p in /opt/cisco /Applications/Cisco /Library/Cisco; do
  [[ -e "$p" ]] && echo "    Still exists: $p"
done

SYSEXT=$(systemextensionsctl list 2>/dev/null | grep -i cisco)
if [[ -n "$SYSEXT" ]]; then
  echo "    System extensions still listed (normally cleared by reboot):"
  echo "$SYSEXT" | sed 's/^/      /'
else
  echo "    System extensions: none"
fi

echo
echo "=== Done. Reboot before the next install test. ==="
