#!/usr/bin/env bash
set -euo pipefail

# Fast logging
log() { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*" >&2; }

# Configuration
readonly AKMODSBUILD="/usr/sbin/akmodsbuild"
readonly KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)
readonly MODULE_ROOT="/usr/lib/modules"

# State tracking
TRANSIENT_PKGS=()
PATCHED_FILES=()

# --- Cleanup & Traps ---
cleanup() {
    local rc=$?
    for f in "${PATCHED_FILES[@]}"; do
        [[ -f "${f}.bak" ]] && mv -f "${f}.bak" "$f"
    done
    if (( ${#TRANSIENT_PKGS[@]} )); then
        log "Cleaning up build dependencies: ${TRANSIENT_PKGS[*]}"
        dnf -y remove "${TRANSIENT_PKGS[@]}" &>/dev/null || true
    fi
    log "Cleaning DNF caches..."
    dnf -y clean all &>/dev/null || true
    rm -rf /var/cache/dnf/* /var/tmp/dnf-* /var/cache/akmods
    exit "$rc"
}
trap cleanup EXIT

# --- Core Logic ---
disable_hooks() {
    log "Disabling kernel install hooks and patching akmodsbuild..."
    for f in "${KERNEL_HOOKS[@]}"; do
        [[ -f "$f" ]] || continue
        [[ ! -f "${f}.bak" ]] && cp -a "$f" "${f}.bak" && PATCHED_FILES+=("$f")
        printf '#!/bin/sh\nexit 0\n' > "$f"
    done
    if [[ -f "$AKMODSBUILD" ]]; then
        [[ ! -f "${AKMODSBUILD}.bak" ]] && cp -a "$AKMODSBUILD" "${AKMODSBUILD}.bak" && PATCHED_FILES+=("$AKMODSBUILD")
        sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "$AKMODSBUILD"
    fi
}

setup_signing_keys() {
    local key="$1" cert="$2"
    local k_sum c_sum
    k_sum=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum)
    c_sum=$(openssl x509 -in "$cert" -pubkey -noout -outform DER | sha256sum)
    [[ "${k_sum%% *}" == "${c_sum%% *}" ]] || { error "Signing key and certificate do not match!"; return 1; }
}

sign_kernel_artifact() {
    local kver="$1" key="$2" cert="$3"
    local vmlinuz="${MODULE_ROOT}/${kver}/vmlinuz"
    log "Signing kernel image: ${vmlinuz}"
    [[ -f "$vmlinuz" ]] || { error "Kernel image not found: $vmlinuz"; return 1; }
    local signed_vmlinuz
    signed_vmlinuz="$(mktemp)"
    sbsign --key "$key" --cert "$cert" --output "${signed_vmlinuz}" "$vmlinuz"
    sbverify --cert "$cert" "${signed_vmlinuz}" >/dev/null || { error "Kernel signature verification failed"; rm -f "${signed_vmlinuz}"; return 1; }
    install -m 0644 "${signed_vmlinuz}" "$vmlinuz"
    rm -f "${signed_vmlinuz}"
    sha256sum "$vmlinuz" > /tmp/vmlinuz.sha
}

# Exported function for xargs
_sign_one_module() {
    local mod="$1" key="$2" cert="$3" sign_bin="$4"
    local raw="$mod" ext=""
    case "${mod}" in
        *.ko.xz)  xz -d -q "${mod}"; raw="${mod%.xz}"; ext="xz" ;;
        *.ko.zst) zstd -d -q --rm "${mod}"; raw="${mod%.zst}"; ext="zst" ;;
        *.ko.gz)  gunzip -q "${mod}"; raw="${mod%.gz}"; ext="gz" ;;
        *.ko) ;;
        *) return 0 ;;
    esac
    "$sign_bin" sha256 "$key" "$cert" "$raw" || return 1
    case "${ext}" in
        xz)  xz -z -q "${raw}" ;;
        zst) zstd -q --rm "${raw}" ;;
        gz)  gzip -q "${raw}" ;;
    esac
}
export -f _sign_one_module

sign_modules_parallel() {
    local kver="$1" key="$2" cert="$3"
    local sign_bin="${MODULE_ROOT}/${kver}/build/scripts/sign-file"
    [[ -x "$sign_bin" ]] || { error "sign-file not found: $sign_bin"; return 1; }
    log "Signing kernel modules in parallel..."
    find "${MODULE_ROOT}/${kver}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0 \
        | xargs -0 -r -P "$(nproc)" -I{} bash -c '_sign_one_module "$@" ' _ "{}" "$key" "$cert" "$sign_bin"
}

create_mok_unit() {
    local pwd="$1" cert="$2"
    local unit_name="mok-enroll.service"
    local unit_file="/usr/lib/systemd/system/${unit_name}"
    local mok_cert="/usr/share/cert/MOK.der"
    log "Creating MOK enrollment service..."
    mkdir -p "$(dirname "${mok_cert}")"
    openssl x509 -in "${cert}" -outform DER -out "${mok_cert}"
    chmod 0644 "${mok_cert}"
    cat > "${unit_file}" <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${mok_cert}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${pwd}"; echo "${pwd}") | mokutil --import "${mok_cert}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl -f enable "${unit_name}"
}

# --- Main Execution ---
log "Starting custom-kernel module..."

# Parse JSON Config
KERNEL_TYPE=$(echo "$1" | jq -r '.kernel // "cachyos-lto"')
INITRAMFS=$(echo "$1" | jq -r '(.initramfs // false | tostring)')
SIGNING_KEY=$(echo "$1" | jq -r '.sign.key // ""')
SIGNING_CERT=$(echo "$1" | jq -r '.sign.cert // ""')
MOK_PASSWORD=$(echo "$1" | jq -r '.sign["mok-password"] // ""')

# Determine Kernel Flavor & Repos
[[ "${KERNEL_TYPE}" == *-nvidia ]] && NVIDIA=true BASE_TYPE="${KERNEL_TYPE%-nvidia}" || NVIDIA=false BASE_TYPE="${KERNEL_TYPE}"
case "${BASE_TYPE}" in
    cachyos-lto|cachyos-lts-lto) COPR_REPO="bieszczaders/kernel-cachyos-lto" ;;
    cachyos|cachyos-rt|cachyos-lts) COPR_REPO="bieszczaders/kernel-cachyos" ;;
    *) error "Unsupported kernel type: ${KERNEL_TYPE}"; exit 1 ;;
esac

# Prepare Package Lists
REMOVE_PACKAGES=(kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched)
INSTALL_PACKAGES=(
    "kernel-${BASE_TYPE}"
    "kernel-${BASE_TYPE}-core"
    "kernel-${BASE_TYPE}-modules"
    "kernel-${BASE_TYPE}-devel-matched"
    "akmods"
    "kernel-devel"
    "kernel-headers"
    "akmod-v4l2loopback"
)
[[ "${NVIDIA}" == true ]] && INSTALL_PACKAGES+=("kernel-${BASE_TYPE}-nvidia-open")
TRANSIENT_PKGS+=("akmods" "kernel-devel" "kernel-headers" "akmod-v4l2loopback" "rpmfusion-free-release")

# Prepare Environment
disable_hooks

# Consolidated DNF Transaction
log "Executing consolidated DNF transaction (Remove default, Enable repos, Install custom)..."
dnf -y copr enable "${COPR_REPO}"
RPMFUSION_URL="https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
rm -rf /usr/lib/modules/* || true
dnf -y install --allowerasing --setopt=install_weak_deps=False --setopt=tsflags=noscripts "${RPMFUSION_URL}" "${INSTALL_PACKAGES[@]}"

# Detect Installed Version
KERNEL_VERSION="$(rpm -q "kernel-${BASE_TYPE}-core" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
log "Detected installed kernel version: ${KERNEL_VERSION}"

# Build v4l2loopback
log "Building v4l2loopback kernel module..."
if ! akmods --force --kernels "${KERNEL_VERSION}" --kmod v4l2loopback; then
    error "v4l2loopback akmod build failed"
    shopt -s nullglob
    for f in /var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log; do
        log "--- Log: $f ---"
        cat "$f"
    done
    exit 1
fi

# Secure Boot Signing
SECURE_BOOT=false
if [[ -n "${SIGNING_KEY}" && -f "${SIGNING_KEY}" && -n "${SIGNING_CERT}" && -f "${SIGNING_CERT}" ]]; then
    SECURE_BOOT=true
    setup_signing_keys "${SIGNING_KEY}" "${SIGNING_CERT}"
    sign_kernel_artifact "${KERNEL_VERSION}" "${SIGNING_KEY}" "${SIGNING_CERT}"
    sign_modules_parallel "${KERNEL_VERSION}" "${SIGNING_KEY}" "${SIGNING_CERT}"
    [[ -n "${MOK_PASSWORD}" ]] && create_mok_unit "${MOK_PASSWORD}" "${SIGNING_CERT}"
else
    log "SecureBoot signing disabled or invalid config."
fi

# Initramfs Generation
if [[ "${INITRAMFS}" == true ]]; then
    log "Generating initramfs..."
    INITRAMFS_OUT="/lib/modules/${KERNEL_VERSION}/initramfs.img"
    DRACUT_NO_XATTR=1 /usr/bin/dracut --no-hostonly --kver "${KERNEL_VERSION}" --reproducible --add ostree -f "${INITRAMFS_OUT}" -v
    chmod 0600 "${INITRAMFS_OUT}"
fi

# Integrity Check
if [[ "${SECURE_BOOT}" == true ]]; then
    log "Verifying kernel integrity..."
    sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
fi

log "Custom kernel installation complete."
