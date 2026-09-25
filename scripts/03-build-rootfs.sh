#!/usr/bin/env bash
# Converts the read-only squashfs into a writable ext4 root filesystem and
# makes the guest reachable two ways: serial console autologin and SSH.
#
# Re-running rebuilds the image from scratch (the squashfs is never modified).

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

SQUASHFS="${IMG_DIR}/${ROOTFS_NAME}"
BUILD_ROOT="${WORKDIR}/build"
EXTRACT="${BUILD_ROOT}/squashfs-root"

[ -s "$SQUASHFS" ] || die "missing ${SQUASHFS} - run 02-install.sh first"

info "Extracting ${ROOTFS_NAME}"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
unsquashfs -q -no-progress -d "$EXTRACT" "$SQUASHFS" >/dev/null
ok "extracted to ${EXTRACT} ($(du -sh "$EXTRACT" | cut -f1))"

info "Generating SSH keypair for the guest"
if [ ! -f "$SSH_KEY" ]; then
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -q -t ed25519 -f "$SSH_KEY" -N "" -C "firecracker-guest"
  ok "created ${SSH_KEY}"
else
  ok "reusing ${SSH_KEY}"
fi
install -d -m 700 "${EXTRACT}/root/.ssh"
install -m 600 "${SSH_KEY}.pub" "${EXTRACT}/root/.ssh/authorized_keys"
ok "installed authorized_keys for root"

info "Enabling root autologin on the serial console"
# Firecracker gives the guest a single serial port. Autologin means `05-run-microvm.sh`
# drops straight to a shell with no credentials needed.
override_dir="${EXTRACT}/etc/systemd/system/serial-getty@ttyS0.service.d"
mkdir -p "$override_dir"
cat > "${override_dir}/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,38400,9600 %I vt220
EOF
ok "serial-getty@ttyS0 autologin configured"

info "Configuring guest networking"
# The kernel `ip=` cmdline arg configures eth0 before userspace starts, so the
# guest only needs a resolver. Static file: the microVM has no DHCP client.
rm -f "${EXTRACT}/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "${EXTRACT}/etc/resolv.conf"
# systemd-networkd would otherwise tear down the kernel-configured address.
ln -sf /dev/null "${EXTRACT}/etc/systemd/system/systemd-networkd.service"
ok "resolv.conf set, systemd-networkd masked"

info "Trimming first-boot services that stall a microVM"
# These wait on cloud metadata / network sources that do not exist here and
# would otherwise add ~2 minutes to boot.
for svc in cloud-init.service cloud-init-local.service cloud-config.service \
           cloud-final.service systemd-networkd-wait-online.service \
           snapd.service snapd.seeded.service apt-daily.service; do
  ln -sf /dev/null "${EXTRACT}/etc/systemd/system/${svc}"
done
ok "masked cloud-init, snapd, and wait-online units"

info "Setting ownership to root:root"
chown -R root:root "$EXTRACT"

# Size the image from actual content plus headroom, so the guest has room to
# write. A fixed size silently breaks when the upstream rootfs grows.
used_mib=$(du -sm "$EXTRACT" | cut -f1)
size_mib=$(( used_mib * 2 + 256 ))
[ "$size_mib" -lt 1024 ] && size_mib=1024
info "Building ext4 image (${used_mib} MiB content -> ${size_mib} MiB image)"
rm -f "$ROOTFS_IMG"
truncate -s "${size_mib}M" "$ROOTFS_IMG"
mkfs.ext4 -q -F -L fcroot -d "$EXTRACT" "$ROOTFS_IMG" \
  || die "mkfs.ext4 failed - image too small for content?"
ok "created ${ROOTFS_IMG} ($(du -h "$ROOTFS_IMG" | cut -f1) on disk)"

info "Verifying image"
e2fsck -fn "$ROOTFS_IMG" >/dev/null 2>&1 || die "ext4 image failed consistency check"
ok "ext4 image is consistent"

rm -rf "$BUILD_ROOT"

echo
ok "Rootfs ready. Next: sudo bash 04-network.sh"
