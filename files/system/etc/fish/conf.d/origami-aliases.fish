#!/usr/bin/env fish

# ============================================================================ #
# Origami shell convenience layer (Fish Port)
# ============================================================================ #

# --- Environment guard -------------------------------------------------------
if set -q DISTROBOX_ENTER_PATH
    return
end

# --- Helper utilities --------------------------------------------------------
function _command_exists
    command -v "$argv[1]" >/dev/null 2>&1
end

function _should_nag
    # 1. Check if interactive
    if not status is-interactive
        return 1
    end

    # 2. Don't nag if stderr isn't a TTY (Fish uses 2 for stderr)
    if not test -t 2
        return 1
    end

    # 3. Don't nag if the user is asking for --help
    for arg in $argv
        if test "$arg" = "--help"
            return 1
        end
    end

    return 0
end

function _nag_and_exec
    set -l tip $argv[1]
    set -e argv[1]
    set -l target $argv[1]
    set -e argv[1]

    if _should_nag $argv
        printf '%s\n' "$tip" >&2
    end

    command "$target" $argv
end

# --- Wrappers ----------------------------------------------------------------
function fastfetch
    if test (count $argv) -eq 0
        set -l config_dir "/usr/share/fastfetch/presets/origami"
        if test -f "$config_dir/origami-ascii.txt"; and test -f "$config_dir/origami-fastfetch.jsonc"
            command fastfetch \
                -l "$config_dir/origami-ascii.txt" \
                --logo-color-1 blue \
                -c "$config_dir/origami-fastfetch.jsonc"
        else
            command fastfetch
        end
    else
        command fastfetch $argv
    end
end

# --- Modern replacements -----------------------------------------------------
# Note: These are applied early but will be overridden by nag functions if names overlap
alias htop btop
alias update topgrade
alias docker podman
alias docker-compose podman-compose
alias cat bat
alias sudo sudo-rs
alias su su-rs
alias cmatrix termflix

# --- Directory listings via eza ----------------------------------------------
alias la 'eza -la --icons'
alias lt 'eza --tree --level=2 --icons'
function ls
    command eza --icons $argv
end
function ll
    command eza -l --icons $argv
end

# --- Interactive tooling -----------------------------------------------------
if status is-interactive
    set -g fish_greeting "" # Disable welcome message

    if _command_exists fzf; fzf --fish | source; end
    if _command_exists starship; starship init fish | source; end
    if _command_exists zoxide; zoxide init fish --cmd cd | source; end
end

# --- uutils-coreutils shims --------------------------------------------------
function _register_uutils_aliases
    for uu_bin in /usr/bin/uu_*
        if test -e "$uu_bin"
            set -l base_cmd (basename "$uu_bin")
            set -l std_cmd (string replace -r '^uu_' '' "$base_cmd")
            switch "$std_cmd"
                case ls cat '[' test vim nvim grep find tmux nano git ps du
                    continue
            end
            alias "$std_cmd" "$base_cmd"
        end
    end
end
_register_uutils_aliases

# --- Friendly migration nags -------------------------------------------------
# In Fish, defining these functions automatically replaces any previous alias.

function tmux
    _nag_and_exec '🌀 Tip: Try using "zellij or byobu" for a modern multiplexing experience.' tmux $argv
end

function find
    _nag_and_exec '🧭 Tip: Try using "fd" next time for a simpler and faster search.' find $argv
end

function grep
    _nag_and_exec '🔍 Tip: Try using "rg" for a simpler and faster search.' grep $argv
end

function nano
    _nag_and_exec '📝 Tip: Give "micro" a try for a friendlier terminal editor.' nano $argv
end

function git
    _nag_and_exec '🐙 Tip: Try "lazygit" for a slick TUI when working with git.' git $argv
end

function ps
    _nag_and_exec '🧾 Tip: "procs" offers a richer, colorful process viewer than ps.' ps $argv
end

function du
    _nag_and_exec '🌬️ Tip: "dust" makes disk usage checks faster and easier than du.' du $argv
end

function vim
    _nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of vim).' nvim $argv
end

function nvim
    _nag_and_exec '📝 Tip: Try using Helix next time: run "hx" (instead of nvim).' nvim $argv
end
