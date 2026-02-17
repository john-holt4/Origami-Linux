# ============================================================================ #
# Origami Shell Convenience Layer (Global Vendor Autoload)
# ============================================================================ #

# --- Environment Guard ---
# Matches: if [ -n "$DISTROBOX_ENTER_PATH" ]; then return; fi
if ($env | default "" DISTROBOX_ENTER_PATH | get DISTROBOX_ENTER_PATH | is-empty) {

    # --- Nag Helper Utility ---
    # Matches: _nag_and_exec logic (Checks for TTY and --help flag)
    def nag_and_exec [tip: string, target: string, args: list<string>] {
        let is_help = ($args | any { |it| $it == "--help" })
        let is_tty = (([ -t 2 ] | complete).exit_code == 0)

        if not $is_help and $is_tty {
            print -e $"(ansi blue_italic)($tip)(ansi reset)"
        }
        run-external $target ...$args
    }

    # --- Modern Replacements ---
    alias vim = nvim
    alias htop = btop
    alias update = topgrade
    alias docker = podman
    alias docker-compose = podman-compose
    alias cat = bat
    alias sudo = sudo-rs
    alias su = su-rs

    # --- Directory Listings (eza) ---
    alias la = eza -la --icons
    alias lt = eza --tree --level=2 --icons
    def --wrapped ls [...args] { ^eza --icons ...$args }
    def --wrapped ll [...args] { ^eza -l --icons ...$args }

    # --- Fastfetch Wrapper ---
    def --wrapped fastfetch [...args] {
        let config_dir = "/usr/share/fastfetch/presets/origami"
        let ascii = ($config_dir | path join "origami-ascii.txt")
        let json = ($config_dir | path join "origami-fastfetch.jsonc")

        if ($args | is-empty) and ($ascii | path exists) and ($json | path exists) {
            ^fastfetch -l $ascii --logo-color-1 blue -c $json
        } else {
            ^fastfetch ...$args
        }
    }

    # --- Migration Nags ---
    def --wrapped tmux  [...args] { nag_and_exec '🌀 Tip: Try using "zellij or byobu" for a modern experience.' 'tmux' $args }
    def --wrapped find  [...args] { nag_and_exec '🧭 Tip: Try using "fd" next time for a simpler and faster search.' 'find' $args }
    def --wrapped grep  [...args] { nag_and_exec '🔍 Tip: Try using "rg" for a simpler and faster search.' 'grep' $args }
    def --wrapped nano  [...args] { nag_and_exec '📝 Tip: Give "micro" a try for a friendlier terminal editor.' 'nano' $args }
    def --wrapped git   [...args] { nag_and_exec '🐙 Tip: Try "lazygit" for a slick TUI when working with git.' 'git' $args }
    def --wrapped ps    [...args] { nag_and_exec '🧾 Tip: "procs" offers a richer, colorful process viewer than ps.' 'ps' $args }
    def --wrapped du    [...args] { nag_and_exec '🌬️ Tip: "dust" makes disk usage checks faster and easier than du.' 'du' $args }
    def --wrapped nvim  [...args] { nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of nvim).' 'nvim' $args }

    # --- uutils-coreutils shims ---
    # Sources the pre-generated static alias file
    if ("/usr/share/nushell/origami_uutils.nu" | path exists) {
        source "/usr/share/nushell/origami_uutils.nu"
    }
}
