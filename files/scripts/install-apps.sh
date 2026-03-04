#!/bin/bash
set -euo pipefail

echo "Preparing offline Flatpak bundle for Zen Browser..."

# Set up a temporary home to pull the Flatpak without touching /var (which gets wiped)
export XDG_DATA_HOME=/tmp/flatpak-data
mkdir -p "$XDG_DATA_HOME"
mkdir -p /usr/share/offline-flatpaks

# Attempt to download and bundle the Flatpak during the container build
# We use an if-statement because some strict build environments block Flatpak's bubblewrap
if flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && \
   flatpak install --user --noninteractive -y flathub app.zen_browser.zen && \
   flatpak build-bundle "$XDG_DATA_HOME/flatpak/repo" /usr/share/offline-flatpaks/zen-browser.flatpak app.zen_browser.zen; then

    echo "Successfully cached Zen Browser Flatpak offline."
    # If successful, our first-boot service will install from the local file
    FLATPAK_INSTALL_CMD="/usr/bin/flatpak install --user --noninteractive -y /usr/share/offline-flatpaks/zen-browser.flatpak"
else
echo "Warning: Could not cache Flatpak during build (likely due to build environment limits). Falling back to online install on first boot."
# Fallback to online install if the build environment blocked the offline caching
FLATPAK_INSTALL_CMD="/usr/bin/flatpak install --user --noninteractive -y flathub app.zen_browser.zen"
fi

# Clean up the temporary flatpak data so it doesn't bloat the image
rm -rf "$XDG_DATA_HOME"

# Create a systemd user service to install Zen Browser Flatpak on first login
# It leaves a marker file so if the user uninstalls it, it won't keep reinstalling
mkdir -p /usr/lib/systemd/user
cat << EOF > /usr/lib/systemd/user/install-zen-browser.service
[Unit]
Description=Install Zen Browser Flatpak on First Login
After=network-online.target
Wants=network-online.target
ConditionPathExists=!%h/.local/state/zen-browser-installed.marker

[Service]
Type=oneshot
ExecStart=${FLATPAK_INSTALL_CMD}
ExecStartPost=/bin/sh -c 'mkdir -p %h/.local/state && touch %h/.local/state/zen-browser-installed.marker'
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

systemctl --global enable install-zen-browser.service
