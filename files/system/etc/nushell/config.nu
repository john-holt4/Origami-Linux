# /etc/nushell/config.nu
# Origami Shell System-Wide Entry Point

# --- Environment guard ---
# Equivalent to [ -n "$DISTROBOX_ENTER_PATH" ]
if ($env | default "" DISTROBOX_ENTER_PATH | get DISTROBOX_ENTER_PATH | is-empty) {

    # Load the Origami logic
    if ("/etc/nushell/scripts/origami.nu" | path exists) {
        use /etc/nushell/scripts/origami.nu *
    }

    # Load Starship and Zoxide (Pre-generated for speed)
    if ("/etc/nushell/starship.nu" | path exists) { source /etc/nushell/starship.nu }
    if ("/etc/nushell/zoxide.nu" | path exists) { source /etc/nushell/zoxide.nu }
}

# --- Default Table Styling ---
$env.config = {
    show_banner: false
    table: { mode: rounded }
}
