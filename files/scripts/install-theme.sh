#!/usr/bin/env bash
set -euo pipefail

git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme
/tmp/WhiteSur-icon-theme/install.sh -b -a
rm -rf /tmp/WhiteSur-icon-theme
rm -rf /usr/share/backgrounds/*
