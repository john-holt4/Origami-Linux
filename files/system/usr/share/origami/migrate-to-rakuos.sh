#!/usr/bin/env bash

set -uo pipefail

SCRIPT_NAME="origami-migrate-to-rakuos"
PROMPT_INTERVAL_DAYS=1
PROMPT_INTERVAL_SECONDS=$((PROMPT_INTERVAL_DAYS * 24 * 60 * 60))
STARTUP_DELAY_SECONDS=5

RAKUOS_URL="https://rakuos.org/origami"
RAKUOS_LOGO_URL="https://rakuos.org/themes/raku/assets/images/rakuos_whitelogo_med.png"

STANDARD_REF="ostree-unverified-registry:quay.io/rakuos/rakuos-cosmic:latest"
NVIDIA_REF="ostree-unverified-registry:quay.io/rakuos/rakuos-cosmic-nvidia:latest"

WINDOW_ICON_INSTALL="system-software-install"
WINDOW_ICON_INFO="dialog-information"
WINDOW_ICON_WARN="dialog-warning"
WINDOW_ICON_ERROR="dialog-error"
WINDOW_ICON_REBOOT="system-reboot"
WINDOW_ICON_LOG="text-x-generic"

HOME_DIR="${HOME:-/tmp}"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME_DIR/.cache}"
STATE_BASE="${XDG_STATE_HOME:-$HOME_DIR/.local/state}"

CACHE_DIR="$CACHE_BASE/origami"
STATE_DIR="$STATE_BASE/origami"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
if [ -z "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ] || [ ! -w "$RUNTIME_DIR" ]; then
    RUNTIME_DIR="/tmp"
fi

LOGO_FILE="$CACHE_DIR/rakuos-logo.png"
REMIND_FILE="$STATE_DIR/migrate-to-rakuos-remind-at"
SUCCESS_BOOT_FILE="$STATE_DIR/migrate-to-rakuos-success-boot-id"
SCRIPT_LOG="$STATE_DIR/migrate-to-rakuos.log"
LOCK_FILE="$RUNTIME_DIR/${SCRIPT_NAME}-${UID}.lock"
FALLBACK_IMAGE="/usr/share/pixmaps/origami-logo.png"

LAST_ATTEMPT_LOG=""

mkdir -p "$CACHE_DIR" "$STATE_DIR" 2>/dev/null || true

timestamp() {
    date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >>"$SCRIPT_LOG" 2>/dev/null || true
}

skip() {
    log "Skipping: $*"
    exit 0
}

flush_progress_state() {
    [ "${progress_open:-0}" -eq 1 ] || return 0

    if [ "${phase_text:-}" != "${last_sent_text:-}" ] || [ "${progress_value:-0}" -ne "${last_sent_value:--1}" ]; then
        printf '# %s\n' "$phase_text" >&3 || true
        printf '%s\n' "$progress_value" >&3 || true
        last_sent_text="$phase_text"
        last_sent_value="$progress_value"
    fi
}

update_progress_from_log_line() {
    local line="$1"
    local current total completed mapped

    case "$line" in
        Pulling\ manifest:*)
            if [ "$progress_value" -lt 3 ]; then
                progress_value=3
            fi
            phase_text="Connecting to the RakuOS image registry..."
            return
            ;;
        Importing:*)
            if [ "$progress_value" -lt 6 ]; then
                progress_value=6
            fi
            phase_text="Importing image metadata..."
            return
            ;;
        ostree\ chunk\ layers\ already\ present:*|ostree\ chunk\ layers\ needed:*|custom\ layers\ needed:*)
            if [ "$progress_value" -lt 10 ]; then
                progress_value=10
            fi
            phase_text="Preparing download..."
            return
            ;;
        *Checking\ out\ tree*|*Writing\ objects:*|*Writing\ commit:*|*Creating\ deployment*|*Staging\ deployment*|*Deploying*)
            if [ "$progress_value" -lt 92 ]; then
                progress_value=92
            fi
            phase_text="Writing the new deployment..."
            return
            ;;
    esac

    if [[ "$line" =~ ^\[([0-9]+)/([0-9]+)\][[:space:]]+Fetching[[:space:]] ]]; then
        current="${BASH_REMATCH[1]}"
        total="${BASH_REMATCH[2]}"

        if [ "$total" -gt 0 ]; then
            completed=$((current + 1))
            mapped=$((10 + (completed * 78 / total)))

            if [ "$mapped" -gt "$progress_value" ]; then
                progress_value="$mapped"
            fi

            phase_text="Downloading RakuOS... (${completed}/${total})"
        fi
    fi
}

log "Script started (user=${USER:-$UID}, display=${DISPLAY:-}, wayland=${WAYLAND_DISPLAY:-}, runtime_dir=$RUNTIME_DIR)"

if command -v flock >/dev/null 2>&1; then
    if exec 9>"$LOCK_FILE"; then
        if ! flock -n 9; then
            skip "another migration prompt instance is already running"
        fi
    else
        log "Could not open lock file $LOCK_FILE; continuing without lock"
    fi
fi

unset YAD_OPTIONS

if [ "${ORIGAMI_MIGRATE_SKIP_DELAY:-0}" != "1" ] && [ "$STARTUP_DELAY_SECONDS" -gt 0 ]; then
    log "Sleeping for $STARTUP_DELAY_SECONDS seconds before showing UI"
    sleep "$STARTUP_DELAY_SECONDS"
fi

have_gui_session() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        return 0
    fi

    [ -n "${DISPLAY:-}" ]
}

load_os_release() {
    local file

    if [ -r /etc/os-release ]; then
        file=/etc/os-release
    elif [ -r /usr/lib/os-release ]; then
        file=/usr/lib/os-release
    else
        return 1
    fi

    . "$file"
}

is_origami_system() {
    local identity

    identity="$(
        printf '%s %s %s %s' \
            "${ID:-}" \
            "${ID_LIKE:-}" \
            "${NAME:-}" \
            "${PRETTY_NAME:-}" |
            tr '[:upper:]' '[:lower:]'
    )"

    case "$identity" in
        *origami*) return 0 ;;
        *) return 1 ;;
    esac
}

staged_rakuos_deployment_exists() {
    local status_text

    status_text="$(rpm-ostree status 2>/dev/null || true)"
    [ -n "$status_text" ] || return 1

    printf '%s' "$status_text" | grep -Eqi \
        'registry\.gitlab\.com/rakuos/images/rakuos-cosmic(/nvidia)?(:latest)?|(^|[^[:alnum:]])rakuos-cosmic([^[:alnum:]]|$)'
}

current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

cleanup_boot_marker() {
    local current stored

    current="$(current_boot_id)"
    [ -n "$current" ] || return 0

    stored="$(head -n 1 "$SUCCESS_BOOT_FILE" 2>/dev/null || true)"
    if [ -n "$stored" ] && [ "$stored" != "$current" ]; then
        rm -f "$SUCCESS_BOOT_FILE"
    fi
}

migration_already_completed_this_boot() {
    local current stored

    current="$(current_boot_id)"
    [ -n "$current" ] || return 1

    stored="$(head -n 1 "$SUCCESS_BOOT_FILE" 2>/dev/null || true)"
    [ "$stored" = "$current" ]
}

record_success_this_boot() {
    local current

    current="$(current_boot_id)"
    [ -n "$current" ] || return 0
    printf '%s\n' "$current" >"$SUCCESS_BOOT_FILE"
}

should_prompt_now() {
    local now remind_at

    now="$(date +%s)"

    if [ -r "$REMIND_FILE" ]; then
        remind_at="$(head -n 1 "$REMIND_FILE" 2>/dev/null || true)"
        case "$remind_at" in
            ''|*[!0-9]*) ;;
            *)
                [ "$now" -lt "$remind_at" ] && return 1
                ;;
        esac
    fi

    return 0
}

set_remind_later() {
    printf '%s\n' "$(( $(date +%s) + PROMPT_INTERVAL_SECONDS ))" >"$REMIND_FILE"
    log "Prompt snoozed for $PROMPT_INTERVAL_DAYS day(s)"
}

clear_remind_later() {
    rm -f "$REMIND_FILE"
}

fetch_logo() {
    local tmp

    [ -s "$LOGO_FILE" ] && return 0

    tmp="${LOGO_FILE}.tmp.$$"
    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 2 --max-time 6 -o "$tmp" "$RAKUOS_LOGO_URL" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 6 -O "$tmp" "$RAKUOS_LOGO_URL" >/dev/null 2>&1 || true
    fi

    if [ -s "$tmp" ]; then
        mv -f "$tmp" "$LOGO_FILE"
        log "Downloaded RakuOS logo"
    else
        rm -f "$tmp"
    fi
}

get_dialog_image() {
    if [ -s "$LOGO_FILE" ]; then
        printf '%s\n' "$LOGO_FILE"
    elif [ -r "$FALLBACK_IMAGE" ]; then
        printf '%s\n' "$FALLBACK_IMAGE"
    else
        printf '%s\n' "system-software-install"
    fi
}

open_website() {
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$RAKUOS_URL" >/dev/null 2>&1 &
        log "Opened RakuOS website in default browser"
        return 0
    fi

    yad --center \
        --fixed \
        --width=480 \
        --borders=22 \
        --title="Open RakuOS Website" \
        --window-icon="$WINDOW_ICON_INFO" \
        --image="internet-web-browser" \
        --image-on-top \
        --text-width=58 \
        --buttons-layout=end \
        --selectable-labels \
        --button="Close":0 \
        --text="Your default browser couldn't be opened automatically.\n\nPlease visit:\n<b>${RAKUOS_URL}</b>" \
        >/dev/null 2>>"$SCRIPT_LOG"
}

detect_variant() {
    if [ -e /proc/driver/nvidia/version ]; then
        printf '%s\n' "nvidia"
        return
    fi

    if command -v lsmod >/dev/null 2>&1 && lsmod | grep -q '^nvidia'; then
        printf '%s\n' "nvidia"
        return
    fi

    if command -v lspci >/dev/null 2>&1 && lspci | grep -Eqi '(VGA|3D|Display).+NVIDIA|NVIDIA.+(VGA|3D|Display)'; then
        printf '%s\n' "nvidia"
        return
    fi

    printf '%s\n' "standard"
}

show_main_dialog() {
    local image="$1"
    local text
    local rc

    text=$(
        cat <<'EOF'
<span size="xx-large" weight="bold">Welcome to RakuOS</span>

Origami Linux is moving to RakuOS.

<span weight="bold">Why you're seeing this</span>
RakuOS is where future updates and support will continue.

<span weight="bold">What happens next</span>
• Your system is rebased to the RakuOS image
• Your files in <span font_family="monospace">/home</span> are normally preserved
• You'll restart once the migration is ready

<span weight="bold">Secure Boot</span>
If Secure Boot is enabled, you'll need one quick BIOS/UEFI change before the first RakuOS boot.
We'll show the exact steps again when the migration is ready.

Please back up anything important before continuing.
EOF
    )

    while true; do
        yad --center \
            --fixed \
            --width=760 \
            --borders=24 \
            --title="Move to RakuOS" \
            --window-icon="$WINDOW_ICON_INSTALL" \
            --image="$image" \
            --image-on-top \
            --text-width=64 \
            --buttons-layout=end \
            --selectable-labels \
            --text-align=left \
            --text="$text" \
            --button="Learn More":20 \
            --button="Remind Me Later":10 \
            --button="Continue":0 \
            >/dev/null 2>>"$SCRIPT_LOG"
        rc=$?

        case "$rc" in
            0)
                log "User chose to continue from main dialog"
                return 0
                ;;
            10)
                set_remind_later
                return 1
                ;;
            20)
                open_website
                ;;
            252|70)
                log "Main dialog dismissed without snoozing"
                return 2
                ;;
            *)
                log "Main dialog exited unexpectedly with status $rc"
                return 3
                ;;
        esac
    done
}

choose_variant() {
    local recommended="$1"
    local image="$2"
    local standard_selected="TRUE"
    local nvidia_selected="FALSE"
    local recommendation_label
    local choice
    local rc

    if [ "$recommended" = "nvidia" ]; then
        standard_selected="FALSE"
        nvidia_selected="TRUE"
        recommendation_label="NVIDIA"
    else
        recommendation_label="Standard"
    fi

    choice="$(
        yad --list \
            --radiolist \
            --center \
            --fixed \
            --width=760 \
            --height=300 \
            --borders=22 \
            --title="Choose Your RakuOS Image" \
            --window-icon="$WINDOW_ICON_INSTALL" \
            --image="$image" \
            --image-on-top \
            --text-width=62 \
            --buttons-layout=end \
            --text-align=left \
            --text="<span size=\"x-large\" weight=\"bold\">Choose an image</span>\n\nSelect the RakuOS image that matches this device.\nIf you're unsure, choose <b>Standard</b>.\n\nRecommended for this system: <b>${recommendation_label}</b>" \
            --column="" \
            --column="Id:HD" \
            --column="Image" \
            --column="Best for" \
            "$standard_selected" "standard" "Standard" "Intel, AMD, and most systems" \
            "$nvidia_selected" "nvidia" "NVIDIA" "Systems that need the NVIDIA image" \
            --print-column=2 \
            --button="Back":10 \
            --button="Install RakuOS":0 \
            2>>"$SCRIPT_LOG"
    )"
    rc=$?

    case "$rc" in
        0)
            if [ -z "$choice" ]; then
                choice="$recommended"
            fi
            log "Selected variant: $choice"
            printf '%s\n' "$choice"
            return 0
            ;;
        10|252|70)
            log "Variant selection dismissed; returning to main dialog"
            return 1
            ;;
        *)
            log "Variant dialog exited unexpectedly with status $rc"
            return 2
            ;;
    esac
}

show_log_file() {
    local file="$1"

    [ -r "$file" ] || return 1

    yad --text-info \
        --center \
        --width=960 \
        --height=640 \
        --title="Migration Log" \
        --window-icon="$WINDOW_ICON_LOG" \
        --filename="$file" \
        --button="Close":0 \
        >/dev/null 2>>"$SCRIPT_LOG"
}

show_dialog_with_optional_log() {
    local title="$1"
    local window_icon="$2"
    local text="$3"
    local file="${4:-}"
    local image="${5:-}"
    local rc

    while true; do
        if [ -n "$file" ] && [ -r "$file" ]; then
            yad --center \
                --fixed \
                --width=600 \
                --borders=22 \
                --title="$title" \
                --window-icon="$window_icon" \
                --image="$image" \
                --image-on-top \
                --text-width=58 \
                --buttons-layout=end \
                --selectable-labels \
                --text-align=left \
                --text="$text" \
                --button="Close":10 \
                --button="View Log":20 \
                >/dev/null 2>>"$SCRIPT_LOG"
            rc=$?

            case "$rc" in
                20)
                    show_log_file "$file"
                    ;;
                *)
                    return 0
                    ;;
            esac
        else
            yad --center \
                --fixed \
                --width=600 \
                --borders=22 \
                --title="$title" \
                --window-icon="$window_icon" \
                --image="$image" \
                --image-on-top \
                --text-width=58 \
                --buttons-layout=end \
                --selectable-labels \
                --text-align=left \
                --text="$text" \
                --button="Close":0 \
                >/dev/null 2>>"$SCRIPT_LOG"
            return 0
        fi
    done
}

interrupt_rebase_client() {
    local pid="$1"
    local step

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    printf '[%s] Sending SIGINT to rpm-ostree client (Ctrl+C)\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"

    kill -INT "$pid" 2>/dev/null || return 1

    for step in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done

    return 1
}

run_rebase() {
    local ref="$1"
    local label="$2"
    local progress_dir progress_fifo
    local cmd_pid yad_pid
    local cmd_status=0 yad_status=0
    local cmd_waited=0 user_canceled=0 progress_open=1 cancel_failed=0
    local progress_value=1
    local phase_text="Preparing migration..."
    local last_sent_value=-1
    local last_sent_text=""
    local last_line_count=0
    local current_line_count=0
    local start_line
    local line
    local idle_ticks=0
    local had_log_activity=0

    LAST_ATTEMPT_LOG="$STATE_DIR/rebase-$(date +%Y%m%d-%H%M%S).log"
    : >"$LAST_ATTEMPT_LOG"

    progress_dir="$(mktemp -d "$STATE_DIR/rebase-progress.XXXXXX" 2>/dev/null)" || {
        log "Failed to create temporary progress directory"
        printf '[%s] Failed to create temporary progress directory\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"
        return 1
    }

    progress_fifo="$progress_dir/progress.fifo"

    mkfifo "$progress_fifo" || {
        log "Failed to create progress FIFO"
        printf '[%s] Failed to create progress FIFO\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"
        rm -rf "$progress_dir"
        return 1
    }

    exec 3<>"$progress_fifo" || {
        log "Failed to open progress FIFO"
        printf '[%s] Failed to open progress FIFO\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"
        rm -rf "$progress_dir"
        return 1
    }

    yad --progress \
        --center \
        --fixed \
        --width=580 \
        --borders=22 \
        --title="Installing RakuOS" \
        --window-icon="$WINDOW_ICON_INSTALL" \
        --text-width=56 \
        --buttons-layout=end \
        --text-align=left \
        --text="Downloading and preparing RakuOS.\n\nThis may take several minutes depending on your connection and disk speed." \
        --button="Cancel":10 \
        <"$progress_fifo" >/dev/null 2>>"$SCRIPT_LOG" &
    yad_pid=$!

    rm -f "$progress_fifo"

    log "Starting rpm-ostree rebase to $label ($ref)"
    printf '[%s] Target: %s\n' "$(timestamp)" "$label" >>"$LAST_ATTEMPT_LOG"
    printf '[%s] Ref: %s\n' "$(timestamp)" "$ref" >>"$LAST_ATTEMPT_LOG"

    flush_progress_state

    rpm-ostree rebase "$ref" >>"$LAST_ATTEMPT_LOG" 2>&1 &
    cmd_pid=$!

    while :; do
        had_log_activity=0
        current_line_count="$(wc -l <"$LAST_ATTEMPT_LOG" 2>/dev/null | tr -d '[:space:]')"
        current_line_count="${current_line_count:-0}"

        if [ "$current_line_count" -gt "$last_line_count" ]; then
            start_line=$((last_line_count + 1))

            while IFS= read -r line; do
                update_progress_from_log_line "$line"
            done < <(sed -n "${start_line},${current_line_count}p" "$LAST_ATTEMPT_LOG" 2>/dev/null)

            last_line_count="$current_line_count"
            had_log_activity=1
            idle_ticks=0
            flush_progress_state
        fi

        if ! kill -0 "$cmd_pid" 2>/dev/null; then
            wait "$cmd_pid"
            cmd_status=$?
            cmd_waited=1

            current_line_count="$(wc -l <"$LAST_ATTEMPT_LOG" 2>/dev/null | tr -d '[:space:]')"
            current_line_count="${current_line_count:-0}"

            if [ "$current_line_count" -gt "$last_line_count" ]; then
                start_line=$((last_line_count + 1))

                while IFS= read -r line; do
                    update_progress_from_log_line "$line"
                done < <(sed -n "${start_line},${current_line_count}p" "$LAST_ATTEMPT_LOG" 2>/dev/null)

                last_line_count="$current_line_count"
            fi

            if [ "$progress_open" -eq 1 ]; then
                if [ "$progress_value" -lt 98 ]; then
                    progress_value=98
                    phase_text="Finalizing RakuOS..."
                    flush_progress_state
                fi

                progress_value=100
                phase_text="Done"
                flush_progress_state

                kill -USR1 "$yad_pid" 2>/dev/null || true
                wait "$yad_pid" 2>/dev/null || true
                progress_open=0
            fi
            break
        fi

        if [ "$progress_open" -eq 1 ] && ! kill -0 "$yad_pid" 2>/dev/null; then
            wait "$yad_pid"
            yad_status=$?
            progress_open=0

            case "$yad_status" in
                10|252)
                    user_canceled=1
                    log "User requested cancellation from the progress dialog"
                    printf '[%s] User requested cancellation from the progress dialog\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"

                    if interrupt_rebase_client "$cmd_pid"; then
                        if ! kill -0 "$cmd_pid" 2>/dev/null; then
                            wait "$cmd_pid" 2>/dev/null || true
                            cmd_status=$?
                            cmd_waited=1
                        fi
                    else
                        cancel_failed=1
                        log "SIGINT did not stop the rpm-ostree client within 10 seconds"
                        printf '[%s] SIGINT did not stop the rpm-ostree client within 10 seconds\n' "$(timestamp)" >>"$LAST_ATTEMPT_LOG"
                    fi
                    break
                    ;;
                *)
                    log "Progress dialog exited unexpectedly with status $yad_status"
                    printf '[%s] Progress dialog exited unexpectedly with status %s\n' "$(timestamp)" "$yad_status" >>"$LAST_ATTEMPT_LOG"
                    ;;
            esac
        fi

        if [ "$progress_open" -eq 1 ] && [ "$had_log_activity" -eq 0 ]; then
            idle_ticks=$((idle_ticks + 1))

            if [ "$progress_value" -lt 10 ] && [ $((idle_ticks % 3)) -eq 0 ]; then
                progress_value=$((progress_value + 1))
                phase_text="Preparing migration..."
                flush_progress_state
            elif [ "$progress_value" -ge 88 ] && [ "$progress_value" -lt 96 ] && [ $((idle_ticks % 4)) -eq 0 ]; then
                progress_value=$((progress_value + 1))
                phase_text="Writing the new deployment..."
                flush_progress_state
            fi
        fi

        sleep 1
    done

    exec 3>&-
    rm -rf "$progress_dir"

    if [ "$cancel_failed" -eq 1 ]; then
        return 131
    fi

    if [ "$user_canceled" -eq 1 ]; then
        return 130
    fi

    return "$cmd_status"
}

show_success_dialog() {
    local image="$1"
    local text
    local rc

    text=$(
        cat <<'EOF'
<span size="xx-large" weight="bold">RakuOS is ready</span>

Your migration has been prepared successfully.
Restart now to boot into RakuOS.

<span weight="bold">Before the first RakuOS boot</span>
1. Disable Secure Boot in BIOS/UEFI

<span weight="bold">After RakuOS starts</span>
2. Run <span font_family="monospace">sudo rakuos enroll-secureboot-key</span>
3. Restart, turn Secure Boot back on, and enroll the new key using password <span font_family="monospace">rakuos</span>
EOF
    )

    yad --center \
        --fixed \
        --width=760 \
        --borders=24 \
        --title="Ready to Restart" \
        --window-icon="$WINDOW_ICON_REBOOT" \
        --image="$image" \
        --image-on-top \
        --text-width=64 \
        --buttons-layout=end \
        --selectable-labels \
        --text-align=left \
        --text="$text" \
        --button="Restart Later":10 \
        --button="Restart Now":0 \
        >/dev/null 2>>"$SCRIPT_LOG"
    rc=$?

    case "$rc" in
        0) return 0 ;;
        *) return 1 ;;
    esac
}

attempt_reboot() {
    if systemctl reboot >/dev/null 2>&1; then
        return 0
    fi

    if command -v pkexec >/dev/null 2>&1; then
        pkexec --disable-internal-agent /usr/bin/systemctl reboot >/dev/null 2>&1 && return 0
    fi

    return 1
}

show_reboot_failure() {
    yad --center \
        --fixed \
        --width=520 \
        --borders=22 \
        --title="Restart Required" \
        --window-icon="$WINDOW_ICON_WARN" \
        --image="dialog-warning" \
        --image-on-top \
        --text-width=50 \
        --buttons-layout=end \
        --text-align=left \
        --button="Close":0 \
        --text="RakuOS is ready, but an automatic restart couldn't be started.\n\nPlease restart your system manually when you're ready." \
        >/dev/null 2>>"$SCRIPT_LOG"
}

main() {
    local dialog_image
    local recommended_variant
    local selected_variant
    local selected_ref
    local selected_label
    local rebase_status
    local main_rc
    local variant_rc

    command -v yad >/dev/null 2>&1 || skip "yad is not available"
    command -v rpm-ostree >/dev/null 2>&1 || skip "rpm-ostree is not available"
    have_gui_session || skip "no GUI session detected"
    [ -e /run/ostree-booted ] || skip "system is not ostree-booted"

    load_os_release || skip "could not read os-release"
    is_origami_system || skip "system does not look like Origami (ID=${ID:-}, ID_LIKE=${ID_LIKE:-}, NAME=${NAME:-})"

    cleanup_boot_marker

    migration_already_completed_this_boot && skip "migration already completed during this boot"
    staged_rakuos_deployment_exists && skip "RakuOS deployment already staged"
    should_prompt_now || skip "remind timer is still active"

    fetch_logo
    dialog_image="$(get_dialog_image)"

    while true; do
        migration_already_completed_this_boot && skip "migration already completed during this boot"
        staged_rakuos_deployment_exists && skip "RakuOS deployment already staged"

        recommended_variant="$(detect_variant)"

        show_main_dialog "$dialog_image"
        main_rc=$?

        case "$main_rc" in
            0)
                ;;
            1|2)
                exit 0
                ;;
            *)
                log "Stopping because the main dialog did not launch cleanly"
                exit 0
                ;;
        esac

        selected_variant="$(choose_variant "$recommended_variant" "$dialog_image")"
        variant_rc=$?

        case "$variant_rc" in
            0)
                ;;
            1)
                continue
                ;;
            *)
                log "Stopping because the variant dialog did not launch cleanly"
                exit 0
                ;;
        esac

        case "$selected_variant" in
            nvidia)
                selected_ref="$NVIDIA_REF"
                selected_label="RakuOS NVIDIA image"
                ;;
            *)
                selected_variant="standard"
                selected_ref="$STANDARD_REF"
                selected_label="RakuOS standard image"
                ;;
        esac

        run_rebase "$selected_ref" "$selected_label"
        rebase_status=$?

        case "$rebase_status" in
            0)
                clear_remind_later
                record_success_this_boot
                log "Migration completed successfully"

                if show_success_dialog "$dialog_image"; then
                    if ! attempt_reboot; then
                        show_reboot_failure
                    fi
                fi
                exit 0
                ;;
            130)
                log "Migration canceled by user; returning to main window"
                continue
                ;;
            131)
                log "Migration cancel request did not stop cleanly"
                show_dialog_with_optional_log \
                    "Still Stopping" \
                    "$WINDOW_ICON_WARN" \
                    "A cancel request was sent, but the migration is still stopping.\n\nPlease wait a moment, then review the log before trying again." \
                    "$LAST_ATTEMPT_LOG" \
                    "dialog-warning"
                exit 0
                ;;
            *)
                log "Migration failed with exit code $rebase_status"
                show_dialog_with_optional_log \
                    "Migration Couldn't Finish" \
                    "$WINDOW_ICON_ERROR" \
                    "Origami Linux wasn't migrated to RakuOS.\n\nYou can review the log and try again later." \
                    "$LAST_ATTEMPT_LOG" \
                    "dialog-error"
                exit 0
                ;;
        esac
    done
}

main "$@"
