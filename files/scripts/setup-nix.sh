#!/usr/bin/env bash
set -euo pipefail

# 1. Create the persistent source directory in /var
# BlueBuild usually works on /var during build, but we ensure it exists
mkdir -p /var/lib/nix

# 2. Create the mount point in the root filesystem
# Note: On some immutable builders, / is read-only.
# We create it in the build context so it exists in the final image.
mkdir -p /nix

# 3. Apply SELinux labels for the build environment
# This ensures that when the system boots, /var/lib/nix already has
# the correct 'usr_t' type expected by the Nix daemon.
if command -v semanage &> /dev/null; then
    echo "Setting SELinux context for /var/lib/nix..."
    semanage fcontext -a -t usr_t '/var/lib/nix(/.*)?'
    restorecon -R /var/lib/nix
else
    echo "SELinux tools not found, skipping labeling (may require manual fix if enforcing)."
fi

# 4. Set basic permissions
chmod 755 /var/lib/nix
chmod 755 /nix
