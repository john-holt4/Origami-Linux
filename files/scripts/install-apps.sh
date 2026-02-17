#!/bin/bash
set -e

# 1. Ensure the destination directory exists
# In image builds, /usr/local/bin may not exist yet
mkdir -p /usr/local/bin

# 2. Fetch latest Surge
echo "Fetching latest Surge..."
REPO="surge-downloader/Surge"
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest \
  | jq -r '.assets[] | select(.name | contains("linux_amd64.tar.gz")) | .browser_download_url')

# Create a temporary directory for extraction
TEMP_DIR=$(mktemp -d)

echo "Downloading from: $DOWNLOAD_URL"
curl -L "$DOWNLOAD_URL" | tar -xz -C "$TEMP_DIR"

# 4. Move the binary
# We find by name to handle any internal folder structure changes
find "$TEMP_DIR" -type f -name "surge" -exec mv {} /usr/local/bin/surge \;
chmod +x /usr/local/bin/surge

# 5. Cleanup
echo "Cleaning up..."
cd /
rm -rf "$TEMP_DIR"

echo "Surge installed successfully to /usr/local/bin/surge"
