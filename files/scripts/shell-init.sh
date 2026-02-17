#!/usr/bin/env bash

# 1. Install Nushell from Gemfury
echo "[gemfury-nushell]
name=Gemfury Nushell Repo
baseurl=https://yum.fury.io/nushell/
enabled=1
gpgcheck=0
gpgkey=https://yum.fury.io/nushell/gpg.key" | sudo tee /etc/yum.repos.d/fury-nushell.repo
sudo dnf install -y nushell

# 2. Ensure system directories exist
sudo mkdir -p /etc/nushell/scripts
sudo mkdir -p /usr/share/nushell/vendor/autoload

# 3. Pre-generate Starship & Zoxide
# We place these in /etc/nushell to be sourced by the global config.nu
starship init nu | sudo tee /etc/nushell/starship.nu > /dev/null
zoxide init nushell | sudo tee /etc/nushell/zoxide.nu > /dev/null

# 4. Pre-generate uutils shims statically
# We move this to /usr/share/nushell to keep it with system vendor files
ls /usr/bin/uu_* | sed 's|.*/uu_\(.*\)|alias \1 = ^&|' | grep -vE "ls|cat|\[|test|ps|du|true|false" | sudo tee /usr/share/nushell/origami_uutils.nu > /dev/null

# --- 1. System-wide (Bash/Fish/General) ---
echo 'export EDITOR="micro"
export VISUAL="micro"' | sudo tee /etc/profile.d/editor.sh
sudo chmod 644 /etc/profile.d/editor.sh

# --- 2. Nushell Specific ---
# We ensure Nushell explicitly maps the system variable into its structured $env
sudo mkdir -p /etc/nushell
echo "\$env.EDITOR = (\$env | default \"micro\" EDITOR | get EDITOR)
\$env.VISUAL = (\$env | default \"micro\" VISUAL | get VISUAL)" | sudo tee /etc/nushell/env.nu > /dev/null

# --- 3. Fish Specific ---
# Fish usually picks up /etc/profile.d, but to be 100% sure:
sudo mkdir -p /etc/fish/conf.d
echo 'set -gx EDITOR micro
set -gx VISUAL micro' | sudo tee /etc/fish/conf.d/editor.fish
