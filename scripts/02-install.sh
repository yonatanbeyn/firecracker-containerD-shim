#!/usr/bin/env bash
# Installs host dependencies and downloads the pinned Firecracker binary and
# guest kernel into /srv/firecracker. Idempotent: re-running skips finished work.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

info "Creating work tree under ${WORKDIR}"
mkdir -p "$BIN_DIR" "$IMG_DIR" "$RUN_DIR" "$(dirname "$SSH_KEY")"
ok "${WORKDIR} ready"

info "Installing host packages"
export DEBIAN_FRONTEND=noninteractive
pkgs=()
for p in curl ca-certificates iptables squashfs-tools e2fsprogs iproute2 openssh-client; do
  dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
done
if [ "${#pkgs[@]}" -gt 0 ]; then
  info "missing: ${pkgs[*]}"
  apt-get update -qq
  apt-get install -y -qq "${pkgs[@]}"
  ok "installed ${pkgs[*]}"
else
  ok "all host packages already present"
fi

# Grant the human user direct /dev/kvm access. Not required by these scripts
# (they run as root) but needed to run Firecracker unprivileged later.
# When invoked via `wsl -u root` there is no SUDO_USER, so fall back to uid 1000.
target_user="${FC_USER:-${SUDO_USER:-$(id -nu 1000 2>/dev/null || true)}}"
if [ -n "$target_user" ]; then
  if id -nG "$target_user" | grep -qw kvm; then
    ok "user '${target_user}' already in the kvm group"
  else
    usermod -aG kvm "$target_user"
    ok "added '${target_user}' to the kvm group"
    warn "run 'wsl --shutdown' from Windows for this to take effect"
  fi
fi

fetch() { # fetch <url> <dest>
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    ok "$(basename "$dest") already downloaded ($(du -h "$dest" | cut -f1))"
    return
  fi
  info "downloading $(basename "$dest")"
  curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.part" "$url" \
    || die "download failed: $url"
  mv "${dest}.part" "$dest"
  ok "$(basename "$dest") ($(du -h "$dest" | cut -f1))"
}

info "Fetching Firecracker ${FC_VERSION}"
fetch "${CI_BASE}/firecracker/firecracker-${FC_VERSION}" "$FC_BIN"
chmod +x "$FC_BIN"
file "$FC_BIN" 2>/dev/null | grep -q ELF || die "downloaded Firecracker is not an ELF binary"
ok "firecracker: $("$FC_BIN" --version | head -1)"

info "Fetching guest kernel ${KERNEL_NAME}"
fetch "${CI_BASE}/${KERNEL_NAME}" "$KERNEL_IMG"

info "Fetching guest rootfs ${ROOTFS_NAME}"
fetch "${CI_BASE}/${ROOTFS_NAME}" "${IMG_DIR}/${ROOTFS_NAME}"

echo
ok "Install complete. Next: sudo bash 03-build-rootfs.sh"
