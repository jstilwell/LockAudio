#!/bin/bash
set -e

# Parse arguments
UPLOAD_TO_GITHUB=false
RELEASE_NOTES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --upload)
            UPLOAD_TO_GITHUB=true
            shift
            ;;
        --notes)
            RELEASE_NOTES="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--upload] [--notes \"Release notes\"]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="Mac Audio Input Locker"
PROJECT_FILE="Mac Audio Input Locker.xcodeproj"
SCHEME="Mac Audio Input Locker"
APP_NAME="Mac Audio Input Locker.app"
PLIST_PATH="Mac Audio Input Locker/Info.plist"

# Get Sparkle tools path
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)
if [ -z "$SPARKLE_BIN" ]; then
    echo -e "${RED}Error: Could not find Sparkle tools. Make sure the project has been built at least once.${NC}"
    exit 1
fi

SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"

# Get version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST_PATH")
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Could not read version from Info.plist${NC}"
    exit 1
fi

# Check if version tag already exists on GitHub
if command -v gh &> /dev/null && gh auth status &> /dev/null 2>&1; then
    if gh release view "v${VERSION}" --repo jstilwell/MacAudioInputLocker &> /dev/null; then
        echo -e "${RED}Error: Version ${VERSION} already exists on GitHub!${NC}"
        echo "Please update CFBundleShortVersionString in Info.plist to a new version."
        echo "Current releases: https://github.com/jstilwell/MacAudioInputLocker/releases"
        exit 1
    fi
fi

echo -e "${GREEN}Building ${PROJECT_NAME} version ${VERSION}${NC}"

# Create release directory and mark it as deletable by Xcode
RELEASE_DIR="release"
if [ -d "$RELEASE_DIR" ]; then
    rm -rf "$RELEASE_DIR"
fi
mkdir -p "$RELEASE_DIR"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$RELEASE_DIR"

# Clean and build Universal Binary (Intel + Apple Silicon)
echo -e "${YELLOW}Building Universal Binary for Intel and Apple Silicon...${NC}"
xcodebuild -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -arch x86_64 -arch arm64 \
    clean build \
    CONFIGURATION_BUILD_DIR="$(pwd)/$RELEASE_DIR" \
    ONLY_ACTIVE_ARCH=NO

if [ ! -d "$RELEASE_DIR/$APP_NAME" ]; then
    echo -e "${RED}Error: Build failed. App not found at $RELEASE_DIR/$APP_NAME${NC}"
    exit 1
fi

# Create DMG
DMG_NAME="MacAudioInputLocker-${VERSION}.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
echo -e "${YELLOW}Creating DMG with Applications folder symlink: ${DMG_NAME}${NC}"

# Create a temporary directory for DMG contents
DMG_TEMP="dmg_temp"
mkdir -p "$DMG_TEMP"
cp -R "$RELEASE_DIR/$APP_NAME" "$DMG_TEMP/"

# Create a symlink to /Applications
ln -s /Applications "$DMG_TEMP/Applications"

# Create the DMG in the release directory
hdiutil create -volname "$PROJECT_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up temp directory
rm -rf "$DMG_TEMP"

# Sign the update
echo -e "${YELLOW}Signing update...${NC}"
SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH")
if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}Error: Failed to sign update${NC}"
    exit 1
fi

# Extract signature value
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)

# Get file size
FILE_SIZE=$(stat -f%z "$DMG_PATH")

# Get current date in RFC 822 format
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

echo -e "${GREEN}Build complete!${NC}"
echo ""
echo -e "${YELLOW}Release Information:${NC}"
echo "  Version: $VERSION"
echo "  DMG: $DMG_NAME"
echo "  Size: $FILE_SIZE bytes"
echo "  Signature: $ED_SIGNATURE"
echo ""
echo -e "${YELLOW}Generating appcast.xml...${NC}"

# Generate appcast.xml
cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkleproject.org/xml/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mac Audio Input Locker</title>
    <link>https://stilwell.dev/updates/mac_audio_input_locker/appcast.xml</link>
    <description>Most recent updates to Mac Audio Input Locker</description>
    <language>en</language>

    <item>
      <title>Version ${VERSION}</title>
      <link>https://github.com/jstilwell/MacAudioInputLocker/releases</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <h2>What's New in Version ${VERSION}</h2>
        <ul>
          <li>Update this with release notes</li>
        </ul>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="https://github.com/jstilwell/MacAudioInputLocker/releases/download/v${VERSION}/${DMG_NAME}"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
      <sparkle:minimumSystemVersion>10.14</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

echo -e "${GREEN}appcast.xml generated!${NC}"
echo ""

# Upload to GitHub if requested
if [ "$UPLOAD_TO_GITHUB" = true ]; then
    echo -e "${YELLOW}Uploading to GitHub...${NC}"

    # Check if gh is installed
    if ! command -v gh &> /dev/null; then
        echo -e "${RED}Error: GitHub CLI (gh) is not installed.${NC}"
        echo "Install it with: brew install gh"
        exit 1
    fi

    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        echo -e "${RED}Error: Not authenticated with GitHub CLI.${NC}"
        echo "Run: gh auth login"
        exit 1
    fi

    # Collect release notes interactively
    echo ""
    echo -e "${YELLOW}Enter release notes (one feature per line, press Enter on empty line when done):${NC}"

    FEATURES=()
    while IFS= read -r line; do
        [ -z "$line" ] && break
        FEATURES+=("$line")
    done

    # Build appcast features (as <li> items)
    APPCAST_FEATURES=""
    for feature in "${FEATURES[@]}"; do
        APPCAST_FEATURES="${APPCAST_FEATURES}          <li>${feature}</li>
"
    done

    # If no features provided, use placeholder
    if [ -z "$APPCAST_FEATURES" ]; then
        APPCAST_FEATURES="          <li>Bug fixes and improvements</li>
"
    fi

    # Build GitHub release notes (as markdown list)
    GITHUB_NOTES="## What's New in Version ${VERSION}

"
    for feature in "${FEATURES[@]}"; do
        GITHUB_NOTES="${GITHUB_NOTES}- ${feature}
"
    done

    # If no features, use placeholder
    if [ ${#FEATURES[@]} -eq 0 ]; then
        GITHUB_NOTES="${GITHUB_NOTES}- Bug fixes and improvements"
    fi

    # Update appcast.xml with the collected features
    cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkleproject.org/xml/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mac Audio Input Locker</title>
    <link>https://stilwell.dev/updates/mac_audio_input_locker/appcast.xml</link>
    <description>Most recent updates to Mac Audio Input Locker</description>
    <language>en</language>

    <item>
      <title>Version ${VERSION}</title>
      <link>https://github.com/jstilwell/MacAudioInputLocker/releases</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <h2>What's New in Version ${VERSION}</h2>
        <ul>
${APPCAST_FEATURES}        </ul>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="https://github.com/jstilwell/MacAudioInputLocker/releases/download/v${VERSION}/${DMG_NAME}"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
      <sparkle:minimumSystemVersion>10.14</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

    echo -e "${GREEN}appcast.xml updated with release notes!${NC}"

    # Create the release
    echo ""
    echo "Creating release v${VERSION}..."
    gh release create "v${VERSION}" \
        "${DMG_PATH}" \
        --title "Version ${VERSION}" \
        --notes "$GITHUB_NOTES" \
        --repo jstilwell/MacAudioInputLocker

    echo -e "${GREEN}Release created successfully!${NC}"
    echo "View at: https://github.com/jstilwell/MacAudioInputLocker/releases/tag/v${VERSION}"
    echo ""
    echo -e "${YELLOW}Next step:${NC}"
    echo "  Upload appcast.xml to: https://stilwell.dev/updates/mac_audio_input_locker/appcast.xml"
else
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Edit appcast.xml to add release notes"
    echo "  2. Create GitHub release: https://github.com/jstilwell/MacAudioInputLocker/releases/new"
    echo "     - Tag: v${VERSION}"
    echo "     - Upload: ${RELEASE_DIR}/${DMG_NAME}"
    echo "     Or run: ./bin/build-release.sh --upload --notes \"Your release notes\""
    echo "  3. Upload appcast.xml to: https://stilwell.dev/updates/mac_audio_input_locker/appcast.xml"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
