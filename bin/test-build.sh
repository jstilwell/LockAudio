#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_NAME="Mac Audio Input Locker"
PROJECT_FILE="Mac Audio Input Locker.xcodeproj"
SCHEME="Mac Audio Input Locker"
APP_NAME="Mac Audio Input Locker.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo -e "${YELLOW}Stopping any running instance...${NC}"
pkill -x "$PROJECT_NAME" 2>/dev/null || true
sleep 1

echo -e "${YELLOW}Building Debug (arm64)...${NC}"
BUILD_DIR=$(mktemp -d)
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -arch arm64 \
    build > "$BUILD_DIR/build.log" 2>&1 || {
        echo -e "${RED}Build failed. Last 40 lines:${NC}"
        tail -40 "$BUILD_DIR/build.log"
        exit 1
    }

APP_PATH="$BUILD_DIR/Build/Products/Debug/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Build succeeded but app not found at $APP_PATH${NC}"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
echo -e "${GREEN}Built version $VERSION${NC}"

echo -e "${YELLOW}Launching...${NC}"
open "$APP_PATH"

echo
echo -e "${GREEN}Running.${NC} Watch the menu bar for the AirPods icon."
echo
echo "Live logs (Ctrl+C to stop tailing — the app keeps running):"
echo "---"
log stream --predicate 'process == "Mac Audio Input Locker"' --level debug
