#!/bin/bash
set -euo pipefail

# 1. Fetch latest Surge download URL
echo "Fetching latest Surge..."
REPO="surge-downloader/Surge"
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest \
  | jq -r '.assets[] | select(.name | contains("linux_amd64.tar.gz")) | .browser_download_url')

# 2. Guard against empty URL (API rate limit, asset rename, network error, etc.)
if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "ERROR: Could not find a download URL for Surge. The GitHub API may be rate-limiting this request or the asset name has changed." >&2
    exit 1
fi

# 3. Create a temporary directory and download + extract the archive
TEMP_DIR=$(mktemp -d)
echo "Downloading from: $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" | tar -xz -C "$TEMP_DIR"

# 4. Move the binary (find by name to handle any internal folder structure changes)
find "$TEMP_DIR" -type f -name "surge" -exec mv {} /usr/bin/surge \;
chmod +x /usr/bin/surge

# 5. Cleanup
echo "Cleaning up..."
cd /
rm -rf "$TEMP_DIR"

echo "Surge installed successfully to /usr/bin/surge"

# --- Termflix ---

# 1. Fetch latest Termflix download URL
echo "Fetching latest Termflix..."
REPO="paulrobello/termflix"
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest \
  | jq -r '.assets[] | select(.name == "termflix-linux-x86_64") | .browser_download_url')

# 2. Guard against empty URL
if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "ERROR: Could not find a download URL for Termflix. The GitHub API may be rate-limiting this request or the asset name has changed." >&2
    exit 1
fi

# 3. Download the binary directly
echo "Downloading from: $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" -o /usr/bin/termflix
chmod +x /usr/bin/termflix

echo "Termflix installed successfully to /usr/bin/termflix"
