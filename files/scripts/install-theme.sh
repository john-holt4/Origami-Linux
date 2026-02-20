#!/usr/bin/env bash
set -euo pipefail

git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme
/tmp/WhiteSur-icon-theme/install.sh -b -a
rm -rf /tmp/WhiteSur-icon-theme
rm -rf /usr/share/backgrounds/cosmic
rm -rf /usr/share/backgrounds/fedora-workstation
rm -rf /usr/share/backgrounds/images
rm -rf /usr/share/backgrounds/f43
rm -f /usr/share/backgrounds/default.jxl
rm -f /usr/share/backgrounds/default-dark.jxl
rm -f /usr/share/backgrounds/default.xml
