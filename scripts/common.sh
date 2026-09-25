#!/usr/bin/env bash
# Shared configuration for all Firecracker setup scripts.
# Sourced by every 0*.sh script; not meant to be run directly.

set -euo pipefail

# --- Pinned artifact versions -------------------------------------------------
# Pinned on purpose: "latest" makes the setup non-reproducible.
CI_CHANNEL="v1.12"
FC_VERSION="v1.12.1"
KERNEL_NAME="vmlinux-6.1.128"
ROOTFS_NAME="ubuntu-24.04.squashfs"

CI_BASE="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_CHANNEL}/$(uname -m)"

# --- Paths --------------------------------------------------------------------
# MUST live on the WSL ext4 filesystem, never on /mnt/c (DrvFs).
# DrvFs cannot host unix domain sockets, which Firecracker's API requires,
# and it does not preserve the ownership/permissions a root filesystem needs.
WORKDIR="/srv/firecracker"
BIN_DIR="${WORKDIR}/bin"
IMG_DIR="${WORKDIR}/images"
RUN_DIR="${WORKDIR}/run"

FC_BIN="${BIN_DIR}/firecracker"
KERNEL_IMG="${IMG_DIR}/${KERNEL_NAME}"
ROOTFS_IMG="${IMG_DIR}/rootfs.ext4"
ROOTFS_SIZE="1G"

API_SOCKET="${RUN_DIR}/firecracker.socket"
VM_LOG="${RUN_DIR}/firecracker.log"
SSH_KEY="${WORKDIR}/keys/id_ed25519"

# --- Guest / network layout ---------------------------------------------------
TAP_DEV="fc-tap0"
TAP_IP="172.16.0.1"       # host side
GUEST_IP="172.16.0.2"     # microVM side
TAP_MASK="255.255.255.252" # /30
TAP_PREFIX="30"
GUEST_MAC="06:00:AC:10:00:02"

VCPU_COUNT=2
MEM_SIZE_MIB=1024

# --- firecracker-containerd layer (scripts 10-14) -----------------------------
# Only used by the containerd/OCI stack; the standalone microVM above needs none
# of this.
GO_VERSION="1.27.1"
GO_ROOT="/usr/local/go"
RUNC_VERSION="v1.2.6"

FCC_REPO="https://github.com/firecracker-microvm/firecracker-containerd"
FCC_SRC="${WORKDIR}/src/firecracker-containerd"
# Pinned upstream revision (main @ 2026-07-16). Upstream publishes no binary
# releases, so the commit is the only stable reference point.
FCC_COMMIT="be68640a5d2237f5b427c37c1f5809ec154126c5"
CONTAINERD_VERSION="v1.7.33"   # must match the version in the repo's go.mod
TC_REDIRECT_TAP_VERSION="v0.0.0-20250516183331-34bf829e9a5c"

# Paths are fixed by firecracker-containerd's own defaults - see
# config/config.go in the upstream repo. Changing them means overriding
# defaults in several places, so we follow upstream instead.
FCC_ETC="/etc/firecracker-containerd"
FCC_RUNTIME_CFG="/etc/containerd/firecracker-runtime.json"
FCC_VAR="/var/lib/firecracker-containerd"
FCC_RUNTIME_DIR="${FCC_VAR}/runtime"
FCC_SHIM_BASE="${FCC_VAR}/shim-base"
FCC_SNAPSHOTTER_DIR="${FCC_VAR}/snapshotter/devmapper"
FCC_SOCK="/run/firecracker-containerd/containerd.sock"
FCC_STATE="/run/firecracker-containerd"
FCC_LOG="${FCC_VAR}/containerd.log"

# Guest artifacts consumed by the shim.
FCC_KERNEL="${FCC_RUNTIME_DIR}/default-vmlinux.bin"
FCC_ROOTFS="${FCC_RUNTIME_DIR}/default-rootfs.img"

# devmapper thin-pool backing the snapshotter.
DM_POOL_NAME="fcc-thinpool"
DM_DATA_SIZE_GB=20
DM_META_SIZE_MB=256

CNI_VERSION="v1.6.2"
CNI_BIN_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/conf.d"

# --- Output helpers -----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_INFO=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_OK" "$C_OFF" "$*"; }
# warn goes to stdout so it stays correctly ordered with info/ok when piped.
warn()  { printf '%swarn%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()   { printf '%sFAIL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root; re-run with: sudo bash $0"
  fi
}
