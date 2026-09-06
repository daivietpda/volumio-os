#!/usr/bin/env bash
# Volumio community port for SEI Robotics SEI501 (Amlogic S905X2/G12A).
# The first image is intended for removable-media bring-up and keeps the
# factory eMMC bootloader/DDR untouched.

DEVICE_SUPPORT_TYPE="C"
DEVICE_STATUS="P"

BASE="Debian"
ARCH="armhf"
BUILD="armv7"
UINITRD_ARCH="arm64"

DEVICEFAMILY="sei501"
DEVICENAME="SEI501 S905X2"
DEVICEREPO=""

VOLVARIANT=no
MYVOLUMIO=no
VOLINITUPDATER=yes
KIOSKMODE=no
DEBUG_IMAGE="yes"
PLYMOUTH_THEME=""

BOOT_START=1
BOOT_END=128
IMAGE_END=4416
BOOT_TYPE=msdos
BOOT_USE_UUID=yes
INIT_TYPE="initv3"

# Rootfs-only module loading baseline: SD rootfs does not need early Wi-Fi in initramfs.
# Allows 8822bs to load cleanly with full /etc/modprobe.d options after udev and regulators settle.
MODULES=("overlay" "squashfs" "nls_cp437" "nls_utf8")
PACKAGES=("iw" "wireless-regdb" "wpasupplicant" "alsa-utils")

write_device_files() {
  log "Installing SEI501 boot files, modules and firmware" "ext"
  # FAT boot mounts do not support chown; preserve modes but not ownership.
  cp -a --no-preserve=ownership "${PLTDIR}/${DEVICE}/boot/." "${ROOTFSMNT}/boot/"
  cp -a --no-preserve=ownership "${PLTDIR}/${DEVICE}/lib/modules" "${ROOTFSMNT}/lib/"
  cp -a --no-preserve=ownership "${PLTDIR}/${DEVICE}/lib/firmware" "${ROOTFSMNT}/lib/"
  # The platform archive may carry an older DTB; use the tracked, verified SEI501 DTB.
  local dtb_source="${SRC}/../../board/sei501/boot/amlogic/meson-g12a-sei501.dtb"
  [[ -f "${dtb_source}" ]] || { log "SEI501 DTB missing: ${dtb_source}" "err"; return 1; }
  install -D -m 0644 "${dtb_source}" "${ROOTFSMNT}/boot/amlogic/meson-g12a-sei501.dtb"
}

write_device_bootloader() {
  log "SEI501: preserving stock bootloader/DDR (removable-media bring-up)" "info"
  :
}

device_image_tweaks() {
  # Apply the SEI501 integration overlay before initramfs generation.
  # This hook runs on the host with ROOTFSMNT pointing at the final rootfs,
  # so rootfs and initramfs use one kernel/module generation.
  local overlay="${SRC}/../../overlays/sei501/rootfs"
  if [[ ! -d "${overlay}" ]]; then
    log "SEI501 overlay missing: ${overlay}" "err"
    return 1
  fi
  log "Applying SEI501 integration overlay" "cfg" "${overlay}"
  # Debian armhf uses /lib -> usr/lib; never replace that symlink.
  rsync -a --exclude='lib/' "${overlay}/" "${ROOTFSMNT}/"
  install -d "${ROOTFSMNT}/usr/lib/modules/6.12.108"
  rsync -a "${overlay}/lib/modules/6.12.108/" \
    "${ROOTFSMNT}/usr/lib/modules/6.12.108/"
  if [[ ! -d "${ROOTFSMNT}/usr/lib/modules/6.12.108" ]]; then
    log "SEI501 kernel module directory missing after overlay" "err"
    return 1
  fi
  # Keep the integration's multi-network setting when applying the overlay.
  # Otherwise wireless.js drops Wi-Fi association whenever LAN is connected.
  local env_file="${ROOTFSMNT}/volumio/.env"
  if [[ -f "${env_file}" ]]; then
    sed -i '/^SINGLE_NETWORK_MODE=/d' "${env_file}"
    printf '\nSINGLE_NETWORK_MODE=false\n' >> "${env_file}"
  fi
  depmod -b "${ROOTFSMNT}" 6.12.108
  test -s "${ROOTFSMNT}/usr/lib/modules/6.12.108/extra/8822bs.ko"
  test -f "${ROOTFSMNT}/etc/modprobe.d/sei501-rtl8822bs.conf"
  test -f "${ROOTFSMNT}/etc/systemd/system/sei501-wifi-init.service"
  test -f "${ROOTFSMNT}/usr/local/sbin/sei501-audio-init"
  test -f "${ROOTFSMNT}/volumio/app/plugins/audio_interface/alsa_controller/cards.json"
  # Port 80 is provided by systemd-socket-proxyd; enable its socket in the
  # immutable rootfs so the HTTP endpoint survives every reboot.
  install -d "${ROOTFSMNT}/etc/systemd/system/sockets.target.wants"
  ln -sfn ../volumio-http.socket \
    "${ROOTFSMNT}/etc/systemd/system/sockets.target.wants/volumio-http.socket"
  # This board kernel has no NAT REDIRECT target; the old iptables redirect
  # only fails at boot and is unnecessary once the socket proxy is enabled.
  rm -f "${ROOTFSMNT}/etc/systemd/system/multi-user.target.wants/iptables.service"
}

device_chroot_tweaks_pre() {
  log "Configuring SEI501 kernel command line" "cfg"
  if [[ -f /boot/config.ini ]]; then
    sed -i "s/%%VOLUMIO-UUIDPARAMS%%/imgpart=UUID=${UUID_IMG} bootpart=UUID=${UUID_BOOT} datapart=UUID=${UUID_DATA}/" /boot/config.ini
    if [[ "${DEBUG_IMAGE}" == "yes" ]]; then
      sed -i "s/%%VERBOSITY%%/verbosity=loglevel=8 nosplash use_kmsg=yes/" /boot/config.ini
    else
      sed -i "s/%%VERBOSITY%%/verbosity=quiet loglevel=0/" /boot/config.ini
    fi
  fi
  cat <<-EOF >>/etc/sysctl.conf
abi.cp15_barrier=2
EOF
  sed -i "s/^MODULES=.*/MODULES=list/" /etc/initramfs-tools/initramfs.conf
}

device_chroot_tweaks_post() {
  :
}

device_image_tweaks_post() {
  local autoscript_src="${SRC}/../../board/sei501/boot-scripts/sei501_autoscript.cmd"
  local autoscript_cmd="${ROOTFSMNT}/boot/.sei501_autoscript.cmd"
  if [[ ! -f "${autoscript_src}" ]]; then
    log "SEI501 autoscript source missing: ${autoscript_src}" "err"
    return 1
  fi
  log "Rendering SEI501 autoscript with image filesystem UUIDs" "info"
  sed -e "s/%%IMG_UUID%%/${UUID_IMG}/g" \
      -e "s/%%BOOT_UUID%%/${UUID_BOOT}/g" \
      -e "s/%%DATA_UUID%%/${UUID_DATA}/g" \
      "${autoscript_src}" > "${autoscript_cmd}"
  mkimage -A arm -O linux -T script -C none -a 0 -e 0 \
    -n "SEI501 Volumio SD boot" -d "${autoscript_cmd}" \
    "${ROOTFSMNT}/boot/sei501_autoscript"
  rm -f "${autoscript_cmd}"
  log "Wrapping volumio.initrd as uInitrd" "info"
  if [[ -f "${ROOTFSMNT}/boot/volumio.initrd" ]]; then
    mkimage -A "${UINITRD_ARCH}" -O linux -T ramdisk -C none -a 0 -e 0 -n uInitrd -d "${ROOTFSMNT}/boot/volumio.initrd" "${ROOTFSMNT}/boot/uInitrd"
    rm -f "${ROOTFSMNT}/boot/volumio.initrd"
  fi
}
