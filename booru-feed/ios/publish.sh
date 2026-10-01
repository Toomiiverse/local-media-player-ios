#!/bin/bash
set -euo pipefail
umask 077
for name in APPLE_TEAM_ID IOS_BUNDLE_ID IOS_CERTIFICATE_BASE64 IOS_CERTIFICATE_PASSWORD IOS_PROFILE_BASE64 ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY; do
  if [[ -z "${!name:-}" ]]; then echo "Missing secure publishing setting: $name"; exit 1; fi
done
[[ "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo 'Invalid API key identifier'; exit 1; }
export KEYCHAIN_PATH="$RUNNER_TEMP/ios-player.keychain-db"
export KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
export SIGNING_DIR="$RUNNER_TEMP/ios-player-signing"
mkdir -p "$SIGNING_DIR" "$HOME/.appstoreconnect/private_keys" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  rm -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  if [[ -n "${PROFILE_UUID:-}" ]]; then rm -f "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"; fi
  rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['SIGNING_DIR'])
for var, name in [('IOS_CERTIFICATE_BASE64', 'certificate.p12'), ('IOS_PROFILE_BASE64', 'profile.mobileprovision')]:
    (root / name).write_bytes(base64.b64decode(os.environ[var], validate=True))
key_id = os.environ['ASC_KEY_ID']
assert key_id.isalnum(), 'Invalid API key identifier'
(Path.home() / '.appstoreconnect' / 'private_keys' / f'AuthKey_{key_id}.p8').write_text(os.environ['ASC_PRIVATE_KEY'])
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$SIGNING_DIR/certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$SIGNING_DIR/profile.mobileprovision" > "$SIGNING_DIR/profile.plist"
export PROFILE_UUID
PROFILE_UUID=$(python3 - <<'PY'
import datetime, os, plistlib, uuid
from pathlib import Path
p = plistlib.loads((Path(os.environ['SIGNING_DIR']) / 'profile.plist').read_bytes())
assert p['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile'
assert p['TeamIdentifier'][0] == os.environ['APPLE_TEAM_ID'], 'Profile team mismatch'
assert p['Entitlements']['application-identifier'] == p['ApplicationIdentifierPrefix'][0] + '.' + os.environ['IOS_BUNDLE_ID'], 'Profile app mismatch'
assert not p.get('ProvisionedDevices') and not p.get('ProvisionsAllDevices'), 'Use an App Store distribution profile'
assert not p['Entitlements'].get('get-task-allow', False), 'Use a distribution profile'
print(str(uuid.UUID(p['UUID'])).upper())
PY
)
cp "$SIGNING_DIR/profile.mobileprovision" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
python3 prepare.py
pod install
xcodebuild -workspace LocalMediaPlayer.xcworkspace -scheme LocalMediaPlayer -configuration Release -destination 'generic/platform=iOS' -archivePath build/LocalMediaPlayer.xcarchive CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}" archive > "$RUNNER_TEMP/ios-archive.log" 2>&1 || { tail -80 "$RUNNER_TEMP/ios-archive.log"; exit 1; }
python3 - <<'PY'
import os, plistlib
from pathlib import Path
options = dict(method='app-store-connect', destination='export', signingStyle='manual', teamID=os.environ['APPLE_TEAM_ID'], signingCertificate='Apple Distribution', provisioningProfiles={os.environ['IOS_BUNDLE_ID']: os.environ['PROFILE_UUID']}, testFlightInternalTestingOnly=True, uploadSymbols=True, manageAppVersionAndBuildNumber=False)
Path('build/ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -exportArchive -archivePath build/LocalMediaPlayer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export > "$RUNNER_TEMP/ios-export.log" 2>&1 || { tail -80 "$RUNNER_TEMP/ios-export.log"; exit 1; }
xcrun altool --validate-app -f build/export/LocalMediaPlayer.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f build/export/LocalMediaPlayer.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo 'Uploaded for Apple processing. Add the processed build to your internal TestFlight group in App Store Connect.'
