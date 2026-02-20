#!/usr/bin/env bash
set -euo pipefail

log() { echo "[custom-kernel] $*"; }
err() { echo "[custom-kernel] Error: $*" >&2; }

TRANSIENT=()
AK_PATCHED=false
_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)

cleanup() {
    local rc=$?
    [[ ${AK_PATCHED} == true ]] && restore_ak
    log "Cleaning DNF caches."
    dnf -y clean all || true
    rm -rf /var/cache/dnf/* /var/tmp/dnf-* || true
    exit "${rc}"
}

disable_hooks() {
    local f
    for f in "${_HOOKS[@]}"; do
        [[ -f ${f} ]] || continue
        mv "${f}" "${f}.bak"
        printf '#!/bin/sh\nexit 0\n' >"${f}"
        chmod +x "${f}"
    done
}

restore_hooks() {
    local f
    for f in "${_HOOKS[@]}"; do
        [[ -f "${f}.bak" ]] && mv -f "${f}.bak" "${f}"
    done
}

disable_ak() {
    local AK=/usr/sbin/akmodsbuild
    [[ -f ${AK} ]] || { err "akmodsbuild not found"; return 1; }
    cp -a "${AK}" "${AK}.backup"
    sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${AK}"
    AK_PATCHED=true
}

restore_ak() {
    [[ -f /usr/sbin/akmodsbuild.backup ]] && mv -f /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
    AK_PATCHED=false
}

sign_kernel() {
    local vmlinuz="/usr/lib/modules/${KVER}/vmlinuz" tmp
    [[ -f ${vmlinuz} ]] || { err "Kernel not found: ${vmlinuz}"; return 1; }
    tmp="$(mktemp)"
    sbsign --key "${KEY}" --cert "${CERT}" --output "${tmp}" "${vmlinuz}"
    sbverify --cert "${CERT}" "${tmp}" || { rm -f "${tmp}"; err "Signature verification failed"; return 1; }
    install -m 0644 "${tmp}" "${vmlinuz}"
    rm -f "${tmp}"
    sha256sum "${vmlinuz}" >/tmp/vmlinuz.sha
}

sign_mods() {
    local mod raw sf="/usr/lib/modules/${KVER}/build/scripts/sign-file"
    [[ -x ${sf} ]] || { err "sign-file not found: ${sf}"; return 1; }
    _sign() { "${sf}" sha256 "${KEY}" "${CERT}" "$1"; }
    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko)     _sign "${mod}" ;;
        *.ko.xz)  raw="${mod%.xz}";  xz -dq "${mod}";       _sign "${raw}" || return 1; xz -zq "${raw}" ;;
        *.ko.zst) raw="${mod%.zst}"; zstd -dq --rm "${mod}"; _sign "${raw}" || return 1; zstd -q --rm "${raw}" ;;
        *.ko.gz)  raw="${mod%.gz}";  gunzip -q "${mod}";     _sign "${raw}" || return 1; gzip -q "${raw}" ;;
        esac
    done < <(find "/usr/lib/modules/${KVER}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)
}

create_mok_unit() {
    local mok=/usr/share/cert/MOK.der tmp
    tmp="$(mktemp)"
    openssl x509 -in "${CERT}" -outform DER -out "${tmp}" || { rm -f "${tmp}"; return 1; }
    install -D -m 0644 "${tmp}" "${mok}"; rm -f "${tmp}"
    install -D -m 0644 /dev/stdin /usr/lib/systemd/system/mok-enroll.service <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${mok}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASS}"; echo "${MOK_PASS}") | mokutil --import "${mok}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl -f enable mok-enroll.service
    log "Enabled mok-enroll.service"
}

trap cleanup EXIT
log "Starting custom-kernel module..."

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

IFS=$'\t' read -r KTYPE INITRAMFS KEY CERT MOK_PASS < <(
    printf '%s' "$1" | jq -r '[
        .kernel // "cachyos-lto",
        (.initramfs // false | tostring),
        (.sign.key // ""),
        (.sign.cert // ""),
        (.sign["mok-password"] // "")
    ] | @tsv')

SB=false
if [[ -z ${KEY} && -z ${CERT} && -z ${MOK_PASS} ]]; then
    log "SecureBoot signing disabled."
elif [[ -f ${KEY} && -f ${CERT} && -n ${MOK_PASS} ]]; then
    SB=true; log "SecureBoot signing enabled."
else
    err "Invalid signing config: key=${KEY:-<empty>} cert=${CERT:-<empty>} mok-password=${MOK_PASS:-<empty>}"
    exit 1
fi

if [[ ${SB} == true ]]; then
    openssl pkey -in "${KEY}"  -noout 2>/dev/null || { err "sign.key is not a valid private key"; exit 1; }
    openssl x509 -in "${CERT}" -noout 2>/dev/null || { err "sign.cert is not a valid X509 cert"; exit 1; }
    diff -q \
        <(openssl pkey -in "${KEY}" -pubout) \
        <(openssl x509 -in "${CERT}" -pubkey -noout) >/dev/null \
        || { err "sign.key and sign.cert do not match"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Kernel package resolution
# ---------------------------------------------------------------------------

BASE="${KTYPE%-nvidia}"
case "${BASE}" in
    cachyos-lto|cachyos-lts-lto)    COPR="bieszczaders/kernel-cachyos-lto" ;;
    cachyos|cachyos-rt|cachyos-lts) COPR="bieszczaders/kernel-cachyos" ;;
    *) err "Unsupported kernel type: ${KTYPE}"; exit 1 ;;
esac

KPKGS=("kernel-${BASE}" "kernel-${BASE}-core" "kernel-${BASE}-modules")
[[ ${KTYPE} == *-nvidia ]] && KPKGS+=("kernel-${BASE}-nvidia-open")

# ---------------------------------------------------------------------------
# Install kernel
# ---------------------------------------------------------------------------

log "Disabling kernel install hooks."
disable_hooks

log "Removing default kernel."
dnf -y remove kernel kernel-core kernel-modules kernel-modules-core \
    kernel-modules-extra kernel-devel kernel-devel-matched || true
rm -rf /usr/lib/modules/*

log "Enabling COPR: ${COPR}"
dnf -y copr enable "${COPR}"

log "Installing: ${KPKGS[*]}"
dnf -y install "${KPKGS[@]}" "kernel-${BASE}-devel-matched" akmods
TRANSIENT+=("kernel-${BASE}-devel-matched" akmods)

KVER="$(rpm -q "${KPKGS[0]}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" || exit 1
log "Kernel: ${KVER}"

restore_hooks
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# Build v4l2loopback
# ---------------------------------------------------------------------------

log "Building v4l2loopback."
disable_ak || exit 1

dnf -y install "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
TRANSIENT+=(rpmfusion-free-release)

dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts akmod-v4l2loopback
TRANSIENT+=(akmod-v4l2loopback)

akmods --force --verbose --kernels "${KVER}" --kmod v4l2loopback

shopt -s nullglob
FAIL_LOGS=(/var/cache/akmods/v4l2loopback/*-for-${KVER}.failed.log)
shopt -u nullglob
if (( ${#FAIL_LOGS[@]} )); then
    err "v4l2loopback build failed"
    for f in "${FAIL_LOGS[@]}"; do cat "${f}"; log "---"; done
    restore_ak; exit 1
fi

rm -f /etc/yum.repos.d/rpmfusion-free*.repo
restore_ak

# ---------------------------------------------------------------------------
# Remove transient build packages
# ---------------------------------------------------------------------------

if (( ${#TRANSIENT[@]} )); then
    log "Removing transient packages: ${TRANSIENT[*]}"
    dnf -y remove "${TRANSIENT[@]}" || true
    TRANSIENT=()
fi

# ---------------------------------------------------------------------------
# SecureBoot signing
# ---------------------------------------------------------------------------

if [[ ${SB} == true ]]; then
    log "Signing kernel.";         sign_kernel   || exit 1
    log "Signing modules.";        sign_mods     || exit 1
    log "Creating MOK enroll unit."; create_mok_unit || exit 1
fi

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------

if [[ ${INITRAMFS} == true ]]; then
    log "Generating initramfs."
    tmp="$(mktemp)"
    DRACUT_NO_XATTR=1 /usr/bin/dracut \
        --no-hostonly --kver "${KVER}" --reproducible --add ostree -f "${tmp}" -v || exit 1
    install -D -m 0600 "${tmp}" "/usr/lib/modules/${KVER}/initramfs.img"
    rm -f "${tmp}"
fi

# ---------------------------------------------------------------------------
# Final integrity check
# ---------------------------------------------------------------------------

if [[ ${SB} == true ]]; then
    sha256sum -c /tmp/vmlinuz.sha || { err "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Integrity check passed."
fi

log "Done."
