#!/bin/bash
set -euo pipefail

# --- Surge ---
echo "Fetching latest Surge..."

# Get the latest release tag by following the 'latest' release redirect to avoid API rate limits
LATEST_TAG=$(curl -sI https://github.com/surge-downloader/Surge/releases/latest | grep -i '^location:' | sed 's/.*tag\///' | tr -d '\r')

if [[ -z "$LATEST_TAG" ]]; then
    echo "ERROR: Could not determine the latest tag for Surge." >&2
    exit 1
fi

# Surge release assets include the version number without the 'v' prefix
VERSION=${LATEST_TAG#v}
SURGE_DOWNLOAD_URL="https://github.com/surge-downloader/Surge/releases/download/${LATEST_TAG}/Surge_${VERSION}_linux_amd64.tar.gz"

TEMP_DIR=$(mktemp -d)
echo "Downloading from: $SURGE_DOWNLOAD_URL"
curl -fL "$SURGE_DOWNLOAD_URL" | tar -xz -C "$TEMP_DIR"

# Move the binary (find by name to handle any internal folder structure changes)
find "$TEMP_DIR" -type f -name "surge" -exec mv {} /usr/bin/surge \;
chmod +x /usr/bin/surge

# Cleanup
echo "Cleaning up..."
cd /
rm -rf "$TEMP_DIR"

echo "Surge installed successfully to /usr/bin/surge"

# --- Termflix ---
echo "Fetching latest Termflix..."

# Termflix has a predictable asset name, so we can use the latest/download endpoint directly
TERMFLIX_DOWNLOAD_URL="https://github.com/paulrobello/termflix/releases/latest/download/termflix-linux-x86_64"

echo "Downloading from: $TERMFLIX_DOWNLOAD_URL"
curl -fL "$TERMFLIX_DOWNLOAD_URL" -o /usr/bin/termflix
chmod +x /usr/bin/termflix

echo "Termflix installed successfully to /usr/bin/termflix"
