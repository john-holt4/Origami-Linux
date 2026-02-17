#!/bin/bash
set -e

# 1. Ensure the destination directories exist
mkdir -p /usr/local/bin
mkdir -p /usr/share/applications
mkdir -p /usr/share/icons/hicolor/scalable/apps/

# 2. Install Build Dependencies
# Added glib2-devel, gstreamer1-devel, and gstreamer1-plugins-base-devel for Ethereal Waves
echo "Installing build dependencies..."
dnf install -y \
    curl jq cargo git gcc just \
    libxkbcommon-devel \
    glib2-devel \
    gstreamer1-devel \
    gstreamer1-plugins-base-devel

# --- PART 1: SURGE (Binary) ---
echo "Fetching latest Surge..."
REPO="surge-downloader/Surge"
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest \
  | jq -r '.assets[] | select(.name | contains("linux_amd64.tar.gz")) | .browser_download_url')

TEMP_DIR=$(mktemp -d)
curl -L "$DOWNLOAD_URL" | tar -xz -C "$TEMP_DIR"
find "$TEMP_DIR" -type f -name "surge" -exec mv {} /usr/local/bin/surge \;
chmod +x /usr/local/bin/surge
echo "Surge installed to /usr/local/bin/surge"

# --- PART 2: ETHEREAL WAVES (Source Build) ---
echo "Building Ethereal Waves..."
mkdir -p /tmp/build && cd /tmp/build
git clone https://github.com/LotusPetal392/ethereal-waves.git
cd ethereal-waves
cargo build --release
mv target/release/ethereal-waves /usr/local/bin/

cat <<EOF > /usr/share/applications/ethereal-waves.desktop
[Desktop Entry]
Type=Application
Name=Ethereal Waves
Exec=ethereal-waves
Icon=multimedia-audio-player
Terminal=true
Categories=Utility;
EOF

# --- PART 3: CUPOLA (Source Build) ---
echo "Building Cupola..."
cd /tmp/build
git clone https://github.com/cosmic-utils/cupola.git
cd cupola
just build-release
mv target/release/cupola /usr/local/bin/

# Install the official Cupola icon
cp res/icons/hicolor/scalable/apps/cupola.svg /usr/share/icons/hicolor/scalable/apps/

cat <<EOF > /usr/share/applications/cupola.desktop
[Desktop Entry]
Type=Application
Name=Cupola
Comment=COSMIC Image Viewer
Exec=cupola
Icon=cupola
Terminal=false
Categories=Graphics;2DGraphics;Viewer;
EOF

# --- CLEANUP ---
echo "Cleaning up..."
cd /
rm -rf /tmp/build "$TEMP_DIR"
# Remove the tools and devel packages to keep the final image clean
dnf remove -y \
    cargo git gcc just \
    libxkbcommon-devel glib2-devel \
    gstreamer1-devel gstreamer1-plugins-base-devel
dnf clean all

echo "Build complete!"
