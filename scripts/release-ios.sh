#!/bin/sh
# Archives ScrobbleKit for iPhone and uploads it to App Store Connect, where
# it appears in TestFlight once Apple has processed it.
#
# Needs an App Store Connect API key (Admin or App Manager) in ASC_KEY_PATH,
# ASC_KEY_ID and ASC_ISSUER_ID, and an App Store Connect app record for
# com.feruzurazaliev.scrobblekit. Signing is cloud-managed through the key,
# so no distribution certificate has to be on this Mac. Each upload of a
# version needs a new build number (CURRENT_PROJECT_VERSION).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-"$ROOT/build/release"}
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the .p8 file}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
TEAM_ID=${TEAM_ID:-DT9JP293AM}

# xcodebuild with the API key, so Xcode can create profiles and sign.
xcodebuild_auth() {
    xcodebuild "$@" -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

cd "$ROOT"
rm -rf "$OUT/ScrobbleKitiOS.xcarchive" "$OUT/ios"
mkdir -p "$OUT"

xcodebuild_auth archive -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitiOS -configuration Release \
    -destination generic/platform=iOS -archivePath "$OUT/ScrobbleKitiOS.xcarchive"

cat > "$OUT/ExportOptions-ios.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild_auth -exportArchive -archivePath "$OUT/ScrobbleKitiOS.xcarchive" -exportPath "$OUT/ios" \
    -exportOptionsPlist "$OUT/ExportOptions-ios.plist"
echo "Uploaded. It shows in TestFlight after Apple processes it (usually 5 to 30 minutes)."
