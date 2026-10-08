#!/bin/sh
# Xcode build phase: copies LASTFM_API_KEY and LASTFM_SHARED_SECRET from the
# repository's .env into the built app's Info.plist. The values end up inside
# the built app (as with any Last.fm client) but never in the repository.
set -eu

ENV_FILE="${SRCROOT}/../.env"
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

read_var() {
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r' | sed -e 's/^"//' -e 's/"$//'
}

KEY=""
SECRET=""
if [ -f "$ENV_FILE" ]; then
    KEY=$(read_var LASTFM_API_KEY)
    SECRET=$(read_var LASTFM_SHARED_SECRET)
fi

if [ -z "$KEY" ] || [ -z "$SECRET" ]; then
    echo "warning: LASTFM_API_KEY or LASTFM_SHARED_SECRET is missing from .env; Last.fm is disabled in this build."
fi

plutil -replace LastFMAPIKey -string "$KEY" "$PLIST"
plutil -replace LastFMSharedSecret -string "$SECRET" "$PLIST"
