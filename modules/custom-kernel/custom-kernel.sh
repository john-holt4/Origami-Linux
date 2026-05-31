Switching to the official NVIDIA `.run` payload is a completely valid, brute-force way to bypass the exact multilib dependency hell you just experienced. Because the image you are building is the final immutable artifact, bypassing `dnf` for the driver installation is actually a very viable strategy in this context.

Here is a breakdown of what happens if you adopt this approach, followed by how to integrate it into your specific `custom-kernel.sh`.

### The Pros

* **Bypasses Dependency Hell:** You get the complete 32-bit and 64-bit stack bundled directly from NVIDIA. You will never experience a `dnf` version mismatch again.
* **Always Up to Date:** You dynamically fetch the absolute latest driver directly from NVIDIA's servers rather than waiting for repository maintainers (like Negativo17 or RPMFusion) to package and sync them.
* **Decoupled from Akmods:** You compile the module directly against your kernel source tree using NVIDIA's official installer, skipping the `akmods` abstraction entirely.

### The Cons

* **Untracked Files:** The files installed by the `.run` script are not tracked by RPM. While this is a cardinal sin on traditional Linux setups, it is generally acceptable in container-native OS builds (like Bluefin/Bazzite/OSTree) because the entire image is the package.
* **Container Toolkit is Separate:** The `.run` payload only contains the driver and basic utilities. You still need to configure the NVIDIA repository specifically to install `nvidia-container-toolkit`.
* **Manual Cleanup:** You have to manually install heavy build tools (`gcc`, `make`, `dkms`) and explicitly strip them out afterward to keep your final image size down.

---

### The Integrated Script

I have rewritten the `NVIDIA` section of your `custom-kernel.sh` to use the `.run` payload method from your example, while preserving your existing SecureBoot signing, CachyOS kernel resolution, and Dracut configurations.

I removed the `rakuos`-specific manifest tracking from your example, as `blue-build` handles OSTree layers differently, and I kept your `nvidia-container-toolkit` installation intact.

```bash
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
# shellcheck disable=SC2086
dnf -y install $KERNEL_PACKAGES akmods

KERNEL_VERSION=$(rpm -q "${KERNEL_PKG}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1) || exit 1
log "Kernel version: ${KERNEL_VERSION}"
KERNEL_SOURCE="/usr/src/kernels/${KERNEL_VERSION}"

log "Restoring kernel install scripts."
restore_kernel_install_hooks

log "Cleaning up COPR repos."
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# Build v4l2loopback
# ---------------------------------------------------------------------------

log "Building v4l2loopback module for kernel: ${KERNEL_VERSION}"
disable_akmodsbuild || exit 1

log "Enabling RPM Fusion Free repo."
dnf -y install \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"

dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
    akmod-v4l2loopback
TRANSIENT="${TRANSIENT} akmod-v4l2loopback"

akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod v4l2loopback

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
# Build Nvidia via upstream .run payload
# ---------------------------------------------------------------------------

if [ "${NVIDIA}" = "true" ]; then
    log "Starting upstream NVIDIA payload build for kernel ${KERNEL_VERSION}."

    # 1. Install build dependencies needed for the installer
    NVIDIA_BUILD_DEPS="dkms gcc make perl elfutils-libelf-devel libglvnd libglvnd-egl libglvnd-gles libglvnd-glx libglvnd-opengl egl-x11 egl-wayland2 egl-gbm xorg-x11-server-Xorg policycoreutils checkpolicy selinux-policy-devel bzip2 curl tar"
    # shellcheck disable=SC2086
    dnf install -y --setopt=install_weak_deps=False $NVIDIA_BUILD_DEPS

    if [[ ! -d "$KERNEL_SOURCE" ]]; then
        err "Missing kernel source path after installing devel package: $KERNEL_SOURCE"
        exit 1
    fi

    # 2. Fetch the latest NVIDIA version directly
    NVIDIA_LATEST_URL="https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"
    latest_info="$(curl -fsSL "$NVIDIA_LATEST_URL")"
    NVIDIA_VERSION="$(awk '{print $1}' <<< "$latest_info")"
    NVIDIA_RUN_PATH="$(awk '{print $2}' <<< "$latest_info")"
    NVIDIA_RUN="${NVIDIA_RUN_PATH##*/}"
    NVIDIA_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_RUN_PATH}"

    _tmpdir="$(mktemp -d)"
    log "Downloading NVIDIA ${NVIDIA_VERSION} installer..."
    curl -fL "$NVIDIA_URL" -o "$_tmpdir/$NVIDIA_RUN"
    chmod +x "$_tmpdir/$NVIDIA_RUN"

    log "Extracting NVIDIA installer payload..."
    (
        cd "$_tmpdir"
        "./$NVIDIA_RUN" --extract-only
    )

    NVIDIA_SRC_DIR="$_tmpdir/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}"
    if [[ ! -d "$NVIDIA_SRC_DIR" ]]; then
        err "Extracted NVIDIA source directory not found: $NVIDIA_SRC_DIR"
        exit 1
    fi

    # 3. Compile and Install
    log "Running NVIDIA installer..."
    LD=ld.bfd "$NVIDIA_SRC_DIR/nvidia-installer" \
        --silent \
        --accept-license \
        --no-questions \
        --no-runlevel-check \
        --no-nouveau-check \
        --no-network \
        --no-check-for-alternate-installs \
        --install-libglvnd \
        --kernel-name="${KERNEL_VERSION}" \
        --kernel-source-path="${KERNEL_SOURCE}" \
        --utility-prefix=/usr \
        --opengl-prefix=/usr \
        --compat32-prefix=/usr \
        --x-prefix=/usr

    rm -rf "$_tmpdir"

    # 4. Apply standard configuration files
    mkdir -p /etc/modprobe.d /usr/lib/udev/rules.d /usr/lib/dracut/dracut.conf.d

    cat <<'EOF' > /etc/modprobe.d/nvidia.conf
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
EOF
    chmod 0644 /etc/modprobe.d/nvidia.conf

    cat <<'EOF' > /usr/lib/dracut/dracut.conf.d/99-nvidia.conf
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_peermem nvidia_drm "
omit_drivers+=" nouveau "
EOF
    chmod 0644 /usr/lib/dracut/dracut.conf.d/99-nvidia.conf

    cat <<'EOF' > /usr/lib/udev/rules.d/60-nvidia.rules
KERNEL=="nvidia", RUN+="/usr/bin/nvidia-modprobe -c 0 -u"
KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c 0 -u"
EOF
    chmod 0644 /usr/lib/udev/rules.d/60-nvidia.rules

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

    # 5. Enable systemd services
    systemctl enable nvidia-powerd.service 2>/dev/null || true
    systemctl enable nvidia-persistenced.service 2>/dev/null || true

    # 6. Install NVIDIA Container Toolkit (still requires the repo)
    log "Installing NVIDIA Container Toolkit..."
    curl -fsSL --retry 5 --create-dirs \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf install -y --setopt=skip_unavailable=1 nvidia-container-toolkit
    rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo

    log "Installing Container Toolkit CDI auto-generation unit."
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

    # 7. Install DGX SELinux Policy
    log "Installing Nvidia SELinux policy."
    curl -fsSL --retry 5 --create-dirs \
        https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/bin/RHEL9/nvidia-container.pp \
        -o nvidia-container.pp
    semodule -i nvidia-container.pp
    rm -f nvidia-container.pp

    # 8. Mark build deps for removal
    # shellcheck disable=SC2086
    TRANSIENT="${TRANSIENT} $NVIDIA_BUILD_DEPS"

    # Generate module dependencies
    depmod "${KERNEL_VERSION}"
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
# ---------------------------------------------------------------------------

log "Removing transient build packages: ${TRANSIENT}"
# shellcheck disable=SC2086
dnf -y remove $TRANSIENT || true

_residual=$(rpm -qa --queryformat '%{NAME}\n' | grep -E '^akmod-|(-devel-matched)$' || true)
if [ -n "${_residual}" ]; then
    log "Removing residual build packages: ${_residual}"
    # shellcheck disable=SC2086
    dnf -y remove $_residual || true
fi

log "Removing kernel build trees."
rm -rf /usr/lib/modules/*/build /usr/lib/modules/*/source /usr/src/nvidia-*

log "Removing akmods build artefacts."
rm -rf /var/cache/akmods /var/lib/dkms

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
    # The .run payload sometimes places modules in different subdirs depending on the kernel structure.
    # Using `find` ensures we can verify them regardless of exact extra/kernel location.
    for _name in nvidia nvidia-drm nvidia-modeset nvidia-peermem nvidia-uvm; do
        if ! find "/usr/lib/modules/${KERNEL_VERSION}" -name "${_name}.ko*" | grep -q .; then
            err "Missing Nvidia module: ${_name}.ko*"
            exit 1
        fi
    done
    log "All Nvidia modules present."
fi

log "Custom kernel installation complete."

```
