#!/bin/sh
set -eu

log() { printf '[custom-kernel] %s\n' "$*"; }
err() { printf '[custom-kernel] Error: %s\n' "$*" >&2; }

log "Starting custom-kernel module..."

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KERNEL_TYPE=$(printf '%s' "$1" | jq -r '.kernel // "cachyos-lto"')
INITRAMFS=$(printf '%s' "$1"   | jq -r '.initramfs // false')
NVIDIA=$(printf '%s' "$1"      | jq -r '.nvidia // false')
SIGNING_KEY=$(printf '%s' "$1" | jq -r '.sign.key // ""')
SIGNING_CERT=$(printf '%s' "$1"| jq -r '.sign.cert // ""')
MOK_PASSWORD=$(printf '%s' "$1"| jq -r '.sign["mok-password"] // ""')
SECURE_BOOT=false

if [ -z "${SIGNING_KEY}" ] && [ -z "${SIGNING_CERT}" ] && [ -z "${MOK_PASSWORD}" ]; then
    log "SecureBoot signing disabled."
elif [ -f "${SIGNING_KEY}" ] && [ -f "${SIGNING_CERT}" ] && [ -n "${MOK_PASSWORD}" ]; then
    SECURE_BOOT=true
    log "SecureBoot signing enabled."
else
    err "Invalid signing config:"
    err "  sign.key:          ${SIGNING_KEY:-<empty>}"
    err "  sign.cert:         ${SIGNING_CERT:-<empty>}"
    err "  sign.mok-password: ${MOK_PASSWORD:-<empty>}"
    exit 1
fi

if [ "${SECURE_BOOT}" = "true" ]; then
    openssl pkey -in "${SIGNING_KEY}"  -noout >/dev/null 2>&1 \
        || { err "sign.key is not a valid private key"; exit 1; }
    openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
        || { err "sign.cert is not a valid X509 cert"; exit 1; }
    _tmp1=$(mktemp); _tmp2=$(mktemp)
    openssl pkey -in "${SIGNING_KEY}"  -pubout        >"${_tmp1}"
    openssl x509 -in "${SIGNING_CERT}" -pubkey -noout >"${_tmp2}"
    if ! cmp -s "${_tmp1}" "${_tmp2}" >/dev/null 2>&1; then
        rm -f "${_tmp1}" "${_tmp2}"
        err "sign.key and sign.cert do not match"
        exit 1
    fi
    rm -f "${_tmp1}" "${_tmp2}"
fi

# ---------------------------------------------------------------------------
# Kernel package resolution
# ---------------------------------------------------------------------------

# TRANSIENT: space-separated build-only packages removed from the image after signing.
TRANSIENT="akmods"

case "${KERNEL_TYPE}" in
cachyos-lto)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    KERNEL_PKG="kernel-cachyos-lto"
    KERNEL_DEVEL_PKG="kernel-cachyos-lto-devel-matched"
    KERNEL_PACKAGES="kernel-cachyos-lto kernel-cachyos-lto-core kernel-cachyos-lto-modules kernel-cachyos-lto-devel-matched"
    ;;
cachyos-lts-lto)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    KERNEL_PKG="kernel-cachyos-lts-lto"
    KERNEL_DEVEL_PKG="kernel-cachyos-lts-lto-devel-matched"
    KERNEL_PACKAGES="kernel-cachyos-lts-lto kernel-cachyos-lts-lto-core kernel-cachyos-lts-lto-modules kernel-cachyos-lts-lto-devel-matched"
    ;;
cachyos)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PKG="kernel-cachyos"
    KERNEL_DEVEL_PKG="kernel-cachyos-devel-matched"
    KERNEL_PACKAGES="kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel-cachyos-devel-matched"
    ;;
cachyos-rt)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PKG="kernel-cachyos-rt"
    KERNEL_DEVEL_PKG="kernel-cachyos-rt-devel-matched"
    KERNEL_PACKAGES="kernel-cachyos-rt kernel-cachyos-rt-core kernel-cachyos-rt-modules kernel-cachyos-rt-devel-matched"
    ;;
cachyos-lts)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PKG="kernel-cachyos-lts"
    KERNEL_DEVEL_PKG="kernel-cachyos-lts-devel-matched"
    KERNEL_PACKAGES="kernel-cachyos-lts kernel-cachyos-lts-core kernel-cachyos-lts-modules kernel-cachyos-lts-devel-matched"
    ;;
*)
    err "Unsupported kernel type: ${KERNEL_TYPE}"
    exit 1
    ;;
esac

# devel-matched provides sign-file and kernel headers; build-time only.
TRANSIENT="${TRANSIENT} ${KERNEL_DEVEL_PKG}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

disable_kernel_install_hooks() {
    for _f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${_f}" ] || continue
        mv "${_f}" "${_f}.bak"
        printf '#!/bin/sh\nexit 0\n' >"${_f}"
        chmod +x "${_f}"
    done
}

restore_kernel_install_hooks() {
    for _f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${_f}.bak" ] && mv -f "${_f}.bak" "${_f}"
    done
}

disable_akmodsbuild() {
    _ak="/usr/sbin/akmodsbuild"
    [ -f "${_ak}" ] || { err "akmodsbuild not found: ${_ak}"; return 1; }
    cp -p "${_ak}" "${_ak}.backup" || return 1
    sed '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${_ak}" > "${_ak}.tmp" && mv "${_ak}.tmp" "${_ak}" || return 1
    chmod +x "${_ak}"
}

restore_akmodsbuild() {
    [ -f /usr/sbin/akmodsbuild.backup ] \
        && mv -f /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
}

sign_kernel() {
    _vmlinuz="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    [ -f "${_vmlinuz}" ] || { err "Kernel image not found: ${_vmlinuz}"; return 1; }
    _tmp=$(mktemp)
    sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${_tmp}" "${_vmlinuz}"
    if ! sbverify --cert "${SIGNING_CERT}" "${_tmp}"; then
        err "Kernel signature verification failed"
        rm -f "${_tmp}"
        return 1
    fi
    cp "${_tmp}" "${_vmlinuz}"
    chmod 0644 "${_vmlinuz}"
    rm -f "${_tmp}"
    sha256sum "${_vmlinuz}" >/tmp/vmlinuz.sha
}

sign_kernel_modules() {
    _module_root="/usr/lib/modules/${KERNEL_VERSION}"
    _sign_file="${_module_root}/build/scripts/sign-file"
    [ -x "${_sign_file}" ] \
        || { err "sign-file not found or not executable: ${_sign_file}"; return 1; }
    _tmplist=$(mktemp)
    find "${_module_root}" -type f \( \
        -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \
    \) >"${_tmplist}"
    while IFS= read -r _mod; do
        case "${_mod}" in
        *.ko)
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_mod}" \
                || { rm -f "${_tmplist}"; return 1; }
            ;;
        *.ko.xz)
            _raw="${_mod%.xz}"
            xz -d -q "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            xz -z -q "${_raw}"
            ;;
        *.ko.zst)
            _raw="${_mod%.zst}"
            zstd -d -q --rm "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            zstd -q "${_raw}"
            ;;
        *.ko.gz)
            _raw="${_mod%.gz}"
            gunzip -q "${_mod}"
            "${_sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${_raw}" \
                || { rm -f "${_tmplist}"; return 1; }
            gzip -q "${_raw}"
            ;;
        esac
    done <"${_tmplist}"
    rm -f "${_tmplist}"
}

create_mok_enroll_unit() {
    _mok_cert="/usr/share/cert/MOK.der"
    _unit_file="/usr/lib/systemd/system/mok-enroll.service"
    _tmp=$(mktemp)
    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${_tmp}" \
        || { rm -f "${_tmp}"; return 1; }
    mkdir -p "$(dirname "${_mok_cert}")"
    cp "${_tmp}" "${_mok_cert}"
    chmod 0644 "${_mok_cert}"
    rm -f "${_tmp}"
    mkdir -p "$(dirname "${_unit_file}")"
    cat <<EOF > "${_unit_file}"
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${_mok_cert}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${_mok_cert}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${_unit_file}"
    systemctl -f enable mok-enroll.service
    log "Created and enabled mok-enroll.service"
}

# ---------------------------------------------------------------------------
# Install kernel
# ---------------------------------------------------------------------------

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

log "Installing kernel packages: ${KERNEL_PACKAGES}"
# SC2086: intentional word-splitting on space-separated package list
# shellcheck disable=SC2086
dnf -y install $KERNEL_PACKAGES akmods

KERNEL_VERSION=$(rpm -q "${KERNEL_PKG}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') || exit 1
log "Kernel version: ${KERNEL_VERSION}"

log "Restoring kernel install scripts."
restore_kernel_install_hooks

log "Cleaning up COPR repos."
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# Build v4l2loopback
# ---------------------------------------------------------------------------

log "Building v4l2loopback module."
disable_akmodsbuild || exit 1

log "Enabling RPM Fusion Free repo."
dnf -y install \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"

dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
    akmod-v4l2loopback
TRANSIENT="${TRANSIENT} akmod-v4l2loopback"

akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod v4l2loopback

# akmods always exits 0, so check for failure logs explicitly.
_fail_found=false
for _f in /var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log; do
    [ -f "${_f}" ] && _fail_found=true && break
done
if [ "${_fail_found}" = "true" ]; then
    err "v4l2loopback akmod build failed:"
    for _f in /var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log; do
        [ -f "${_f}" ] && cat "${_f}"
    done
    restore_akmodsbuild
    exit 1
fi

log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

restore_akmodsbuild

# ---------------------------------------------------------------------------
# Build Nvidia modules (optional)
# ---------------------------------------------------------------------------

if [ "${NVIDIA}" = "true" ]; then
    log "Enabling Nvidia repositories."
    curl -fsSL --retry 5 --create-dirs \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    curl -fsSL --retry 5 --create-dirs \
        https://negativo17.org/repos/fedora-nvidia.repo \
        -o /etc/yum.repos.d/fedora-nvidia.repo

    log "Building Nvidia kernel modules."
    disable_akmodsbuild || exit 1

    dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
        akmod-nvidia \
        nvidia-kmod-common \
        nvidia-modprobe \
        gcc-c++
    TRANSIENT="${TRANSIENT} akmod-nvidia gcc-c++"

    akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod nvidia

    # akmods always exits 0, so check for failure logs explicitly.
    _fail_found=false
    for _f in /var/cache/akmods/nvidia/*-for-"${KERNEL_VERSION}".failed.log; do
        [ -f "${_f}" ] && _fail_found=true && break
    done
    if [ "${_fail_found}" = "true" ]; then
        err "Nvidia akmod build failed:"
        for _f in /var/cache/akmods/nvidia/*-for-"${KERNEL_VERSION}".failed.log; do
            [ -f "${_f}" ] && cat "${_f}"
        done
        exit 1
    fi

    restore_akmodsbuild

    log "Installing Nvidia userspace packages."
    dnf install -y --setopt=skip_unavailable=1 \
        libva-nvidia-driver \
        nvidia-driver \
        nvidia-persistenced \
        nvidia-settings \
        nvidia-driver-cuda \
        libnvidia-cfg \
        libnvidia-fbc \
        libnvidia-ml \
        libnvidia-gpucomp \
        nvidia-driver-libs.i686 \
        nvidia-driver-cuda-libs.i686 \
        libnvidia-fbc.i686 \
        libnvidia-ml.i686 \
        libnvidia-gpucomp.i686 \
        nvidia-container-toolkit

    log "Cleaning Nvidia repositories."
    rm -f /etc/yum.repos.d/*nvidia*

    log "Installing Nvidia SELinux policy."
    curl -fsSL --retry 5 --create-dirs \
        https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/bin/RHEL9/nvidia-container.pp \
        -o nvidia-container.pp
    semodule -i nvidia-container.pp
    rm -f nvidia-container.pp

    log "Installing Nvidia container toolkit service and preset."
    mkdir -p /usr/lib/systemd/system
    cat <<'EOF' > /usr/lib/systemd/system/nvctk-cdi.service
[Unit]
Description=NVIDIA Container Toolkit CDI auto-generation
ConditionFileIsExecutable=/usr/bin/nvidia-ctk
ConditionPathExists=!/etc/cdi/nvidia.yaml
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /usr/lib/systemd/system/nvctk-cdi.service

    mkdir -p /usr/lib/systemd/system-preset
    cat <<'EOF' > /usr/lib/systemd/system-preset/70-nvctk-cdi.preset
enable nvctk-cdi.service
EOF
    chmod 0644 /usr/lib/systemd/system-preset/70-nvctk-cdi.preset

    mkdir -p /etc/modprobe.d
    cat <<'EOF' > /etc/modprobe.d/nvidia.conf
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
EOF
    chmod 0644 /etc/modprobe.d/nvidia.conf

    mkdir -p /usr/lib/dracut/dracut.conf.d
    cat <<'EOF' > /usr/lib/dracut/dracut.conf.d/99-nvidia.conf
# Force the i915 amdgpu nvidia drivers to the ramdisk
force_drivers+=" i915 amdgpu nvidia nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm "
EOF
    chmod 0644 /usr/lib/dracut/dracut.conf.d/99-nvidia.conf

    mkdir -p /usr/lib/bootc/kargs.d
    cat <<'EOF' > /usr/lib/bootc/kargs.d/90-nvidia.toml
kargs = [
"rd.driver.blacklist=nouveau",
"modprobe.blacklist=nouveau",
"rd.driver.pre=nvidia",
"nvidia-drm.modeset=1",
"nvidia-drm.fbdev=1"
]
EOF
    chmod 0644 /usr/lib/bootc/kargs.d/90-nvidia.toml
fi

# ---------------------------------------------------------------------------
# SecureBoot signing
# ---------------------------------------------------------------------------

if [ "${SECURE_BOOT}" = "true" ]; then
    log "Signing the kernel."
    sign_kernel || exit 1

    log "Signing kernel modules."
    sign_kernel_modules || exit 1

    log "Creating MOK enroll unit."
    create_mok_enroll_unit || exit 1
fi

# ---------------------------------------------------------------------------
# Remove transient build packages
# sign-file (inside *-devel-matched) is no longer needed past this point.
# ---------------------------------------------------------------------------

log "Removing transient build packages: ${TRANSIENT}"
# SC2086: intentional word-splitting on space-separated package list
# shellcheck disable=SC2086
dnf -y remove $TRANSIENT || true

# Safety-net: remove any remaining akmod-* or *-devel-matched packages.
_residual=$(rpm -qa --queryformat '%{NAME}\n' | grep -E '^akmod-|(-devel-matched)$' || true)
if [ -n "${_residual}" ]; then
    log "Removing residual build packages: ${_residual}"
    # shellcheck disable=SC2086
    dnf -y remove $_residual || true
fi

# Nuke kernel build trees (belt-and-suspenders after devel-matched removal).
log "Removing kernel build trees."
rm -rf /usr/lib/modules/*/build /usr/lib/modules/*/source

log "Removing akmods build artefacts."
rm -rf /var/cache/akmods

log "Cleaning DNF caches."
dnf -y clean all || true
rm -rf /var/cache/dnf/* /var/tmp/dnf-* || true

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------

if [ "${INITRAMFS}" = "true" ]; then
    log "Generating initramfs."
    _tmp=$(mktemp)
    DRACUT_NO_XATTR=1 /usr/bin/dracut \
        --no-hostonly \
        --kver "${KERNEL_VERSION}" \
        --reproducible \
        --add ostree \
        -f "${_tmp}" \
        -v || exit 1
    mkdir -p "/usr/lib/modules/${KERNEL_VERSION}"
    cp "${_tmp}" "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
    chmod 0600 "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
    rm -f "${_tmp}"
fi

# ---------------------------------------------------------------------------
# Final integrity checks
# ---------------------------------------------------------------------------

if [ "${SECURE_BOOT}" = "true" ]; then
    sha256sum -c /tmp/vmlinuz.sha || { err "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Integrity check passed."
fi

if [ "${NVIDIA}" = "true" ]; then
    _nvidia_dir="/usr/lib/modules/${KERNEL_VERSION}/extra/nvidia"
    [ -d "${_nvidia_dir}" ] \
        || { err "Missing Nvidia module directory: ${_nvidia_dir}"; exit 1; }
    for _name in nvidia nvidia-drm nvidia-modeset nvidia-peermem nvidia-uvm; do
        if ! ls "${_nvidia_dir}/${_name}".* >/dev/null 2>&1; then
            err "Missing Nvidia module: ${_nvidia_dir}/${_name}.*"
            exit 1
        fi
    done
    log "All Nvidia modules present."
fi

log "Custom kernel installation complete."
