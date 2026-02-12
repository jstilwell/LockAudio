#!/bin/bash
set -e

# Load .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi

source "$ENV_FILE"

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

aws s3 cp appcast.xml "s3://${R2_BUCKET}/${R2_APPCAST_PATH}" \
    --endpoint-url "$R2_ENDPOINT" \
    --profile r2 \
    --content-type "application/xml"

echo "Uploaded appcast.xml to ${APPCAST_BASE_URL}/${R2_APPCAST_PATH}"
