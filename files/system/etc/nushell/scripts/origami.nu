# /etc/nushell/scripts/origami.nu

# --- Nag Helper Utility ---
def nag_and_exec [tip: string, target: string, args: list<string>] {
    let is_help = ($args | any { |it| $it == "--help" })

    # Don't nag if stderr isn't a TTY (checking exit code of 'test -t 2')
    let is_tty = (([ -t 2 ] | complete).exit_code == 0)

    if not $is_help and $is_tty {
        print -e $"(ansi blue_italic)($tip)(ansi reset)"
    }
    run-external $target ...$args
}

# --- Modern Replacements ---
export alias htop = btop
export alias update = topgrade
export alias docker = podman
export alias docker-compose = podman-compose
export alias cat = bat
export alias sudo = sudo-rs
export alias su = su-rs

# --- Directory Listings (eza) ---
export alias la = eza -la --icons
export alias lt = eza --tree --level=2 --icons
export def --wrapped ls [...args] { ^eza --icons ...$args }
export def --wrapped ll [...args] { ^eza -l --icons ...$args }

# --- Fastfetch Wrapper ---
export def --wrapped fastfetch [...args] {
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
export def --wrapped tmux  [...args] { nag_and_exec '🌀 Tip: Try using "zellij or byobu" for a modern experience.' 'tmux' $args }
export def --wrapped find  [...args] { nag_and_exec '🧭 Tip: Try using "fd" next time for a simpler and faster search.' 'find' $args }
export def --wrapped grep  [...args] { nag_and_exec '🔍 Tip: Try using "rg" for a simpler and faster search.' 'grep' $args }
export def --wrapped nano  [...args] { nag_and_exec '📝 Tip: Give "micro" a try for a friendlier terminal editor.' 'nano' $args }
export def --wrapped git   [...args] { nag_and_exec '🐙 Tip: Try "lazygit" for a slick TUI when working with git.' 'git' $args }
export def --wrapped ps    [...args] { nag_and_exec '🧾 Tip: "procs" offers a richer, colorful process viewer than ps.' 'ps' $args }
export def --wrapped du    [...args] { nag_and_exec '🌬️ Tip: "dust" makes disk usage checks faster and easier than du.' 'du' $args }
export def --wrapped vim   [...args] { nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of vim).' 'nvim' $args }
export def --wrapped nvim  [...args] { nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of nvim).' 'nvim' $args }

# --- uutils-coreutils shims ---
# Dynamically create aliases for all uu_ binaries
# Note: In Nushell, we loop and use the 'alias' keyword
do {
    let uu_path = "/usr/bin"
    if ($uu_path | path exists) {
        let shims = (ls ($uu_path | path join "uu_*") | get name | each { path basename })
        for bin in $shims {
            let std_cmd = ($bin | str replace "uu_" "")
            if ($std_cmd not-in ["ls", "cat", "[", "test", "ps", "du"]) {
                # This creates a simple name mapping
                alias $std_cmd = ^$bin
            }
        }
    }
}
