#!/bin/sh
set -eu

log() { echo "[custom-kernel] $*"; }
err() { echo "[custom-kernel] Error: $*" >&2; }

TRANSIENT=""
AK_PATCHED=false

cleanup() {
    rc=$?
    [ "$AK_PATCHED" = "true" ] && restore_ak
    log "Cleaning DNF caches."
    dnf -y clean all || true
    rm -rf /var/cache/dnf/* /var/tmp/dnf-* || true
    exit "${rc}"
}

disable_hooks() {
    for f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${f}" ] || continue
        mv "${f}" "${f}.bak"
        printf '#!/bin/sh\nexit 0\n' >"${f}"
        chmod +x "${f}"
    done
}

restore_hooks() {
    for f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${f}.bak" ] && mv -f "${f}.bak" "${f}"
    done
}

disable_ak() {
    local AK PATTERN
    AK=/usr/sbin/akmodsbuild
    PATTERN='if [[ -w /var ]] ; then'
    [ -f "${AK}" ] || { err "akmodsbuild not found"; return 1; }

    # Pre-check: make sure the root-guard block we intend to remove actually exists.
    # If it doesn't, upstream has changed akmodsbuild and the sed below would silently
    # do nothing, causing akmods to abort later with a confusing "Not to be used as root" error.
    if ! grep -qF "${PATTERN}" "${AK}"; then
        err "akmodsbuild: root-check pattern not found — upstream may have changed the script. Manual inspection of ${AK} required."
        return 1
    fi

    cp -a "${AK}" "${AK}.backup"
    sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${AK}"

    # Post-check: verify the block is actually gone after patching.
    if grep -qF "${PATTERN}" "${AK}"; then
        err "akmodsbuild: sed patch did not remove the root-check block — the file is unchanged."
        restore_ak
        return 1
    fi

    AK_PATCHED=true
}

restore_ak() {
    [ -f /usr/sbin/akmodsbuild.backup ] && mv -f /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
    AK_PATCHED=false
}

sign_kernel() {
    local vmlinuz tmp
    vmlinuz="/usr/lib/modules/${KVER}/vmlinuz"
    [ -f "${vmlinuz}" ] || { err "Kernel not found: ${vmlinuz}"; return 1; }
    tmp="$(mktemp)"
    sbsign --key "${KEY}" --cert "${CERT}" --output "${tmp}" "${vmlinuz}"
    sbverify --cert "${CERT}" "${tmp}" || { rm -f "${tmp}"; err "Signature verification failed"; return 1; }
    install -m 0644 "${tmp}" "${vmlinuz}"
    rm -f "${tmp}"
    sha256sum "${vmlinuz}" >/tmp/vmlinuz.sha
}

sign_mods() {
    local sf tmplist raw
    sf="/usr/lib/modules/${KVER}/build/scripts/sign-file"
    [ -x "${sf}" ] || { err "sign-file not found: ${sf}"; return 1; }
    _sign() { "${sf}" sha256 "${KEY}" "${CERT}" "$1"; }

    tmplist="$(mktemp)"
    find "/usr/lib/modules/${KVER}" -type f \(    \
        -name "*.ko"     -o -name "*.ko.xz"       \
        -o -name "*.ko.zst" -o -name "*.ko.gz"    \
    \) >"${tmplist}"

    while IFS= read -r mod; do
        case "${mod}" in
        *.ko)
            _sign "${mod}" || { rm -f "${tmplist}"; return 1; }
            ;;
        *.ko.xz)
            raw="${mod%.xz}"
            xz -dq "${mod}"
            _sign "${raw}" || { rm -f "${tmplist}"; return 1; }
            xz -zq "${raw}"
            ;;
        *.ko.zst)
            raw="${mod%.zst}"
            zstd -dq --rm "${mod}"
            _sign "${raw}" || { rm -f "${tmplist}"; return 1; }
            zstd -q --rm "${raw}"
            ;;
        *.ko.gz)
            raw="${mod%.gz}"
            gunzip -q "${mod}"
            _sign "${raw}" || { rm -f "${tmplist}"; return 1; }
            gzip -q "${raw}"
            ;;
        esac
    done <"${tmplist}"

    rm -f "${tmplist}"
}

create_mok_unit() {
    local mok tmp
    mok=/usr/share/cert/MOK.der
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

jq_out=$(printf '%s' "$1" | jq -r '[
    .kernel // "cachyos-lto",
    (.initramfs // false | tostring),
    (.sign.key // ""),
    (.sign.cert // ""),
    (.sign["mok-password"] // "")
] | @tsv')

KTYPE=$(printf '%s' "$jq_out"    | cut -f1)
INITRAMFS=$(printf '%s' "$jq_out" | cut -f2)
KEY=$(printf '%s' "$jq_out"      | cut -f3)
CERT=$(printf '%s' "$jq_out"     | cut -f4)
MOK_PASS=$(printf '%s' "$jq_out" | cut -f5)

SB=false
if [ -z "${KEY}" ] && [ -z "${CERT}" ] && [ -z "${MOK_PASS}" ]; then
    log "SecureBoot signing disabled."
elif [ -f "${KEY}" ] && [ -f "${CERT}" ] && [ -n "${MOK_PASS}" ]; then
    SB=true; log "SecureBoot signing enabled."
else
    err "Invalid signing config: key=${KEY:-<empty>} cert=${CERT:-<empty>} mok-password=${MOK_PASS:-<empty>}"
    exit 1
fi

if [ "$SB" = "true" ]; then
    openssl pkey -in "${KEY}"  -noout 2>/dev/null || { err "sign.key is not a valid private key"; exit 1; }
    openssl x509 -in "${CERT}" -noout 2>/dev/null || { err "sign.cert is not a valid X509 cert"; exit 1; }
    tmp1="$(mktemp)"; tmp2="$(mktemp)"
    openssl pkey -in "${KEY}" -pubout        >"${tmp1}"
    openssl x509 -in "${CERT}" -pubkey -noout >"${tmp2}"
    if ! diff -q "${tmp1}" "${tmp2}" >/dev/null; then
        rm -f "${tmp1}" "${tmp2}"
        err "sign.key and sign.cert do not match"
        exit 1
    fi
    rm -f "${tmp1}" "${tmp2}"
fi

# ---------------------------------------------------------------------------
# Kernel package resolution
# ---------------------------------------------------------------------------

case "${KTYPE}" in
    *-nvidia) BASE="${KTYPE%-nvidia}" ;;
    *)        BASE="${KTYPE}" ;;
esac

case "${BASE}" in
    cachyos-lto|cachyos-lts-lto)    COPR="bieszczaders/kernel-cachyos-lto" ;;
    cachyos|cachyos-rt|cachyos-lts) COPR="bieszczaders/kernel-cachyos" ;;
    *) err "Unsupported kernel type: ${KTYPE}"; exit 1 ;;
esac

KPKGS="kernel-${BASE} kernel-${BASE}-core kernel-${BASE}-modules"
case "${KTYPE}" in
    *-nvidia) KPKGS="${KPKGS} kernel-${BASE}-nvidia-open" ;;
esac

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

log "Installing: ${KPKGS}"
# SC2086: intentional word-splitting on space-separated package list
# shellcheck disable=SC2086
dnf -y install $KPKGS "kernel-${BASE}-devel-matched" akmods
TRANSIENT="${TRANSIENT:+${TRANSIENT} }kernel-${BASE}-devel-matched akmods"

KVER="$(rpm -q "$(printf '%s' "$KPKGS" | cut -d' ' -f1)" \
    --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" || exit 1
log "Kernel: ${KVER}"

restore_hooks
rm -f /etc/yum.repos.d/*copr*

# ---------------------------------------------------------------------------
# Build v4l2loopback
# ---------------------------------------------------------------------------

log "Building v4l2loopback."
disable_ak || exit 1

dnf -y install "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
TRANSIENT="${TRANSIENT:+${TRANSIENT} }rpmfusion-free-release"

dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts akmod-v4l2loopback
TRANSIENT="${TRANSIENT:+${TRANSIENT} }akmod-v4l2loopback"

akmods --force --verbose --kernels "${KVER}" --kmod v4l2loopback

fail_found=false
for f in /var/cache/akmods/v4l2loopback/*-for-"${KVER}".failed.log; do
    [ -f "$f" ] && { fail_found=true; break; }
done
if [ "$fail_found" = "true" ]; then
    err "v4l2loopback build failed"
    for f in /var/cache/akmods/v4l2loopback/*-for-"${KVER}".failed.log; do
        [ -f "$f" ] && { cat "$f"; log "---"; }
    done
    restore_ak; exit 1
fi

rm -f /etc/yum.repos.d/rpmfusion-free*.repo
restore_ak

# ---------------------------------------------------------------------------
# SecureBoot signing (must happen before transient removal: sign-file lives
# inside kernel-devel, which dnf auto-removes with devel-matched)
# ---------------------------------------------------------------------------

if [ "$SB" = "true" ]; then
    log "Signing kernel.";           sign_kernel    || exit 1
    log "Signing modules.";          sign_mods      || exit 1
    log "Creating MOK enroll unit."; create_mok_unit || exit 1
fi

# ---------------------------------------------------------------------------
# Remove transient build packages
# ---------------------------------------------------------------------------

if [ -n "${TRANSIENT}" ]; then
    log "Removing transient packages: ${TRANSIENT}"
    # SC2086: intentional word-splitting on space-separated package list
    # shellcheck disable=SC2086
    dnf -y remove $TRANSIENT || true
    TRANSIENT=""
fi

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------

if [ "${INITRAMFS}" = "true" ]; then
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

if [ "$SB" = "true" ]; then
    sha256sum -c /tmp/vmlinuz.sha || { err "Kernel modified after signing."; exit 1; }
    rm -f /tmp/vmlinuz.sha
    log "Integrity check passed."
fi

log "Done."
