#!/usr/bin/env bash
# Reports health of both layers without booting anything. Read-only.

source "$(dirname "$(readlink -f "$0")")/common.sh"

state() { # state <label> <ok-condition-command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '%s  ok%s %-30s\n' "$C_OK" "$C_OFF" "$label"
  else
    printf '%swarn%s %-30s\n' "$C_WARN" "$C_OFF" "$label"
  fi
}

info "Host"
echo "     kernel : $(uname -r)"
echo "        kvm : $( [ -e /dev/kvm ] && echo present || echo MISSING )"
echo

info "Layer 1 - standalone microVM"
state "firecracker binary"      test -x "$FC_BIN"
state "guest kernel image"      test -s "$KERNEL_IMG"
state "guest rootfs"            test -s "$ROOTFS_IMG"
state "tap device ${TAP_DEV}"   ip link show "$TAP_DEV"
echo

info "Layer 2 - firecracker-containerd"
state "firecracker-containerd binary" test -x /usr/local/bin/firecracker-containerd
state "shim binary"                   test -x /usr/local/bin/containerd-shim-aws-firecracker
state "ctr client"                    test -x /usr/local/bin/firecracker-ctr
state "agent rootfs"                  test -s "$FCC_ROOTFS"
state "runtime config"                test -s "$FCC_RUNTIME_CFG"
state "CNI: tc-redirect-tap"          test -x "${CNI_BIN_DIR}/tc-redirect-tap"
echo

info "Services"
for svc in fcc-thinpool.service firecracker-containerd.service; do
  st="$(systemctl is-active "$svc" 2>/dev/null || true)"
  if [ "$st" = "active" ]; then
    printf '%s  ok%s %-30s %s\n' "$C_OK" "$C_OFF" "$svc" "$st"
  else
    printf '%swarn%s %-30s %s\n' "$C_WARN" "$C_OFF" "$svc" "${st:-unknown}"
  fi
done
echo

info "Thin pool"
if dmsetup info "$DM_POOL_NAME" >/dev/null 2>&1; then
  ok "${DM_POOL_NAME}: $(dmsetup info "$DM_POOL_NAME" | awk '/^State:/{print $2}')"
  dmsetup status "$DM_POOL_NAME" 2>/dev/null | sed 's/^/       /'
else
  warn "${DM_POOL_NAME} not active"
fi
echo

info "containerd socket"
if [ -S "$FCC_SOCK" ]; then
  ok "$FCC_SOCK"
  imgs="$(/usr/local/bin/firecracker-ctr --address "$FCC_SOCK" images ls -q 2>/dev/null)"
  if [ -n "$imgs" ]; then
    info "Pulled images"
    printf '%s\n' "$imgs" | sed 's/^/       /'
  else
    info "No images pulled yet"
  fi
else
  warn "socket missing - is firecracker-containerd running?"
fi
