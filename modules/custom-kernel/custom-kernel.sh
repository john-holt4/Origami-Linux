#!/usr/bin/env bash
set -euo pipefail

log() {
    local PREFIX="[custom-kernel]"
    echo -e "${PREFIX} $*"
}

error() {
    local PREFIX="[custom-kernel] Error:"
    echo -e "${PREFIX} $*"
}

log "Starting custom-kernel module..."

# Read configuration
KERNEL_TYPE=$(echo "$1" | jq -r '.kernel // "cachyos-lto"')
INITRAMFS=$(echo "$1" | jq -r '.initramfs // false')
NVIDIA=$(echo "$1" | jq -r '.nvidia // false')
SIGNING_KEY=$(echo "$1" | jq -r '.sign.key // ""')
SIGNING_CERT=$(echo "$1" | jq -r '.sign.cert // ""')
MOK_PASSWORD=$(echo "$1" | jq -r '.sign["mok-password"] // ""')
SECURE_BOOT=false

# Validating signing config
if [[ -z "${SIGNING_KEY}" && -z "${SIGNING_CERT}" && -z "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing disabled."
elif [[ -f "${SIGNING_KEY}" && -f "${SIGNING_CERT}" && -n "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing enabled."
    SECURE_BOOT=true
else
    error "Invalid signing config."
    exit 1
fi

# Double check keys and certs
if [[ ${SECURE_BOOT} == true ]]; then
    openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 || { error "Invalid private key"; exit 1; }
    openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 || { error "Invalid X509 cert"; exit 1; }
fi

# Resolve kernel and COPR settings
case "${KERNEL_TYPE}" in
cachyos-lto | cachyos-lts-lto)
    COPR_REPOS=("bieszczaders/kernel-cachyos-lto")
    BASE="cachyos-lto"
    ;;
cachyos | cachyos-rt | cachyos-lts)
    COPR_REPOS=("bieszczaders/kernel-cachyos")
    BASE="cachyos"
    ;;
*)
    error "Unsupported kernel type: ${KERNEL_TYPE}"
    exit 1
    ;;
esac

# Build package list dynamically
KERNEL_PACKAGES=(
    "kernel-${BASE}"
    "kernel-${BASE}-core"
    "kernel-${BASE}-modules"
    "kernel-${BASE}-devel-matched"
)

# Helper functions for hooks
disable_kernel_install_hooks() {
    for f in /usr/lib/kernel/install.d/05-rpmostree.install /usr/lib/kernel/install.d/50-dracut.install; do
        [[ -f "$f" ]] && { mv "$f" "$f.bak"; printf '%s\n' '#!/bin/sh' 'exit 0' >"$f"; chmod +x "$f"; }
    done
}

restore_kernel_install_hooks() {
    for f in /usr/lib/kernel/install.d/05-rpmostree.install /usr/lib/kernel/install.d/50-dracut.install; do
        [[ -f "$f.bak" ]] && mv -f "$f.bak" "$f"
    done
}

# 1. Install Kernel
log "Removing default kernel packages."
disable_kernel_install_hooks
dnf -y remove kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

for repo in "${COPR_REPOS[@]}"; do
    dnf -y copr enable "${repo}"
done

log "Installing kernel packages..."
dnf -y install "${KERNEL_PACKAGES[@]}" akmods

KERNEL_VERSION="$(rpm -q "${KERNEL_PACKAGES[1]}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
log "Detected kernel version: ${KERNEL_VERSION}"

# 2. NVIDIA Implementation
if [[ ${NVIDIA} == true ]]; then
    log "Configuring NVIDIA Drivers..."

    # Enable essential repos for userspace drivers
    dnf -y copr enable bieszczaders/kernel-cachyos-addons
    curl -fsSL https://negativo17.org/repos/fedora-nvidia.repo -o /etc/yum.repos.d/fedora-nvidia.repo

    # Patch akmods for root build
    sed -i.backup '/if \[\[ -w \/var \]\] ; then/,/fi/d' /usr/sbin/akmodsbuild

    log "Installing NVIDIA userspace and kernel modules..."
    # We install the open-source kernel module AND the userspace driver libraries
    dnf install -y --setopt=install_weak_deps=False \
        "kernel-${BASE}-nvidia-open" \
        nvidia-driver \
        nvidia-driver-libs \
        nvidia-driver-libs.i686 \
        nvidia-settings \
        nvidia-kmod-common \
        nvidia-container-toolkit \
        libva-nvidia-driver

    log "Building NVIDIA kmod via akmods..."
    akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod "nvidia"

    # Set persistent Kernel Arguments for NVIDIA
    log "Injecting NVIDIA kernel arguments..."
    mkdir -p /usr/lib/bootc/kargs.d
    cat <<EOF > /usr/lib/bootc/kargs.d/90-nvidia.toml
kargs = [
    "rd.driver.blacklist=nouveau",
    "modprobe.blacklist=nouveau",
    "rd.driver.pre=nvidia",
    "nvidia-drm.modeset=1",
    "nvidia-drm.fbdev=1"
]
EOF

    # Modprobe config to ensure nouveau doesn't load
    mkdir -p /etc/modprobe.d
    echo "blacklist nouveau" > /etc/modprobe.d/nvidia.conf
    echo "options nvidia-drm modeset=1 fbdev=1" >> /etc/modprobe.d/nvidia.conf

    # Restore akmodsbuild
    [[ -f /usr/sbin/akmodsbuild.backup ]] && mv -f /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
fi

# 3. Signing Logic
if [[ ${SECURE_BOOT} == true ]]; then
    log "Signing Kernel and Modules..."

    # Kernel signing
    VMLINUZ="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    TMP_VMLINUZ=$(mktemp)
    sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${TMP_VMLINUZ}" "${VMLINUZ}"
    install -m 0644 "${TMP_VMLINUZ}" "${VMLINUZ}"
    rm -f "${TMP_VMLINUZ}"

    # Modules signing
    SIGN_FILE="/usr/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file"
    find "/usr/lib/modules/${KERNEL_VERSION}" -type f -name "*.ko*" | while read -r mod; do
        case "${mod}" in
            *.ko)   "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" ;;
            *.ko.xz) xz -d "$mod"; "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod%.xz}"; xz -z "${mod%.xz}" ;;
            *.ko.zst) zstd -d --rm "$mod"; "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod%.zst}"; zstd -q --rm "${mod%.zst}" ;;
        esac
    done

    # MOK Enrollment Service
    MOK_CERT="/usr/share/cert/MOK.der"
    mkdir -p /usr/share/cert
    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${MOK_CERT}"

    cat <<EOF > /usr/lib/systemd/system/mok-enroll.service
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
    systemctl enable mok-enroll.service
fi

# 4. Finalizing
log "Generating initramfs..."
DRACUT_NO_XATTR=1 /usr/bin/dracut --no-hostonly --kver "${KERNEL_VERSION}" --reproducible --add ostree -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"

log "Restoring hooks and cleaning up..."
restore_kernel_install_hooks
dnf -y remove "kernel-${BASE}-devel-matched" # Remove heavy headers but keep akmods
rm -f /etc/yum.repos.d/*copr*

log "Installation complete."
