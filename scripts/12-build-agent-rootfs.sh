#!/usr/bin/env bash
# Builds the guest rootfs that firecracker-containerd boots: Ubuntu 24.04 plus
# the VM agent, runc, and upstream's systemd units and overlay-init.
#
# Upstream builds this with Docker (tools/image-builder). Docker Desktop's WSL
# integration is a manual GUI toggle, so this assembles the same image directly
# from the Firecracker CI squashfs instead - same result, no Docker.
#
# The shim mounts this image READ-ONLY and shares it across every microVM
# (see runtime/service.go buildRootDrive). /sbin/overlay-init therefore pivots
# onto a tmpfs overlay at boot so the guest gets a writable root.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

GUEST_BIN="${WORKDIR}/guest-bin"
SQUASHFS="${IMG_DIR}/${ROOTFS_NAME}"
BUILD_ROOT="${WORKDIR}/build-agent"
EXTRACT="${BUILD_ROOT}/rootfs"
UPSTREAM_FILES="${FCC_SRC}/tools/image-builder/files_debootstrap"

[ -x "${GUEST_BIN}/agent" ] || die "missing agent - run 11-build-firecracker-containerd.sh"
[ -x "${GUEST_BIN}/runc" ]  || die "missing runc - run 11-build-firecracker-containerd.sh"
[ -d "$UPSTREAM_FILES" ]    || die "missing upstream image files at ${UPSTREAM_FILES}"

mkdir -p "$IMG_DIR"
if [ ! -s "$SQUASHFS" ]; then
  info "Fetching base rootfs ${ROOTFS_NAME}"
  curl -fsSL --retry 3 -o "$SQUASHFS" "${CI_BASE}/${ROOTFS_NAME}" \
    || die "failed to download ${ROOTFS_NAME}"
  ok "downloaded ${ROOTFS_NAME}"
fi

info "Extracting base rootfs"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
unsquashfs -q -no-progress -d "$EXTRACT" "$SQUASHFS" >/dev/null
ok "extracted ($(du -sh "$EXTRACT" | cut -f1))"

info "Installing agent and runc"
install -D -m755 "${GUEST_BIN}/agent" "${EXTRACT}/usr/local/bin/agent"
install -D -m755 "${GUEST_BIN}/runc"  "${EXTRACT}/usr/local/bin/runc"
# The agent resolves runc via PATH; /usr/bin is always on it.
ln -sf /usr/local/bin/runc "${EXTRACT}/usr/bin/runc"
ok "agent + runc installed"

info "Creating guest directory layout"
# Matches IMAGE_DIRS in tools/image-builder/Makefile. /container is the agent's
# working directory, /rom and /overlay are overlay-init's pivot targets.
for d in /dev /bin /etc /etc/init.d /tmp /var /run /proc /sys \
         /container/rootfs /agent /rom /overlay /mnt; do
  mkdir -p "${EXTRACT}${d}"
done
ok "directories created"

info "Installing upstream systemd units and overlay-init"
# Copied from the pinned upstream checkout rather than hand-written, so the
# guest contract stays in sync with the agent we built.
install -D -m755 "${UPSTREAM_FILES}/sbin/overlay-init" "${EXTRACT}/sbin/overlay-init"
install -D -m644 "${UPSTREAM_FILES}/etc/systemd/system/firecracker-agent.service" \
  "${EXTRACT}/etc/systemd/system/firecracker-agent.service"
install -D -m644 "${UPSTREAM_FILES}/etc/systemd/system/firecracker.target" \
  "${EXTRACT}/etc/systemd/system/firecracker.target"

# firecracker.target pulls in the agent. getty is included so the serial console
# still gives a shell for debugging.
wants="${EXTRACT}/etc/systemd/system/firecracker.target.wants"
mkdir -p "$wants"
ln -sf /etc/systemd/system/firecracker-agent.service "${wants}/firecracker-agent.service"
ln -sf /lib/systemd/system/getty.target "${wants}/getty.target"
ok "firecracker.target + firecracker-agent.service installed"

info "Installing guest resolver"
# ctr is a low-level client: unlike Docker it does not synthesise
# /etc/resolv.conf for containers. 14-run-lambda-vm.sh bind-mounts this file
# into each container so DNS works inside the microVM. WSL's own resolver
# (10.255.255.254) is unreachable from a guest, so use public servers.
rm -f "${EXTRACT}/etc/resolv.conf"
cat > "${EXTRACT}/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
chmod 644 "${EXTRACT}/etc/resolv.conf"
ok "/etc/resolv.conf written into the guest rootfs"

info "Disabling services that stall or fight the microVM"
for svc in cloud-init.service cloud-init-local.service cloud-config.service \
           cloud-final.service systemd-networkd-wait-online.service \
           snapd.service snapd.seeded.service apt-daily.service \
           apt-daily-upgrade.timer apt-daily.timer systemd-timesyncd.service; do
  ln -sf /dev/null "${EXTRACT}/etc/systemd/system/${svc}"
done
ok "masked cloud-init, snapd and timer units"

info "Setting ownership to root:root"
chown -R root:root "$EXTRACT"

used_mib=$(du -sm "$EXTRACT" | cut -f1)
size_mib=$(( used_mib + 128 ))
info "Building ext4 image (${used_mib} MiB content -> ${size_mib} MiB image)"
mkdir -p "$FCC_RUNTIME_DIR"
rm -f "$FCC_ROOTFS"
truncate -s "${size_mib}M" "$FCC_ROOTFS"
mkfs.ext4 -q -F -L fcc-rootfs -d "$EXTRACT" "$FCC_ROOTFS" \
  || die "mkfs.ext4 failed"
e2fsck -fn "$FCC_ROOTFS" >/dev/null 2>&1 || die "rootfs failed consistency check"
ok "${FCC_ROOTFS} ($(du -h "$FCC_ROOTFS" | cut -f1) on disk)"

info "Installing guest kernel"
# firecracker-containerd expects the kernel at a fixed default path.
if [ ! -s "$KERNEL_IMG" ]; then
  curl -fsSL --retry 3 -o "$KERNEL_IMG" "${CI_BASE}/${KERNEL_NAME}" \
    || die "failed to download ${KERNEL_NAME}"
fi
cp -f "$KERNEL_IMG" "$FCC_KERNEL"
ok "${FCC_KERNEL}"

info "Installing firecracker binary for the shim"
# The shim looks up firecracker by the path in firecracker-runtime.json.
if [ ! -x "$FC_BIN" ]; then
  mkdir -p "$BIN_DIR"
  curl -fsSL --retry 3 -o "$FC_BIN" "${CI_BASE}/firecracker/firecracker-${FC_VERSION}" \
    || die "failed to download firecracker"
  chmod +x "$FC_BIN"
fi
install -m755 "$FC_BIN" /usr/local/bin/firecracker
ok "/usr/local/bin/firecracker ($(/usr/local/bin/firecracker --version | head -1))"

rm -rf "$BUILD_ROOT"

echo
ok "Agent rootfs ready. Next: sudo bash 13-configure-containerd.sh"
