#!/usr/bin/env bash
set -euo pipefail

log()   { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*" >&2; }

log "Starting custom-kernel module..."

RAW_CONFIG="${1:-{}}"
CONFIG="${RAW_CONFIG}"

# Try strict parse first; if it fails, attempt to decode JSON-encoded string,
# then unescape backslash-escaped JSON, then trim to first valid JSON object as fallback
if ! jq -e . >/dev/null 2>&1 <<< "${CONFIG}"; then
  if jq -e 'type == "string"' >/dev/null 2>&1 <<< "${RAW_CONFIG}"; then
    CONFIG="$(jq -r 'fromjson' <<< "${RAW_CONFIG}" 2>/dev/null || true)"
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "${CONFIG}"; then
    CONFIG="$(printf '%b' "${RAW_CONFIG}" 2>/dev/null || true)"
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "${CONFIG}"; then
    CONFIG="$(printf '%s' "${RAW_CONFIG}" | sed -n 's/^[^{]*\({.*}\)[^}]*$/\1/p')"
  fi
fi

# Final validation
jq -e . >/dev/null <<< "${CONFIG}" || {
  error "Invalid JSON config payload"
  error "Raw payload (truncated): $(printf '%s' "${RAW_CONFIG}" | head -c 240)"
  exit 1
}

# Single-pass config parse
read -r KERNEL_TYPE INITRAMFS SIGNING_KEY SIGNING_CERT MOK_PASSWORD < <(
  jq -r '
    . as $c |
    [
      ($c.kernel // "cachyos-lto"),
      (($c.initramfs // false)|tostring),
      ($c.sign.key // ""),
      ($c.sign.cert // ""),
      ($c.sign["mok-password"] // "")
    ] | @tsv
  ' <<< "${CONFIG}"
)

SECURE_BOOT=false
if [[ -z "${SIGNING_KEY}" && -z "${SIGNING_CERT}" && -z "${MOK_PASSWORD}" ]]; then
  log "SecureBoot signing disabled."
elif [[ -f "${SIGNING_KEY}" && -f "${SIGNING_CERT}" && -n "${MOK_PASSWORD}" ]]; then
  log "SecureBoot signing enabled."
  SECURE_BOOT=true
else
  error "Invalid signing config:"
  error "  sign.key: ${SIGNING_KEY:-<empty>}"
  error "  sign.cert: ${SIGNING_CERT:-<empty>}"
  error "  sign.mok-password: ${MOK_PASSWORD:-<empty>}"
  exit 1
fi

if [[ "${SECURE_BOOT}" == true ]]; then
  openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 || { error "sign.key is not a valid private key"; exit 1; }
  openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 || { error "sign.cert is not a valid X509 cert"; exit 1; }
  diff -q \
    <(openssl pkey -in "${SIGNING_KEY}" -pubout) \
    <(openssl x509 -in "${SIGNING_CERT}" -pubkey -noout) >/dev/null || { error "sign.key and sign.cert do not match"; exit 1; }
fi

# Kernel mapping
COPR_REPO=""
KBASE=""
NVIDIA=false

case "${KERNEL_TYPE}" in
  cachyos|cachyos-nvidia|cachyos-rt|cachyos-rt-nvidia|cachyos-lts|cachyos-lts-nvidia)
    COPR_REPO="bieszczaders/kernel-cachyos"
    ;;
  cachyos-lto|cachyos-lto-nvidia|cachyos-lts-lto|cachyos-lts-lto-nvidia)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    ;;
  *)
    error "Unsupported kernel type: ${KERNEL_TYPE}"
    exit 1
    ;;
esac

KBASE="${KERNEL_TYPE%-nvidia}"
[[ "${KERNEL_TYPE}" == *-nvidia ]] && NVIDIA=true

KERNEL_PACKAGES=(
  "kernel-${KBASE}"
  "kernel-${KBASE}-core"
  "kernel-${KBASE}-modules"
  "kernel-${KBASE}-devel-matched"
)
[[ "${NVIDIA}" == true ]] && KERNEL_PACKAGES+=("kernel-${KBASE}-nvidia-open")

RPMOSTREE="/usr/lib/kernel/install.d/05-rpmostree.install"
DRACUT_HOOK="/usr/lib/kernel/install.d/50-dracut.install"
AKMODSBUILD="/usr/sbin/akmodsbuild"

restore_all() {
  [[ -f "${RPMOSTREE}.bak" ]] && mv -f "${RPMOSTREE}.bak" "${RPMOSTREE}"
  [[ -f "${DRACUT_HOOK}.bak" ]] && mv -f "${DRACUT_HOOK}.bak" "${DRACUT_HOOK}"
  [[ -f "${AKMODSBUILD}.backup" ]] && mv -f "${AKMODSBUILD}.backup" "${AKMODSBUILD}"
}
trap restore_all EXIT

disable_kernel_install_hooks() {
  if [[ -f "${RPMOSTREE}" ]]; then
    mv -f "${RPMOSTREE}" "${RPMOSTREE}.bak"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${RPMOSTREE}"
    chmod +x "${RPMOSTREE}"
  fi
  if [[ -f "${DRACUT_HOOK}" ]]; then
    mv -f "${DRACUT_HOOK}" "${DRACUT_HOOK}.bak"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${DRACUT_HOOK}"
    chmod +x "${DRACUT_HOOK}"
  fi
}

disable_akmodsbuild() {
  [[ -f "${AKMODSBUILD}" ]] || { error "akmodsbuild not found: ${AKMODSBUILD}"; exit 1; }
  cp -a "${AKMODSBUILD}" "${AKMODSBUILD}.backup"
  sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' "${AKMODSBUILD}"
}

log "Temporarily disabling kernel install scripts."
disable_kernel_install_hooks

log "Removing default kernel packages."
dnf -y remove kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

log "Enabling COPR repo: ${COPR_REPO}"
dnf -y copr enable "${COPR_REPO}"

log "Installing kernel packages."
dnf -y --setopt=install_weak_deps=False install "${KERNEL_PACKAGES[@]}" akmods

KERNEL_VERSION="$(rpm -q "${KERNEL_PACKAGES[0]}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" || exit 1
log "Detected kernel version: ${KERNEL_VERSION}"

log "Cleaning up custom kernel repos."
rm -f /etc/yum.repos.d/*copr*

log "Temporarily disabling akmodsbuild script for v4l2loopback."
disable_akmodsbuild

log "Enabling RPM Fusion Free repo for v4l2loopback."
dnf -y install "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"

log "Building and installing v4l2loopback."
dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=noscripts akmod-v4l2loopback
akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod v4l2loopback

shopt -s nullglob
FAIL_LOGS=(/var/cache/akmods/v4l2loopback/*-for-"${KERNEL_VERSION}".failed.log)
shopt -u nullglob
if (( ${#FAIL_LOGS[@]} )); then
  error "v4l2loopback akmod build failed"
  for f in "${FAIL_LOGS[@]}"; do cat "${f}" || true; echo "--------------"; done
  exit 1
fi

log "Cleaning RPM Fusion Free repo."
dnf -y remove rpmfusion-free-release || true
rm -f /etc/yum.repos.d/rpmfusion-free*.repo

sign_kernel() {
  local module_root
  local vmlinuz
  local signed

  module_root="/usr/lib/modules/${KERNEL_VERSION}"
  vmlinuz="${module_root}/vmlinuz"

  [[ -f "${vmlinuz}" ]] || { error "Can't find kernel image: ${vmlinuz}"; return 1; }

  signed="$(mktemp)"
  sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${signed}" "${vmlinuz}"
  sbverify --cert "${SIGNING_CERT}" "${signed}" >/dev/null || {
    rm -f "${signed}"
    error "Kernel signature verification failed"
    return 1
  }

  install -m 0644 "${signed}" "${vmlinuz}"
  rm -f "${signed}"
  sha256sum "${vmlinuz}" > /tmp/vmlinuz.sha
}

sign_kernel_modules() {
  local module_root
  local sign_file
  local mod
  local raw

  module_root="/usr/lib/modules/${KERNEL_VERSION}"
  sign_file="${module_root}/build/scripts/sign-file"

  [[ -x "${sign_file}" ]] || { error "sign-file not found or not executable: ${sign_file}"; return 1; }

  while IFS= read -r -d '' mod; do
    case "${mod}" in
      *.ko) "${sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" ;;
      *.ko.xz)  xz -d -q "${mod}"; raw="${mod%.xz}"; "${sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"; xz -z -q "${raw}" ;;
      *.ko.zst) zstd -d -q --rm "${mod}"; raw="${mod%.zst}"; "${sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"; zstd -q "${raw}" ;;
      *.ko.gz)  gunzip -q "${mod}"; raw="${mod%.gz}"; "${sign_file}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"; gzip -q "${raw}" ;;
    esac || return 1
  done < <(find "${module_root}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)
}

create_mok_enroll_unit() {
  local unit="/usr/lib/systemd/system/mok-enroll.service"
  local mok_cert="/usr/share/cert/MOK.der"
  local tmp_der

  tmp_der="$(mktemp)"
  openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${tmp_der}"
  install -D -m 0644 "${tmp_der}" "${mok_cert}"
  rm -f "${tmp_der}"

  cat > "${unit}" <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${mok_cert}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${mok_cert}"'
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl -f enable mok-enroll.service
}

if [[ "${SECURE_BOOT}" == true ]]; then
  log "Signing kernel and modules."
  sign_kernel
  sign_kernel_modules
  create_mok_enroll_unit
fi

if [[ "${INITRAMFS}" == "true" ]]; then
  log "Generating initramfs."
  tmp_initramfs="$(mktemp)"
  DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${KERNEL_VERSION}" --reproducible --add ostree -f "${tmp_initramfs}" -v
  install -D -m 0600 "${tmp_initramfs}" "/lib/modules/${KERNEL_VERSION}/initramfs.img"
  rm -f "${tmp_initramfs}"
fi

if [[ "${SECURE_BOOT}" == true ]]; then
  sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
  rm -f /tmp/vmlinuz.sha
  log "Kernel was not modified after signing."
fi

log "Custom kernel installation complete."
