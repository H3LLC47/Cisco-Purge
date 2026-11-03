# cisco-purge

A bash script that completely removes Cisco Secure Client (formerly AnyConnect) from a Mac, so the Mac behaves as if Cisco was never installed.

It's meant for admins testing MDM deployments of Secure Client who need a truly clean Mac between install attempts, and for fixing half-broken installs.

Not affiliated with or endorsed by Cisco. Provided as-is, without warranty. Test on a non-production Mac first.

## Why this exists

Cisco's own uninstallers leave enough behind that the next install doesn't behave like a first install. Things this script fixes:

- **The Secure Client app doesn't reinstall.** If the app bundle is gone but the `com.cisco.pkg.secureclient.gui` package receipt remains, the core VPN installer logs `UI module not selected: existing version is same or newer` and skips the GUI. Everything else installs, but there's no app.
- **Old Socket Filter extension versions get stuck.** Leftover `com.cisco.anyconnect.macos.acsockext` versions can leave the network extension asking for approval repeatedly.
- **Privacy permissions survive the uninstall.** Earlier Full Disk Access, Apple Events and Endpoint Security decisions stay in the TCC database, so later test installs don't show the prompts a real first install would.

## What it removes

- All Secure Client modules: VPN, Umbrella, DART, Network Visibility Module (NVM), Endpoint Visibility Module (EVM), Cloud Management, Socket Filter
- `/opt/cisco`, `/Applications/Cisco`, `/Library/Cisco`
- Cisco launch daemons and agents, and running Cisco processes
- Cisco logs, `/var/log/secureclient`, and the cloud-management bootstrap's `/tmp` files
- Cisco preference and cache files, system-wide and for the logged-in user
- Every Cisco package receipt (`pkgutil --forget`)
- Privacy (TCC) permissions granted to Cisco apps

## What it leaves alone

- **Webex and Jabber**, which also use `com.cisco.*` identifiers
- **MDM configuration profiles** (System Extensions, Web Content Filter, Managed Login Items, Privacy/PPPC), so you can re-test the same deployment
- Permissions granted by an MDM profile (those are stored separately from user decisions)
- `/Library/Receipts/InstallHistory.plist`

## Usage

Download `cisco-purge.sh`, then make it executable:

```
chmod +x cisco-purge.sh
```

If you downloaded it through a browser, macOS may quarantine it. Clear that with:

```
xattr -d com.apple.quarantine cisco-purge.sh
```

Run it:

```
sudo ./cisco-purge.sh          # asks you to type YES first
sudo ./cisco-purge.sh --yes    # no prompt, for repeated test runs
./cisco-purge.sh --help
```

If your deployment uses its own wrapper package with a staging folder, add it so it's cleaned up too:

```
sudo EXTRA_PATHS="/Library/MyStaging:/private/tmp/mywrapper" ./cisco-purge.sh --yes
```

**Reboot afterwards.** The Socket Filter extension is marked `terminated waiting to uninstall on reboot` and only fully unloads after a restart.

Each run is logged to `/var/tmp/cisco-purge-<date-time>.log`.

### What a clean run looks like

```
--- 2. Resetting TCC permissions
    reset com.cisco.secureclient.evm
    reset com.cisco.secureclient.vpn.service
    ...
--- 7. Verification
    Receipts: none
    System extensions still listed (normally cleared by reboot):
      ... com.cisco.anyconnect.macos.acsockext ... [terminated waiting to uninstall on reboot]

=== Done. Reboot before the next install test. ===
```

Any `FAILED` line in step 2 means that app's permissions weren't cleared.

### Confirm after the reboot

```
pkgutil --pkgs | grep -i cisco
systemextensionsctl list | grep -i cisco
ls /Applications/Cisco /opt/cisco
```

Expect no output from the first two (apart from any Webex/`Spark` entries) and "No such file or directory" from the third.

## Privacy permission gotchas

These cost me the most time, so they're worth knowing:

- **Reset permissions before deleting the apps.** `tccutil reset All <bundle id>` looks the app up through Launch Services. Once the app is gone it fails with `No such bundle identifier ... (OSStatus error -10814)`. The script resets permissions first for this reason. If the apps are already deleted, reinstall Secure Client, then run `sudo tccutil reset All com.cisco.secureclient.vpn.service` (and `com.cisco.secureclient.evm`).
- **macOS 27 makes the TCC database read-only.** You can still read `/Library/Application Support/com.apple.TCC/TCC.db` with `sqlite3`, but `DELETE` fails with a read-only error. Use `tccutil`.
- **Denied Endpoint Security rows are normal.** With an MDM privacy profile granting Full Disk Access, the TCC database still shows `kTCCServiceEndpointSecurityClient` rows with `auth_value 0` / `auth_reason 4` for `com.cisco.secureclient.vpn.service` and `com.cisco.secureclient.evm`. The MDM grant overrides them; NVM and EVM run normally.
- **System Settings can show Full Disk Access as off when it's granted.** Entries marked "This setting has been configured by a profile" may show the switch off. Check the real state instead:

```
sudo plutil -p "/Library/Application Support/com.apple.TCC/MDMOverrides.plist" | grep -iA12 "secureclient"
pgrep -lf "acnvmagent|csc_evm"
```

If the MDM grants show `Allowed => true` and the processes are running, permissions are working.

## MDM profiles for a prompt-free Secure Client install

Not part of the script, but these are what it took to get a Secure Client install (VPN, Umbrella, NVM, EVM, Cloud Management) with no user prompts. Cisco Team ID for everything: `DE8Y96K9QP`.

**Managed Login Items** (`com.apple.servicemanagement`)
- Rule: Team Identifier `DE8Y96K9QP`

**System Extensions** (`com.apple.system-extension-policy`)
- Allowed Team ID `DE8Y96K9QP` (or bundle ID `com.cisco.anyconnect.macos.acsockext`, type NetworkExtension)

**Web Content Filter** (`com.apple.webcontent-filter`)

| Key | Value |
| --- | --- |
| FilterType | Plugin |
| PluginBundleID | `com.cisco.anyconnect.macos.acsock` |
| FilterSockets | true |
| FilterPackets | false |
| FilterGrade | firewall |
| FilterDataProviderBundleIdentifier | `com.cisco.anyconnect.macos.acsockext` |
| FilterDataProviderDesignatedRequirement | see below |

```
anchor apple generic and identifier "com.cisco.anyconnect.macos.acsockext" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = DE8Y96K9QP)
```

**Privacy / PPPC** (`com.apple.TCC.configuration-profile-policy`)

| Bundle ID | Services | Static Code |
| --- | --- | --- |
| `com.cisco.secureclient.vpn.service` | SystemPolicyAllFiles: Allow; AppleEvents → `com.apple.systemevents`: Allow | true |
| `com.cisco.secureclient.evm` | SystemPolicyAllFiles: Allow | true |

Get the code requirements from an installed Mac rather than copying them:

```
codesign -dr - "/opt/cisco/secureclient/bin/Cisco Secure Client - AnyConnect VPN Service.app"
codesign -dr - "/opt/cisco/secureclient/evm/bin/Cisco Secure Client - Endpoint Visibility Module.app"
codesign -dr - "/System/Library/CoreServices/System Events.app"
```

Use the text after `designated =>`. The System Events receiver requirement is `identifier "com.apple.systemevents" and anchor apple`.

**Notifications** (optional, stops the notification permission prompt)
- `com.cisco.secureclient.gui`, `com.cisco.secureclient.vpn.service`, `com.cisco.secureclient.vpn.notification`

## References

- [Cisco Secure Client 5.1 Admin Guide: macOS 11 (and later) changes](https://www.cisco.com/c/en/us/td/docs/security/vpn_client/anyconnect/Cisco-Secure-Client-5/admin/guide/b-cisco-secure-client-admin-guide-5-1/macos11-on-ac.html)
- [Cisco: Provide Full Disk Access for macOS](https://www.cisco.com/c/en/us/td/docs/security/vpn_client/anyconnect/Cisco-Secure-Client-5/admin/guide/cisco-secure-client-admin-guide-new/nvm-intro/provide-full-disk-access-for-macos.html)
- [Cisco XDR: Deployment Management (EVM / NVM Full Disk Access)](https://docs.xdr.security.cisco.com/Content/Client-Management/deployment-management.htm)

## License

MIT. See [LICENSE](LICENSE).
