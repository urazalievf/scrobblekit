#!/bin/sh
# Builds ScrobbleKit for Mac for direct download: signs it with Developer ID,
# notarizes and staples it, and zips it for a GitHub release.
#
# Needs an App Store Connect API key (Admin or App Manager) in ASC_KEY_PATH,
# ASC_KEY_ID and ASC_ISSUER_ID; the "Developer ID Application" certificate in
# the login keychain; and a Developer ID provisioning profile for
# com.feruzurazaliev.scrobblekit.mac named MAC_PROFILE (default "ScrobbleKit
# Mac Developer ID") installed in ~/Library/Developer/Xcode/UserData/
# Provisioning Profiles. The app's Keychain access group needs a profile even
# outside the App Store. The archive step signs for development, so this Mac
# must be a registered device of the team. Last.fm is included only when
# .env has a key (see README: from 1 December 2026 the key's owner needs
# Last.fm Pro).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-"$ROOT/build/release"}
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the .p8 file}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
TEAM_ID=${TEAM_ID:-DT9JP293AM}
MAC_PROFILE=${MAC_PROFILE:-"ScrobbleKit Mac Developer ID"}

# xcodebuild with the API key, so Xcode can create profiles and sign.
xcodebuild_auth() {
    xcodebuild "$@" -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

cd "$ROOT"
VERSION=$(xcodebuild -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitMac -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
rm -rf "$OUT/mac" "$OUT/ScrobbleKitMac.xcarchive"
mkdir -p "$OUT"

xcodebuild_auth archive -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitMac -configuration Release \
    -destination generic/platform=macOS -archivePath "$OUT/ScrobbleKitMac.xcarchive"

cat > "$OUT/ExportOptions-mac.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.feruzurazaliev.scrobblekit.mac</key><string>$MAC_PROFILE</string>
    </dict>
</dict>
</plist>
PLIST

xcodebuild_auth -exportArchive -archivePath "$OUT/ScrobbleKitMac.xcarchive" -exportPath "$OUT/mac" \
    -exportOptionsPlist "$OUT/ExportOptions-mac.plist"

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
