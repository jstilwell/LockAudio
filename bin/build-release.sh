#!/bin/bash
set -e

# Parse arguments
UPLOAD_TO_GITHUB=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --upload)
            UPLOAD_TO_GITHUB=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--upload]"
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

# Load .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo "Copy .env.example to .env and fill in your values:"
    echo "  cp .env.example .env"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required .env variables
if [ -z "$R2_ACCOUNT_ID" ] || [ "$R2_ACCOUNT_ID" = "your_account_id_here" ]; then
    echo -e "${RED}Error: R2_ACCOUNT_ID is not set in .env${NC}"
    exit 1
fi

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
APPCAST_PUBLIC_URL="${APPCAST_BASE_URL}/${R2_APPCAST_PATH}"

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

# Parse release notes from CHANGELOG.md
CHANGELOG_FILE="CHANGELOG.md"
if [ ! -f "$CHANGELOG_FILE" ]; then
    echo -e "${RED}Error: CHANGELOG.md not found${NC}"
    echo "Create a CHANGELOG.md with an entry for version ${VERSION} before building."
    exit 1
fi

# Extract the section for this version (everything between ## VERSION and the next ## or EOF)
CHANGELOG_SECTION=$(sed -n "/^## ${VERSION} /,/^## /{/^## ${VERSION} /d;/^## /d;p;}" "$CHANGELOG_FILE")

if [ -z "$CHANGELOG_SECTION" ]; then
    echo -e "${RED}Error: No CHANGELOG.md entry found for version ${VERSION}${NC}"
    echo "Add an entry like this to CHANGELOG.md before building:"
    echo ""
    echo "  ## ${VERSION} - $(date +%m-%d-%Y)"
    echo ""
    echo "  ### Changed"
    echo "  - Your change description here"
    exit 1
fi

# Strip leading/trailing blank lines
CHANGELOG_SECTION=$(echo "$CHANGELOG_SECTION" | awk 'NF{found=1} found' | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--)if(lines[i]~/[^ \t]/){last=i;break} for(i=1;i<=last;i++)print lines[i]}')

echo -e "${GREEN}Found CHANGELOG.md entry for version ${VERSION}${NC}"

# Build GitHub release notes (markdown, used for gh release)
GITHUB_NOTES="## What's New in Version ${VERSION}

${CHANGELOG_SECTION}"

# Build appcast features (convert markdown bullets to HTML <li> items)
APPCAST_FEATURES=""
while IFS= read -r line; do
    # Match lines starting with "- " (changelog bullet points)
    if [[ "$line" == -\ * ]]; then
        APPCAST_FEATURES="${APPCAST_FEATURES}          <li>${line#- }</li>
"
    fi
done <<< "$CHANGELOG_SECTION"

if [ -z "$APPCAST_FEATURES" ]; then
    APPCAST_FEATURES="          <li>Bug fixes and improvements</li>
"
fi

# Ensure CFBundleVersion matches CFBundleShortVersionString
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST_PATH")
if [ "$BUILD_VERSION" != "$VERSION" ]; then
    echo -e "${YELLOW}Syncing CFBundleVersion ($BUILD_VERSION) to match CFBundleShortVersionString ($VERSION)${NC}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST_PATH"
fi

# Ensure SUFeedURL matches .env configuration
CURRENT_FEED_URL=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$PLIST_PATH")
if [ "$CURRENT_FEED_URL" != "$APPCAST_PUBLIC_URL" ]; then
    echo -e "${YELLOW}Updating SUFeedURL in Info.plist to match .env${NC}"
    echo "  From: $CURRENT_FEED_URL"
    echo "  To:   $APPCAST_PUBLIC_URL"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_PUBLIC_URL" "$PLIST_PATH"
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

# Copy app
cp -R "$RELEASE_DIR/$APP_NAME" "$DMG_TEMP/"

# Create a symlink to /Applications with a space prefix to sort after the app name
ln -s /Applications "$DMG_TEMP/ Applications"

# Create the DMG in the release directory
hdiutil create -volname "$PROJECT_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up temp directory
rm -rf "$DMG_TEMP"

# Notarize the DMG
echo -e "${YELLOW}Submitting DMG for notarization...${NC}"

# Submit for notarization (don't wait)
SUBMISSION_ID=$(xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "notarytool-profile" \
    --output-format json 2>&1 | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$SUBMISSION_ID" ]; then
    echo -e "${RED}Error: Failed to submit for notarization${NC}"
    echo "You can manually notarize later with:"
    echo "  xcrun notarytool submit \"$DMG_PATH\" --keychain-profile \"notarytool-profile\""
else
    echo -e "${GREEN}Submitted for notarization!${NC}"
    echo "Submission ID: $SUBMISSION_ID"
    echo ""
    echo -e "${YELLOW}Waiting for notarization to complete (this may take a few minutes)...${NC}"

    # Wait for notarization with timeout
    TIMEOUT=300  # 5 minutes
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        STATUS=$(xcrun notarytool info "$SUBMISSION_ID" \
            --keychain-profile "notarytool-profile" \
            --output-format json 2>&1 | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        if [ "$STATUS" = "Accepted" ]; then
            echo -e "${GREEN}Notarization successful!${NC}"

            # Staple the ticket
            echo -e "${YELLOW}Stapling notarization ticket to DMG...${NC}"
            xcrun stapler staple "$DMG_PATH"
            echo -e "${GREEN}Stapling complete!${NC}"
            break
        elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
            echo -e "${RED}Notarization failed!${NC}"
            echo "View details with:"
            echo "  xcrun notarytool log \"$SUBMISSION_ID\" --keychain-profile \"notarytool-profile\""
            exit 1
        fi

        echo -n "."
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        echo -e "${YELLOW}Notarization is taking longer than expected.${NC}"
        echo "Check status with:"
        echo "  xcrun notarytool info \"$SUBMISSION_ID\" --keychain-profile \"notarytool-profile\""
        echo "Once accepted, staple with:"
        echo "  xcrun stapler staple \"$DMG_PATH\""
    fi
fi

echo ""

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

# Upload appcast.xml to R2
upload_appcast_to_r2() {
    echo -e "${YELLOW}Uploading appcast.xml to Cloudflare R2...${NC}"

    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: AWS CLI is not installed.${NC}"
        echo "Install it with: brew install awscli"
        echo "Then configure R2 profile: aws configure --profile r2"
        return 1
    fi

    if ! aws configure list --profile r2 &> /dev/null 2>&1; then
        echo -e "${RED}Error: AWS CLI profile 'r2' is not configured.${NC}"
        echo "Configure it with: aws configure --profile r2"
        return 1
    fi

    aws s3 cp appcast.xml "s3://${R2_BUCKET}/${R2_APPCAST_PATH}" \
        --endpoint-url "$R2_ENDPOINT" \
        --profile r2 \
        --content-type "application/xml"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}appcast.xml uploaded to R2!${NC}"
        echo "  URL: ${APPCAST_PUBLIC_URL}"
    else
        echo -e "${RED}Error: Failed to upload appcast.xml to R2${NC}"
        return 1
    fi
}

# Generate appcast.xml with release notes from CHANGELOG.md
cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkleproject.org/xml/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mac Audio Input Locker</title>
    <link>${APPCAST_PUBLIC_URL}</link>
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

echo -e "${GREEN}appcast.xml generated with release notes from CHANGELOG.md!${NC}"
echo ""

upload_appcast_to_r2 || echo -e "${YELLOW}Skipping R2 upload. You can manually upload appcast.xml later.${NC}"

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
else
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  Create GitHub release and upload DMG:"
    echo "     ./bin/build-release.sh --upload"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
