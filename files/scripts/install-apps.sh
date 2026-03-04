#!/bin/bash
set -euo pipefail

echo "Configuring Zen Browser Flatpak to install on first login..."

# Create a systemd user service to install Zen Browser Flatpak on first login
# It leaves a marker file so if the user uninstalls it, it won't keep reinstalling
mkdir -p /usr/lib/systemd/user

cat << 'EOF' > /usr/lib/systemd/user/install-zen-browser.service
[Unit]
Description=Install Zen Browser Flatpak on First Login
After=network-online.target
Wants=network-online.target
ConditionPathExists=!%h/.local/state/zen-browser-installed.marker

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak install --user --noninteractive -y flathub app.zen_browser.zen
ExecStartPost=/bin/sh -c 'mkdir -p %h/.local/state && touch %h/.local/state/zen-browser-installed.marker'
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

systemctl --global enable install-zen-browser.service
