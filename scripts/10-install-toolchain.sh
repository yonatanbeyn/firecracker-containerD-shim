#!/usr/bin/env bash
# Installs the build toolchain for firecracker-containerd: Go, C build deps and
# the device-mapper headers the devmapper snapshotter links against.
#
# Ubuntu 24.04 ships a Go older than firecracker-containerd's go.mod requires,
# so Go comes from upstream rather than apt.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

info "Installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
pkgs=()
for p in git make gcc g++ pkg-config libdevmapper-dev libbtrfs-dev \
         e2fsprogs dmsetup curl ca-certificates; do
  dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
done
if [ "${#pkgs[@]}" -gt 0 ]; then
  info "missing: ${pkgs[*]}"
  apt-get update -qq
  apt-get install -y -qq "${pkgs[@]}"
  ok "installed ${pkgs[*]}"
else
  ok "all build dependencies already present"
fi

info "Installing Go ${GO_VERSION}"
current_go=""
[ -x "${GO_ROOT}/bin/go" ] && current_go="$("${GO_ROOT}/bin/go" version | awk '{print $3}')"
if [ "$current_go" = "go${GO_VERSION}" ]; then
  ok "go${GO_VERSION} already installed"
else
  tarball="/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  info "downloading go${GO_VERSION}"
  curl -fsSL --retry 3 -o "$tarball" \
    "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    || die "failed to download Go ${GO_VERSION}"
  rm -rf "$GO_ROOT"
  tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  ok "installed $("${GO_ROOT}/bin/go" version)"
fi

# Make go available to later scripts and to interactive shells.
ln -sf "${GO_ROOT}/bin/go" /usr/local/bin/go
ln -sf "${GO_ROOT}/bin/gofmt" /usr/local/bin/gofmt
cat > /etc/profile.d/go.sh <<'EOF'
export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
EOF
ok "go on PATH via /usr/local/bin/go"

info "Verifying device-mapper thin-pool support"
# The devmapper snapshotter needs these targets in the running kernel. The WSL2
# kernel does ship them, but a kernel update could silently remove them.
if dmsetup targets | grep -q '^thin-pool'; then
  ok "thin-pool target present: $(dmsetup targets | awk '/^thin-pool/{print $2}')"
else
  die "kernel has no thin-pool target - devmapper snapshotter cannot work"
fi
if dmsetup targets | grep -q '^thin '; then
  ok "thin target present"
else
  die "kernel has no thin target - devmapper snapshotter cannot work"
fi

echo
ok "Toolchain ready. Next: sudo bash 11-build-firecracker-containerd.sh"
