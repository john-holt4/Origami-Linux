# /etc/nushell/config.nu
# Global System Configuration for Origami OS

# --- 1. Aesthetics ---
$env.config = {
    show_banner: false # Removes the welcome art
    ls: {
        use_ls_colors: true
        clickable_links: true
    }
    table: {
        mode: rounded      # Modern rounded corners
        index_mode: always # Row indices
    }
}

# --- 2. Interactive Tooling ---
# Guarded so these don't run inside Distrobox containers
if ($env | default "" DISTROBOX_ENTER_PATH | get DISTROBOX_ENTER_PATH | is-empty) {
    if ("/etc/nushell/starship.nu" | path exists) { source /etc/nushell/starship.nu }
    if ("/etc/nushell/zoxide.nu" | path exists) { source /etc/nushell/zoxide.nu }
}
