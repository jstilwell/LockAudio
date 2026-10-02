#!/bin/bash
set -e

# Renders the vector icon sources in design/icons/ into the PNGs the app (and
# the lockaudio.com site) ship. Uses headless Chrome: ImageMagick's built-in
# SVG renderer draws the masked sound-bar cut-outs wrongly.
#
#   ./bin/render-icons.sh [path/to/lockaudio.com]
#
# With a website path, also refreshes its static/appicon.png and
# static/menuicon.svg. (static/og-image.png embeds the icon too and is
# rendered separately.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC="$PROJECT_DIR/design/icons"
ASSETS="$PROJECT_DIR/LockAudio/Assets.xcassets"
WEBSITE_DIR="$1"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "Error: Google Chrome is required at $CHROME"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render <svg> <out.png> <px>
render() {
    printf '<html><body style="margin:0;background:transparent"><img src="file://%s" width="%s" height="%s" style="display:block"></body></html>' \
        "$1" "$3" "$3" > "$WORK/render.html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 --force-device-scale-factor=1 \
        --window-size="$3,$3" --screenshot="$2" "file://$WORK/render.html" > /dev/null 2>&1
}

# App icon (sizes referenced by AppIcon.appiconset/Contents.json)
for px in 16 32 64 128 256 512 1024; do
    render "$SRC/appicon.svg" "$ASSETS/AppIcon.appiconset/icon_$px.png" "$px"
done

# Menu bar template images, 18pt at 1x and 2x
for state in active paused attention; do
    render "$SRC/status-$state.svg" "$ASSETS/status-$state.imageset/status-$state.png" 18
    render "$SRC/status-$state.svg" "$ASSETS/status-$state.imageset/status-$state@2x.png" 36
done

echo "Rendered app icon and status images into $ASSETS"

if [ -n "$WEBSITE_DIR" ]; then
    render "$SRC/appicon.svg" "$WEBSITE_DIR/static/appicon.png" 512
    cp "$SRC/status-active.svg" "$WEBSITE_DIR/static/menuicon.svg"
    echo "Updated $WEBSITE_DIR/static/appicon.png and menuicon.svg"
fi
