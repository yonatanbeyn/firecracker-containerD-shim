#!/usr/bin/env bash
# Builds firecracker-containerd from source and installs every binary the
# stack needs.
#
# Upstream ships no binary releases, so everything is built from a pinned
# commit. The first run compiles a large Go dependency tree and takes several
# minutes; later runs reuse the Go build cache.
#
# Host binaries -> /usr/local/bin
# Guest binaries -> /srv/firecracker/guest-bin (baked into the rootfs by 12-)

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

export PATH="${PATH}:${GO_ROOT}/bin"
export GOFLAGS="-buildvcs=false"
command -v go >/dev/null || die "go not found - run 10-install-toolchain.sh first"

GUEST_BIN="${WORKDIR}/guest-bin"
mkdir -p "$GUEST_BIN" "$(dirname "$FCC_SRC")"

# --- source ------------------------------------------------------------------
info "Fetching firecracker-containerd @ ${FCC_COMMIT:0:12}"
if [ -d "${FCC_SRC}/.git" ]; then
  git -C "$FCC_SRC" fetch -q origin "$FCC_COMMIT" 2>/dev/null \
    || git -C "$FCC_SRC" fetch -q origin
else
  rm -rf "$FCC_SRC"
  git clone -q "$FCC_REPO" "$FCC_SRC"
fi
git -C "$FCC_SRC" checkout -q "$FCC_COMMIT" 2>/dev/null \
  || die "could not check out pinned commit ${FCC_COMMIT}"
ok "source at $(git -C "$FCC_SRC" rev-parse --short HEAD)"

# --- guest agent -------------------------------------------------------------
# CGO_ENABLED=0: the agent runs inside the microVM, which has a different libc
# situation than the build host. A static binary removes that coupling.
info "Building guest agent (static)"
( cd "${FCC_SRC}/agent" \
  && CGO_ENABLED=0 go build -installsuffix cgo -a \
       -ldflags "-s -X main.revision=${FCC_COMMIT}" -o "${GUEST_BIN}/agent" . ) \
  || die "agent build failed"
file "${GUEST_BIN}/agent" | grep -q "statically linked" \
  || warn "agent is not statically linked - it may fail inside the guest"
ok "agent -> ${GUEST_BIN}/agent ($(du -h "${GUEST_BIN}/agent" | cut -f1))"

# --- runtime shim ------------------------------------------------------------
info "Building containerd-shim-aws-firecracker"
( cd "${FCC_SRC}/runtime" \
  && go build -o /usr/local/bin/containerd-shim-aws-firecracker \
       -ldflags "-X main.revision=${FCC_COMMIT}" . ) \
  || die "shim build failed"
chmod 755 /usr/local/bin/containerd-shim-aws-firecracker
ok "shim -> /usr/local/bin/containerd-shim-aws-firecracker"

# --- containerd with the firecracker-control plugin --------------------------
# This is a full containerd binary with firecracker-control compiled in. It is
# deliberately separate from any system containerd: it listens on its own
# socket and uses its own state dir, so Docker Desktop is unaffected.
info "Building firecracker-containerd (containerd + fc-control plugin)"
( cd "${FCC_SRC}/firecracker-control/cmd/containerd" \
  && go build -o /usr/local/bin/firecracker-containerd \
       -ldflags "-X main.revision=${FCC_COMMIT}" . ) \
  || die "firecracker-containerd build failed"
chmod 755 /usr/local/bin/firecracker-containerd
ok "firecracker-containerd -> $(/usr/local/bin/firecracker-containerd --version | head -1)"

# --- ctr client --------------------------------------------------------------
# Taken from the official release tarball rather than `go install`: containerd's
# go.mod carries `exclude` directives, which `go install pkg@version` refuses to
# resolve. ctr is a generic client and speaks the same API as the daemon built
# above, so the released build is equivalent.
info "Installing ctr client (containerd ${CONTAINERD_VERSION})"
if [ -x /usr/local/bin/firecracker-ctr ]; then
  ok "firecracker-ctr already installed"
else
  ctr_ver="${CONTAINERD_VERSION#v}"
  curl -fsSL --retry 3 -o /tmp/containerd.tgz \
    "https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${ctr_ver}-linux-amd64.tar.gz" \
    || die "containerd release download failed"
  tar -C /tmp -xzf /tmp/containerd.tgz bin/ctr
  install -m755 /tmp/bin/ctr /usr/local/bin/firecracker-ctr
  rm -rf /tmp/containerd.tgz /tmp/bin
  ok "firecracker-ctr -> $(/usr/local/bin/firecracker-ctr --version)"
fi

# --- runc for the guest ------------------------------------------------------
# The agent shells out to runc inside the microVM to actually run the
# container, so runc must be in the guest rootfs, not on the host.
info "Fetching runc ${RUNC_VERSION} (guest)"
if [ -x "${GUEST_BIN}/runc" ]; then
  ok "runc already present"
else
  curl -fsSL --retry 3 -o "${GUEST_BIN}/runc" \
    "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" \
    || die "runc download failed"
  chmod +x "${GUEST_BIN}/runc"
  ok "runc -> ${GUEST_BIN}/runc"
fi

# --- CNI plugins + tc-redirect-tap -------------------------------------------
# tc-redirect-tap is what wires a CNI-managed veth to the microVM's tap device;
# without it the standard CNI plugins cannot give a Firecracker VM a network.
info "Installing CNI plugins ${CNI_VERSION}"
mkdir -p "$CNI_BIN_DIR"
if [ -x "${CNI_BIN_DIR}/bridge" ] && [ -x "${CNI_BIN_DIR}/host-local" ]; then
  ok "CNI plugins already installed"
else
  curl -fsSL --retry 3 -o /tmp/cni.tgz \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
    || die "CNI plugin download failed"
  tar -C "$CNI_BIN_DIR" -xzf /tmp/cni.tgz
  rm -f /tmp/cni.tgz
  ok "CNI plugins -> ${CNI_BIN_DIR}"
fi

info "Building tc-redirect-tap"
if [ -x "${CNI_BIN_DIR}/tc-redirect-tap" ]; then
  ok "tc-redirect-tap already built"
else
  GOBIN="$CNI_BIN_DIR" go install \
    "github.com/awslabs/tc-redirect-tap/cmd/tc-redirect-tap@${TC_REDIRECT_TAP_VERSION}" \
    || die "tc-redirect-tap build failed"
  ok "tc-redirect-tap -> ${CNI_BIN_DIR}/tc-redirect-tap"
fi

echo
info "Installed binaries"
for b in /usr/local/bin/firecracker-containerd \
         /usr/local/bin/containerd-shim-aws-firecracker \
         /usr/local/bin/firecracker-ctr; do
  printf '       %-50s %s\n' "$b" "$(du -h "$b" | cut -f1)"
done
printf '       %-50s %s\n' "${GUEST_BIN}/agent" "$(du -h "${GUEST_BIN}/agent" | cut -f1)"
printf '       %-50s %s\n' "${GUEST_BIN}/runc"  "$(du -h "${GUEST_BIN}/runc" | cut -f1)"

echo
ok "Build complete. Next: sudo bash 12-build-agent-rootfs.sh"
