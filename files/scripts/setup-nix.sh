#!/usr/bin/env bash
set -euo pipefail

# Only ensure the directories exist during build context
# The actual persistence and labeling is handled by tmpfiles.d at boot
mkdir -p /var/lib/nix
mkdir -p /nix
