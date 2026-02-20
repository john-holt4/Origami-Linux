#!/usr/bin/env bash
# Exit immediately on error, treat unset variables as errors, and propagate pipe failures
set -euo pipefail

# Logging helpers — prefix every message with the module name for clarity in build logs
log()   { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*" >&2; }

log "Starting custom-kernel module..."

# ---------------------------------------------------------------------------
# Configuration parsing
# ---------------------------------------------------------------------------
# Parse all config values from the JSON argument in a single jq call to avoid
# spawning a separate process per field. @tsv serialises the array as a
# tab-separated line; IFS=$'\t' + read splits it back into named variables.
# File paths never contain tabs so @tsv is safe here.
IFS=$'\t' read -r KERNEL_TYPE INITRAMFS SIGNING_KEY SIGNING_CERT MOK_PASSWORD < <(
    printf '%s' "$1" | jq -r '[
        .kernel // "cachyos-lto",
        (.initramfs // false | tostring),
        (.sign.key // ""),
        (.sign.cert // ""),
        (.sign["mok-password"] // "")
    ] | @tsv')
SECURE_BOOT=false

# ---------------------------------------------------------------------------
# Validate SecureBoot signing config
# ---------------------------------------------------------------------------
# All three fields absent  → signing intentionally disabled, continue without it.
# All three fields present → signing enabled, set SECURE_BOOT=true.
# Anything else            → partial / broken config, abort early.
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

# When signing is enabled, cryptographically verify the key and cert before
# doing any real work — better to fail fast here than mid-build.
if [[ ${SECURE_BOOT} == true ]]; then
    # Ensure the private key file is a valid PEM-encoded key
    openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 \
        || { error "sign.key is not a valid private key"; exit 1; }

    # Ensure the certificate file is a valid X.509 cert
    openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
        || { error "sign.cert is not a valid X509 cert"; exit 1; }

    # Confirm the public key embedded in the cert matches the private key.
    # diff -q exits non-zero if the two public keys differ.
    diff -q \
        <(openssl pkey -in "${SIGNING_KEY}" -pubout) \
        <(openssl x509 -in "${SIGNING_CERT}" -pubkey -noout) >/dev/null \
        || { error "sign.key and sign.cert do not match"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Resolve kernel packages and COPR repo
# ---------------------------------------------------------------------------
# All CachyOS kernel package names follow the pattern:
#   kernel-{type}, kernel-{type}-core, kernel-{type}-modules, …
# The nvidia variant simply appends an extra package — strip the "-nvidia"
# suffix so BASE_TYPE always refers to the core kernel name.
NVIDIA=false
if [[ "${KERNEL_TYPE}" == *-nvidia ]]; then
    NVIDIA=true
    BASE_TYPE="${KERNEL_TYPE%-nvidia}"
else
    BASE_TYPE="${KERNEL_TYPE}"
fi

# Map the base kernel type to its COPR repository.
# LTO kernels live in a separate repo from the standard/RT/LTS ones.
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

# Build the list of packages to install using the consistent naming pattern.
# The nvidia-open package is appended only when the nvidia variant was requested.
KERNEL_PACKAGES=(
    "kernel-${BASE_TYPE}"
    "kernel-${BASE_TYPE}-core"
    "kernel-${BASE_TYPE}-modules"
    "kernel-${BASE_TYPE}-devel-matched"
)
[[ "${NVIDIA}" == true ]] && KERNEL_PACKAGES+=("kernel-${BASE_TYPE}-nvidia-open")

# ---------------------------------------------------------------------------
# Kernel install hook helpers
# ---------------------------------------------------------------------------
# rpm-ostree and dracut both register kernel-install hooks that run during
# kernel package installation. Inside a container build those hooks will fail
# (no running systemd, no boot partition, etc.), so we temporarily replace
# them with no-op stubs and restore the originals afterwards.
_KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)

disable_kernel_install_hooks() {
    for f in "${_KERNEL_HOOKS[@]}"; do
        [[ -f "${f}" ]] || continue
        mv "${f}" "${f}.bak"                        # preserve original
        printf '%s\n' '#!/bin/sh' 'exit 0' >"${f}" # replace with no-op stub
        chmod +x "${f}"
    done
}

restore_kernel_install_hooks() {
    for f in "${_KERNEL_HOOKS[@]}"; do
        # Restore only if a backup exists (hook may not have been present)
        [[ -f "${f}.bak" ]] && mv -f "${f}.bak" "${f}"
    done
}

# ---------------------------------------------------------------------------
# Install custom kernel
# ---------------------------------------------------------------------------
log "Temporarily disabling kernel install scripts."
disable_kernel_install_hooks

# Remove the default Fedora kernel entirely so there is no version conflict
# with the CachyOS kernel. The || true prevents a failure if packages are
# already absent. Module files are also wiped for a clean slate.
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
# akmods is included here as it is required later for building out-of-tree modules
dnf -y install "${KERNEL_PACKAGES[@]}" akmods

# Query the installed kernel package to get the exact version string used by
# rpm (e.g. 6.9.3-1.cachyos.x86_64). This is needed for akmods and dracut.
KERNEL_VERSION="$(rpm -q "${KERNEL_PACKAGES[0]}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" || exit 1
log "Detected kernel version: ${KERNEL_VERSION}"

log "Restoring kernel install scripts."
restore_kernel_install_hooks

# Remove the COPR repo file so it doesn't persist into the final image
log "Cleaning up COPR repos."
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# akmodsbuild helpers
# ---------------------------------------------------------------------------
# akmodsbuild contains a block that checks for a writable /var and tries to
# set up a build user at runtime. This fails inside the container build
# environment, so we patch it out temporarily with sed and restore afterwards.

disable_akmodsbuild() {
    local AK="/usr/sbin/akmodsbuild"

    if [[ ! -f "${AK}" ]]; then
        error "akmodsbuild not found: ${AK}"
        return 1
    fi

    cp -a "${AK}" "${AK}.backup" || return 1
    # Remove the problematic /var writability check block from the script
    sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${AK}" || return 1
}

restore_akmodsbuild() {
    local AK="/usr/sbin/akmodsbuild"
    # Restore from backup only if one exists
    [[ -f "${AK}.backup" ]] && mv -f "${AK}.backup" "${AK}"
}

# ---------------------------------------------------------------------------
# Build and install v4l2loopback
# ---------------------------------------------------------------------------
# v4l2loopback is a virtual video device kernel module used for virtual
# cameras. It must be built against the exact kernel version we just installed.

log "Temporarily disabling akmodsbuild for v4l2loopback."
disable_akmodsbuild || exit 1

# RPM Fusion Free provides the akmod-v4l2loopback source package
log "Enabling RPM Fusion Free repo for v4l2loopback."
dnf -y install \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"

log "Building and installing v4l2loopback kernel module."
# --setopt=tsflags=noscripts prevents kernel-install hooks from running during
# the akmod source package install, which would fail in the container
dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts akmod-v4l2loopback
# Trigger the actual kernel module build for our specific kernel version
akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod "v4l2loopback"

# nullglob ensures the array is empty (not a literal glob string) when no
# failed log files exist, so the length check below is reliable
shopt -s nullglob
FAIL_LOGS=( /var/cache/akmods/v4l2loopback/*-for-${KERNEL_VERSION}.failed.log )
shopt -u nullglob

if (( ${#FAIL_LOGS[@]} )); then
    error "v4l2loopback akmod build failed"
    # Dump all failure logs to the build output for diagnosis
    for f in "${FAIL_LOGS[@]}"; do
        cat "${f}" || log "Failed to read ${f}"
        log "--------------"
    done
    restore_akmodsbuild
    exit 1
fi

# Remove RPM Fusion so it doesn't persist into the final image
log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

log "Restoring akmodsbuild."
restore_akmodsbuild

# ---------------------------------------------------------------------------
# SecureBoot: sign kernel and modules
# ---------------------------------------------------------------------------

# Signs the kernel image (vmlinuz) with the MOK key so that UEFI SecureBoot
# will allow it to boot. The signed image is verified before replacing the
# original, and a checksum is saved for a post-build integrity check.
sign_kernel() {
    local VMLINUZ="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
    local SIGNED_VMLINUZ

    [[ -f "${VMLINUZ}" ]] || { error "Kernel image not found: ${VMLINUZ}"; return 1; }

    log "Kernel image: ${VMLINUZ}"
    # Sign into a temp file so the original is untouched if signing fails
    SIGNED_VMLINUZ="$(mktemp)"
    sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${SIGNED_VMLINUZ}" "${VMLINUZ}"

    # Verify the signature on the temp file before committing it
    if ! sbverify --cert "${SIGNING_CERT}" "${SIGNED_VMLINUZ}"; then
        error "Kernel signature verification failed"
        rm -f "${SIGNED_VMLINUZ}"
        return 1
    fi

    log "Verification successful. Installing signed kernel."
    install -m 0644 "${SIGNED_VMLINUZ}" "${VMLINUZ}"
    rm -f "${SIGNED_VMLINUZ}"

    # Save a checksum of the signed vmlinuz so we can confirm nothing has
    # modified it between now and the end of the build (see final check below)
    sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha
}

# Signs every kernel module (.ko) under the kernel version directory.
# Modules may be stored compressed (xz, zst, gz); each must be decompressed
# before signing and recompressed afterwards to preserve the original format.
sign_kernel_modules() {
    local MODULE_ROOT="/usr/lib/modules/${KERNEL_VERSION}"
    # sign-file is the kernel's own tool for appending a PKCS#7 signature to a module
    local SIGN_FILE="${MODULE_ROOT}/build/scripts/sign-file"

    [[ -x "${SIGN_FILE}" ]] || { error "sign-file not found or not executable: ${SIGN_FILE}"; return 1; }

    # -print0 / read -d '' safely handles paths with spaces or special characters
    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko)
            # Uncompressed module — sign directly
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" || return 1
            ;;
        *.ko.xz)
            xz -d -q "${mod}"                                                   # decompress in-place
            raw="${mod%.xz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            xz -z -q "${raw}"                                                   # recompress
            ;;
        *.ko.zst)
            zstd -d -q --rm "${mod}"                                            # decompress, remove original
            raw="${mod%.zst}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            zstd -q "${raw}"                                                    # recompress
            ;;
        *.ko.gz)
            gunzip -q "${mod}"                                                  # decompress in-place
            raw="${mod%.gz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            gzip -q "${raw}"                                                    # recompress
            ;;
        esac
    done < <(find "${MODULE_ROOT}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)
}

# Creates a systemd one-shot unit that enrolls our MOK (Machine Owner Key)
# certificate into the UEFI MOK database on the first real boot. Enrollment
# requires the MOK password set in the configuration; once enrolled the
# firmware will trust kernels and modules signed with our key.
create_mok_enroll_unit() {
    local UNIT_NAME="mok-enroll.service"
    local UNIT_FILE="/usr/lib/systemd/system/${UNIT_NAME}"
    local MOK_CERT="/usr/share/cert/MOK.der"
    local TMP_DER

    # mokutil requires the certificate in DER (binary) format, not PEM
    TMP_DER="$(mktemp)"
    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${TMP_DER}" || { rm -f "${TMP_DER}"; return 1; }
    install -D -m 0644 "${TMP_DER}" "${MOK_CERT}"
    rm -f "${TMP_DER}"

    # Write the systemd unit; ConditionPathExists=!/var/.mok-enrolled ensures
    # it only runs once and is a no-op on subsequent boots
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

    # -f (force) suppresses the "Created symlink" warning in the container
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

# ---------------------------------------------------------------------------
# Generate initramfs (optional)
# ---------------------------------------------------------------------------
# When initramfs generation is requested, dracut builds an initramfs image
# tailored for an OSTree-based system. DRACUT_NO_XATTR=1 avoids xattr issues
# inside the container. --no-hostonly ensures the image works on any hardware,
# not just the build host.
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

# ---------------------------------------------------------------------------
# Final integrity check
# ---------------------------------------------------------------------------
# Verify the signed vmlinuz has not been silently modified by any subsequent
# step (e.g. a dracut hook or stray dnf trigger). Fail loudly if it has.
if [[ ${SECURE_BOOT} == true ]]; then
    sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Kernel integrity check passed."
fi

log "Custom kernel installation complete."
