#!/usr/bin/env bash
# Tears down runtime state for both layers.
#
#   sudo bash teardown.sh            stop VMs, remove TAP/NAT, stop containerd stack
#   sudo bash teardown.sh --purge    also delete all images, binaries and configs
#
# Without --purge this only removes runtime state, so a re-run of
# 05-run-microvm.sh or 14-run-lambda-vm.sh rebuilds it without re-downloading.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

# --- layer 2: firecracker-containerd -----------------------------------------
info "Stopping firecracker-containerd stack"
for svc in firecracker-containerd.service fcc-thinpool.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1 \
     && systemctl is-active --quiet "$svc"; then
    systemctl stop "$svc"
    ok "stopped ${svc}"
  else
    ok "${svc} not running"
  fi
done

# Shims outlive containerd; leaving them holds the thin pool open.
if pkill -f containerd-shim-aws-firecracker 2>/dev/null; then
  ok "terminated lingering firecracker shims"
  sleep 1
else
  ok "no shims running"
fi

info "Removing device-mapper devices"
# Snapshot devices must go before the pool that owns them.
removed=0
while read -r dev; do
  [ -n "$dev" ] || continue
  case "$dev" in
    "${DM_POOL_NAME}") continue ;;
  esac
  if dmsetup remove "$dev" 2>/dev/null; then
    removed=$((removed + 1))
  fi
done < <(dmsetup ls --target thin 2>/dev/null | awk '{print $1}')
[ "$removed" -gt 0 ] && ok "removed ${removed} thin device(s)" || ok "no thin devices"

if dmsetup info "$DM_POOL_NAME" >/dev/null 2>&1; then
  if dmsetup remove "$DM_POOL_NAME" 2>/dev/null; then
    ok "removed thin pool '${DM_POOL_NAME}'"
  else
    warn "thin pool '${DM_POOL_NAME}' is busy; left in place"
  fi
else
  ok "thin pool not active"
fi

info "Detaching loop devices"
detached=0
for f in "${FCC_SNAPSHOTTER_DIR}/data" "${FCC_SNAPSHOTTER_DIR}/metadata"; do
  dev="$(losetup --output NAME --noheadings --associated "$f" 2>/dev/null | head -1 | tr -d ' ')"
  if [ -n "$dev" ] && losetup -d "$dev" 2>/dev/null; then
    detached=$((detached + 1))
  fi
done
[ "$detached" -gt 0 ] && ok "detached ${detached} loop device(s)" || ok "no loop devices attached"

# --- layer 1: standalone microVM ---------------------------------------------
info "Stopping standalone microVMs"
if pkill -f "${BIN_DIR}/firecracker" 2>/dev/null; then
  ok "terminated running firecracker process(es)"
else
  ok "no standalone firecracker running"
fi
rm -f "$API_SOCKET"

UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"

info "Removing NAT rules"
del_rule() { # del_rule <table> <chain> <rule...>
  local table="$1" chain="$2"; shift 2
  local removed=0
  while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
    iptables -t "$table" -D "$chain" "$@"
    removed=$((removed + 1))
  done
  if [ "$removed" -gt 0 ]; then
    ok "removed ${removed} rule(s): ${chain} $*"
  else
    ok "no rule to remove: ${chain} $*"
  fi
}

if [ -n "$UPLINK" ]; then
  del_rule nat POSTROUTING -o "$UPLINK" -s "${TAP_IP}/${TAP_PREFIX}" -j MASQUERADE
  del_rule filter FORWARD -i "$TAP_DEV" -o "$UPLINK" -j ACCEPT
  del_rule filter FORWARD -i "$UPLINK" -o "$TAP_DEV" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
else
  warn "no default route; skipping NAT rule cleanup"
fi

info "Removing network devices"
for dev in "$TAP_DEV" fc-br0; do
  if ip link show "$dev" >/dev/null 2>&1; then
    ip link del "$dev" && ok "${dev} removed"
  else
    ok "${dev} not present"
  fi
done

# --- purge -------------------------------------------------------------------
if [ "$PURGE" -eq 1 ]; then
  info "Purging installed artifacts"
  systemctl disable -q firecracker-containerd.service fcc-thinpool.service 2>/dev/null || true
  rm -f /etc/systemd/system/firecracker-containerd.service \
        /etc/systemd/system/fcc-thinpool.service
  systemctl daemon-reload
  ok "systemd units removed"

  rm -rf "$WORKDIR" "$FCC_VAR" "$FCC_ETC" "$CNI_CONF_DIR"
  rm -f "$FCC_RUNTIME_CFG"
  ok "state directories deleted"

  rm -f /usr/local/bin/firecracker-containerd \
        /usr/local/bin/containerd-shim-aws-firecracker \
        /usr/local/bin/firecracker-ctr \
        /usr/local/bin/firecracker \
        /usr/local/sbin/fcc-thinpool-setup
  ok "binaries removed"

  warn "Go (${GO_ROOT}) and CNI plugins (${CNI_BIN_DIR}) were left in place"
  warn "re-run setup.ps1 to rebuild everything"
fi

echo
ok "Teardown complete."
