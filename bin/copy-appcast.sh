#!/bin/bash
set -e

# Load .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# See build-release.sh: pre-set variables win (op run --env-file=.env -- ...),
# otherwise source a regular .env.
if [ -z "$R2_ACCOUNT_ID" ] && [ -e "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi
for var in R2_ACCOUNT_ID R2_BUCKET R2_APPCAST_PATH APPCAST_BASE_URL; do
    if [ -z "${!var}" ] || [ "${!var}" = "your_account_id_here" ]; then
        echo "Error: $var is not set. Create a regular .env (cp .env.example .env) or run:"
        echo "  op run --env-file=.env -- $0"
        exit 1
    fi
done


# The app requires a signed feed (SURequireSignedFeed), so refuse to publish
# an appcast that wasn't signed by build-release.sh or was edited afterwards.
cd "$PROJECT_DIR"
BUILD_PRODUCTS_DIR=$(xcodebuild -project LockAudio.xcodeproj -scheme LockAudio -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILD_DIR = /{print $2; exit}')
SIGN_UPDATE="$(dirname "$(dirname "$BUILD_PRODUCTS_DIR")")/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if ! "$SIGN_UPDATE" --verify appcast.xml; then
    echo "Error: appcast.xml is not signed (or was modified after signing). Re-run ./bin/build-release.sh."
    exit 1
fi

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

aws s3 cp appcast.xml "s3://${R2_BUCKET}/${R2_APPCAST_PATH}" \
    --endpoint-url "$R2_ENDPOINT" \
    --profile r2 \
    --content-type "application/xml"

echo "Uploaded appcast.xml to ${APPCAST_BASE_URL}/${R2_APPCAST_PATH}"
