#!/usr/bin/env bash

# ============================================================================ #
# Origami shell convenience layer
# ============================================================================ #

# --- Environment guard -------------------------------------------------------
if [ -n "$DISTROBOX_ENTER_PATH" ]; then
    return
fi

# --- Cleanup -----------------------------------------------------------------
# Initial cleanup (good practice, but we will strictly unalias below too)
unset -f grep find tmux ls ll nano git ps du 2>/dev/null
unalias ls 2>/dev/null
unalias ll 2>/dev/null

# --- Helper utilities --------------------------------------------------------
_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_eval_if_available() {
    local binary="$1"
    shift
    if _command_exists "$binary"; then
        eval "$("$binary" "$@")"
    fi
}

_should_nag() {
    # 1. Don't nag during completion (COMP_LINE check)
    # 2. Don't nag if stderr isn't a TTY
    if [ ! -t 2 ] || [ -n "$COMP_LINE" ]; then
        return 1
    fi

    # 3. Don't nag if the user is asking for --help
    for arg in "$@"; do
        if [ "$arg" = "--help" ]; then
            return 1
        fi
    done

    return 0
}

_nag_and_exec() {
    local tip="$1"
    shift
    local target="$1"
    shift

    # Pass remaining arguments to _should_nag to check for flags
    if _should_nag "$@"; then
        printf '%s\n' "$tip" >&2
    fi
    command "$target" "$@"
}

# --- Wrappers ----------------------------------------------------------------
fastfetch() {
    if [ $# -eq 0 ]; then
        local config_dir="/usr/share/fastfetch/presets/origami"
        # Safety check: only load custom config if files exist
        if [ -f "$config_dir/origami-ascii.txt" ] && [ -f "$config_dir/origami-fastfetch.jsonc" ]; then
            command fastfetch \
                -l "$config_dir/origami-ascii.txt" \
                --logo-color-1 blue \
                -c "$config_dir/origami-fastfetch.jsonc"
        else
            command fastfetch
        fi
    else
        command fastfetch "$@"
    fi
}

# --- Modern replacements -----------------------------------------------------
alias htop='btop'
alias cmatrix='termflix'
alias update='topgrade'
alias docker='podman'
alias docker-compose='podman-compose'
alias cat='bat'
alias sudo='sudo-rs '
alias su='su-rs'

# --- Directory listings via eza ----------------------------------------------
alias la='eza -la --icons'
alias lt='eza --tree --level=2 --icons'
ls() { command eza --icons "$@"; }
ll() { command eza -l --icons "$@"; }

# --- Interactive tooling -----------------------------------------------------
_eval_if_available fzf --bash
_eval_if_available starship init bash
_eval_if_available zoxide init bash --cmd cd

# --- uutils-coreutils shims --------------------------------------------------
_register_uutils_aliases() {
    local uu_bin base_cmd std_cmd
    for uu_bin in /usr/bin/uu_*; do
        [ -e "$uu_bin" ] || continue
        base_cmd=$(basename "$uu_bin")
        std_cmd="${base_cmd#uu_}"
        case "$std_cmd" in
        ls | cat | '[' | test) continue ;;
        esac
        alias "$std_cmd"="$base_cmd"
    done
}
_register_uutils_aliases

# --- Friendly migration nags -------------------------------------------------
# We must unalias these first to prevent 'syntax error' if they are already
# aliased elsewhere (e.g. grep='grep --color').
unalias vim tmux find grep nano git ps du 2>/dev/null

tmux() {
    _nag_and_exec '🌀 Tip: Try using "zellij or byobu" for a modern multiplexing experience.' tmux "$@"
}

find() {
    _nag_and_exec '🧭 Tip: Try using "fd" next time for a simpler and faster search.' find "$@"
}

grep() {
    _nag_and_exec '🔍 Tip: Try using "rg" for a simpler and faster search.' grep "$@"
}

nano() {
    _nag_and_exec '📝 Tip: Give "micro" a try for a friendlier terminal editor.' nano "$@"
}

git() {
    _nag_and_exec '🐙 Tip: Try "lazygit" for a slick TUI when working with git.' git "$@"
}

ps() {
    _nag_and_exec '🧾 Tip: "procs" offers a richer, colorful process viewer than ps.' ps "$@"
}

du() {
    _nag_and_exec '🌬️ Tip: "dust" makes disk usage checks faster and easier than du.' du "$@"
}

vim() {
    _nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of vim).' nvim "$@"
}

nvim() {
    _nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of nvim).' nvim "$@"
}
