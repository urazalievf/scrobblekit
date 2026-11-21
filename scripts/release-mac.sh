#!/bin/sh
# Builds ScrobbleKit for Mac for direct download: signs it with Developer ID,
# notarizes and staples it, and zips it for a GitHub release.
#
# Needs an App Store Connect API key (Admin or App Manager) in ASC_KEY_PATH,
# ASC_KEY_ID and ASC_ISSUER_ID, and the "Developer ID Application" certificate
# in the login keychain. Last.fm is included only when .env has a key (see
# README: from 1 December 2026 the key's owner needs Last.fm Pro).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-"$ROOT/build/release"}
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the .p8 file}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
TEAM_ID=${TEAM_ID:-DT9JP293AM}
AUTH="-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"

cd "$ROOT"
VERSION=$(xcodebuild -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitMac -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
rm -rf "$OUT/mac" "$OUT/ScrobbleKitMac.xcarchive"
mkdir -p "$OUT"

# shellcheck disable=SC2086
xcodebuild archive -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitMac -configuration Release \
    -destination generic/platform=macOS -archivePath "$OUT/ScrobbleKitMac.xcarchive" $AUTH

cat > "$OUT/ExportOptions-mac.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$OUT/ScrobbleKitMac.xcarchive" -exportPath "$OUT/mac" \
    -exportOptionsPlist "$OUT/ExportOptions-mac.plist" $AUTH

APP="$OUT/mac/ScrobbleKit.app"
ZIP="$OUT/ScrobbleKit-mac-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Ready: $ZIP"
