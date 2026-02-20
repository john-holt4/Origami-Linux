#!/usr/bin/env bash
set -euo pipefail

log()   { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*" >&2; }

log "Starting custom-kernel module..."

# Parse configuration (single jq call)
IFS=$'\t' read -r KERNEL_TYPE INITRAMFS SIGNING_KEY SIGNING_CERT MOK_PASSWORD < <(
    printf '%s' "$1" | jq -r '[
        .kernel // "cachyos-lto",
        (.initramfs // false | tostring),
        (.sign.key // ""),
        (.sign.cert // ""),
        (.sign["mok-password"] // "")
    ] | @tsv')
SECURE_BOOT=false

# Validate signing config
if [[ -z "${SIGNING_KEY}" && -z "${SIGNING_CERT}" && -z "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing disabled."
elif [[ -f "${SIGNING_KEY}" && -f "${SIGNING_CERT}" && -n "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing enabled."
    SECURE_BOOT=true
else
    error "Invalid signing config:"
    error "  sign.key:          ${SIGNING_KEY:-<empty>}"
    error "  sign.cert:         ${SIGNING_CERT:-<empty>}"
    error "  sign.mok-password: ${MOK_PASSWORD:-<empty>}"
    exit 1
fi

# Validate key and cert
if [[ ${SECURE_BOOT} == true ]]; then
    openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 \
        || { error "sign.key is not a valid private key"; exit 1; }

    openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
        || { error "sign.cert is not a valid X509 cert"; exit 1; }

    diff -q \
        <(openssl pkey -in "${SIGNING_KEY}" -pubout) \
        <(openssl x509 -in "${SIGNING_CERT}" -pubkey -noout) >/dev/null \
        || { error "sign.key and sign.cert do not match"; exit 1; }
fi

# Resolve kernel packages and COPR repo.
# Kernel package names are perfectly consistent: kernel-{type}, kernel-{type}-core, etc.
# Strip the -nvidia suffix if present and handle it as an add-on.
NVIDIA=false
if [[ "${KERNEL_TYPE}" == *-nvidia ]]; then
    NVIDIA=true
    BASE_TYPE="${KERNEL_TYPE%-nvidia}"
else
    BASE_TYPE="${KERNEL_TYPE}"
fi

case "${BASE_TYPE}" in
    cachyos-lto|cachyos-lts-lto)
        COPR_REPO="bieszczaders/kernel-cachyos-lto"
        ;;
    cachyos|cachyos-rt|cachyos-lts)
        COPR_REPO="bieszczaders/kernel-cachyos"
        ;;
    *)
        error "Unsupported kernel type: ${KERNEL_TYPE}"
        exit 1
        ;;
esac

KERNEL_PACKAGES=(
    "kernel-${BASE_TYPE}"
    "kernel-${BASE_TYPE}-core"
    "kernel-${BASE_TYPE}-modules"
    "kernel-${BASE_TYPE}-devel-matched"
)
[[ "${NVIDIA}" == true ]] && KERNEL_PACKAGES+=("kernel-${BASE_TYPE}-nvidia-open")

# Kernel install hook helpers
_KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)

disable_kernel_install_hooks() {
    for f in "${_KERNEL_HOOKS[@]}"; do
        [[ -f "${f}" ]] || continue
        mv "${f}" "${f}.bak"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"${f}"
        chmod +x "${f}"
    done
}

restore_kernel_install_hooks() {
    for f in "${_KERNEL_HOOKS[@]}"; do
        [[ -f "${f}.bak" ]] && mv -f "${f}.bak" "${f}"
    done
}

# Install custom kernel
log "Temporarily disabling kernel install scripts."
disable_kernel_install_hooks

log "Removing default kernel packages."
dnf -y remove \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

log "Enabling COPR repo: ${COPR_REPO}"
dnf -y copr enable "${COPR_REPO}"

log "Installing kernel packages: ${KERNEL_PACKAGES[*]}"
dnf -y install "${KERNEL_PACKAGES[@]}" akmods

KERNEL_VERSION="$(rpm -q "${KERNEL_PACKAGES[0]}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" || exit 1
log "Detected kernel version: ${KERNEL_VERSION}"

log "Restoring kernel install scripts."
restore_kernel_install_hooks

log "Cleaning up COPR repos."
rm -f /etc/yum.repos.d/*copr*

# akmodsbuild helpers
disable_akmodsbuild() {
    local AK="/usr/sbin/akmodsbuild"

    if [[ ! -f "${AK}" ]]; then
        error "akmodsbuild not found: ${AK}"
        return 1
    fi

    cp -a "${AK}" "${AK}.backup" || return 1
    sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${AK}" || return 1
}

restore_akmodsbuild() {
    local AK="/usr/sbin/akmodsbuild"
    [[ -f "${AK}.backup" ]] && mv -f "${AK}.backup" "${AK}"
}

# Build and install v4l2loopback
log "Temporarily disabling akmodsbuild for v4l2loopback."
disable_akmodsbuild || exit 1

log "Enabling RPM Fusion Free repo for v4l2loopback."
dnf -y install \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"

log "Building and installing v4l2loopback kernel module."
dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts akmod-v4l2loopback
akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod "v4l2loopback"

shopt -s nullglob
FAIL_LOGS=( /var/cache/akmods/v4l2loopback/*-for-${KERNEL_VERSION}.failed.log )
shopt -u nullglob

if (( ${#FAIL_LOGS[@]} )); then
    error "v4l2loopback akmod build failed"
    for f in "${FAIL_LOGS[@]}"; do
        cat "${f}" || log "Failed to read ${f}"
        log "--------------"
    done
    restore_akmodsbuild
    exit 1
fi

log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

log "Restoring akmodsbuild."
restore_akmodsbuild

# Sign kernel and modules for SecureBoot
sign_kernel() {
    local VMLINUZ="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    local SIGNED_VMLINUZ

    [[ -f "${VMLINUZ}" ]] || { error "Kernel image not found: ${VMLINUZ}"; return 1; }

    log "Kernel image: ${VMLINUZ}"
    SIGNED_VMLINUZ="$(mktemp)"

    sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${SIGNED_VMLINUZ}" "${VMLINUZ}"

    if ! sbverify --cert "${SIGNING_CERT}" "${SIGNED_VMLINUZ}"; then
        error "Kernel signature verification failed"
        rm -f "${SIGNED_VMLINUZ}"
        return 1
    fi

    log "Verification successful. Installing signed kernel."
    install -m 0644 "${SIGNED_VMLINUZ}" "${VMLINUZ}"
    rm -f "${SIGNED_VMLINUZ}"

    sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha
}

sign_kernel_modules() {
    local MODULE_ROOT="/usr/lib/modules/${KERNEL_VERSION}"
    local SIGN_FILE="${MODULE_ROOT}/build/scripts/sign-file"

    [[ -x "${SIGN_FILE}" ]] || { error "sign-file not found or not executable: ${SIGN_FILE}"; return 1; }

    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko)
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" || return 1
            ;;
        *.ko.xz)
            xz -d -q "${mod}"
            raw="${mod%.xz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            xz -z -q "${raw}"
            ;;
        *.ko.zst)
            zstd -d -q --rm "${mod}"
            raw="${mod%.zst}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            zstd -q "${raw}"
            ;;
        *.ko.gz)
            gunzip -q "${mod}"
            raw="${mod%.gz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            gzip -q "${raw}"
            ;;
        esac
    done < <(find "${MODULE_ROOT}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)
}

create_mok_enroll_unit() {
    local UNIT_NAME="mok-enroll.service"
    local UNIT_FILE="/usr/lib/systemd/system/${UNIT_NAME}"
    local MOK_CERT="/usr/share/cert/MOK.der"
    local TMP_DER

    TMP_DER="$(mktemp)"
    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${TMP_DER}" || { rm -f "${TMP_DER}"; return 1; }
    install -D -m 0644 "${TMP_DER}" "${MOK_CERT}"
    rm -f "${TMP_DER}"

    install -D -m 0644 /dev/stdin "${UNIT_FILE}" <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${MOK_CERT}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${MOK_CERT}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl -f enable "${UNIT_NAME}"
    log "Created and enabled ${UNIT_NAME}"
}

if [[ ${SECURE_BOOT} == true ]]; then
    log "Signing the kernel."
    sign_kernel || exit 1

    log "Signing kernel modules."
    sign_kernel_modules || exit 1

    log "Creating MOK enroll unit for first boot."
    create_mok_enroll_unit || exit 1
fi

# Generate initramfs
if [[ ${INITRAMFS} == true ]]; then
    log "Generating initramfs."
    TMP_INITRAMFS="$(mktemp)"
    DRACUT_NO_XATTR=1 /usr/bin/dracut \
        --no-hostonly \
        --kver "${KERNEL_VERSION}" \
        --reproducible \
        --add ostree \
        -f "${TMP_INITRAMFS}" \
        -v || return 1
    install -D -m 0600 "${TMP_INITRAMFS}" "/lib/modules/${KERNEL_VERSION}/initramfs.img"
    rm -f "${TMP_INITRAMFS}"
fi

# Final integrity check
if [[ ${SECURE_BOOT} == true ]]; then
    sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Kernel integrity check passed."
fi

log "Custom kernel installation complete."
