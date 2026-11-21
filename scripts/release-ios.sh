#!/bin/sh
# Archives ScrobbleKit for iPhone and uploads it to App Store Connect, where
# it appears in TestFlight once Apple has processed it.
#
# Needs an App Store Connect API key (Admin or App Manager) in ASC_KEY_PATH,
# ASC_KEY_ID and ASC_ISSUER_ID; the "Apple Distribution" certificate in the
# login keychain; an App Store provisioning profile for
# com.feruzurazaliev.scrobblekit named IOS_PROFILE (default "ScrobbleKit App
# Store") installed in ~/Library/Developer/Xcode/UserData/Provisioning
# Profiles; and an App Store Connect app record for the bundle ID. The API key
# has no cloud-signing permission, so signing is manual. Each upload of a
# version needs a new build number (CURRENT_PROJECT_VERSION).
#
# DESTINATION=export writes the .ipa to build/release/ios instead of uploading.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-"$ROOT/build/release"}
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the .p8 file}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
TEAM_ID=${TEAM_ID:-DT9JP293AM}
IOS_PROFILE=${IOS_PROFILE:-"ScrobbleKit App Store"}
DESTINATION=${DESTINATION:-upload}

# xcodebuild with the API key, so Xcode can create profiles and sign.
xcodebuild_auth() {
    xcodebuild "$@" -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

cd "$ROOT"
rm -rf "$OUT/ScrobbleKitiOS.xcarchive" "$OUT/ios"
mkdir -p "$OUT"

xcodebuild_auth archive -project Apps/ScrobbleKit.xcodeproj -scheme ScrobbleKitiOS -configuration Release \
    -destination generic/platform=iOS -archivePath "$OUT/ScrobbleKitiOS.xcarchive" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE"

cat > "$OUT/ExportOptions-ios.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DESTINATION</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.feruzurazaliev.scrobblekit</key><string>$IOS_PROFILE</string>
    </dict>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild_auth -exportArchive -archivePath "$OUT/ScrobbleKitiOS.xcarchive" -exportPath "$OUT/ios" \
    -exportOptionsPlist "$OUT/ExportOptions-ios.plist"
if [ "$DESTINATION" = upload ]; then
    echo "Uploaded. It shows in TestFlight after Apple processes it (usually 5 to 30 minutes)."
else
    echo "Exported to $OUT/ios"
fi
