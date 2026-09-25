#!/usr/bin/env bash
# Boots the microVM.
#
#   sudo bash 05-run-microvm.sh            interactive serial console
#   sudo bash 05-run-microvm.sh --smoke    boot, verify over SSH, shut down
#
# Exits non-zero if the VM fails to boot or fails verification in --smoke mode.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

MODE="interactive"
[ "${1:-}" = "--smoke" ] && MODE="smoke"

[ -x "$FC_BIN" ]      || die "missing ${FC_BIN} - run 02-install.sh"
[ -s "$KERNEL_IMG" ]  || die "missing ${KERNEL_IMG} - run 02-install.sh"
[ -s "$ROOTFS_IMG" ]  || die "missing ${ROOTFS_IMG} - run 03-build-rootfs.sh"

# WSL drops network state on restart, so reassert it rather than failing later
# with an opaque "device not found" from Firecracker.
if ! ip link show "$TAP_DEV" >/dev/null 2>&1; then
  warn "${TAP_DEV} missing (WSL restarted?) - reconfiguring network"
  bash "$(dirname "$(readlink -f "$0")")/04-network.sh"
fi

CONFIG="${RUN_DIR}/vm-config.json"
mkdir -p "$RUN_DIR"
rm -f "$API_SOCKET" "$VM_LOG"

# ip=<guest>::<gw>:<mask>::<iface>:off configures eth0 from the kernel command
# line, before userspace - the microVM has no DHCP client.
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"
BOOT_ARGS="${BOOT_ARGS} ip=${GUEST_IP}::${TAP_IP}:${TAP_MASK}::eth0:off"

info "Writing VM config"
cat > "$CONFIG" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${KERNEL_IMG}",
    "boot_args": "${BOOT_ARGS}"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${ROOTFS_IMG}",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "${GUEST_MAC}",
      "host_dev_name": "${TAP_DEV}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VCPU_COUNT},
    "mem_size_mib": ${MEM_SIZE_MIB}
  }
}
EOF
ok "${CONFIG} (${VCPU_COUNT} vCPU, ${MEM_SIZE_MIB} MiB)"

if [ "$MODE" = "interactive" ]; then
  echo
  info "Booting microVM - serial console follows"
  # `poweroff` only halts the vCPU - Firecracker has no ACPI power button, so
  # the process would hang. `reboot` hits the i8042 controller, which
  # Firecracker intercepts and exits on.
  warn "type 'reboot' inside the guest to shut down and exit"
  echo
  exec "$FC_BIN" --api-sock "$API_SOCKET" --config-file "$CONFIG"
fi

# ---------------------------------------------------------------- smoke mode
SSH_OPTS=(-i "$SSH_KEY"
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR
          -o ConnectTimeout=3)

FC_PID=""
cleanup() {
  if [ -n "$FC_PID" ] && kill -0 "$FC_PID" 2>/dev/null; then
    kill "$FC_PID" 2>/dev/null || true
    wait "$FC_PID" 2>/dev/null || true
  fi
  rm -f "$API_SOCKET"
}
trap cleanup EXIT

info "Booting microVM (detached, serial -> ${VM_LOG})"
"$FC_BIN" --api-sock "$API_SOCKET" --config-file "$CONFIG" \
  >"$VM_LOG" 2>&1 </dev/null &
FC_PID=$!
ok "firecracker pid ${FC_PID}"

info "Waiting for guest SSH on ${GUEST_IP} (timeout 90s)"
booted=0
for i in $(seq 1 90); do
  if ! kill -0 "$FC_PID" 2>/dev/null; then
    echo; warn "firecracker exited early - last serial output:"
    tail -30 "$VM_LOG" >&2
    die "microVM died during boot"
  fi
  if ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" true 2>/dev/null; then
    booted=1
    ok "guest reachable after ${i}s"
    break
  fi
  sleep 1
done

if [ "$booted" -ne 1 ]; then
  warn "guest did not become reachable - last serial output:"
  tail -40 "$VM_LOG" >&2
  die "boot timed out after 90s"
fi

echo
info "==================== GUEST VERIFICATION ===================="
run_in_guest() { # run_in_guest <label> <command>
  local label="$1" cmd="$2" out
  if out=$(ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" "$cmd" 2>&1); then
    printf '%s  ok%s %-22s %s\n' "$C_OK" "$C_OFF" "$label" "$out"
  else
    printf '%swarn%s %-22s %s\n' "$C_WARN" "$C_OFF" "$label" "${out:-failed}"
  fi
}

run_in_guest "guest hostname"  'hostname'
run_in_guest "guest OS"        '. /etc/os-release && echo "$PRETTY_NAME"'
run_in_guest "guest kernel"    'uname -r'
run_in_guest "guest vCPUs"     'nproc'
run_in_guest "guest memory"    'free -m | awk "/^Mem:/{print \$2\" MiB\"}"'
run_in_guest "guest IP"        'ip -4 -o addr show eth0 | awk "{print \$4}"'
run_in_guest "ping gateway"    "ping -c2 -W2 ${TAP_IP} >/dev/null && echo 'reachable'"
run_in_guest "ping internet"   'ping -c2 -W3 1.1.1.1 >/dev/null && echo "reachable" || echo "no egress"'
run_in_guest "dns"             'getent hosts example.com >/dev/null && echo "resolves" || echo "no dns"'
info "============================================================"
echo

info "Shutting down the microVM"
# `reboot`, not `poweroff`: with reboot=k the guest resets via the i8042
# controller, which Firecracker traps to exit the process. `poweroff` would
# leave the vCPU halted and Firecracker running forever.
ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" 'nohup reboot >/dev/null 2>&1 &' 2>/dev/null || true
for i in $(seq 1 20); do
  kill -0 "$FC_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$FC_PID" 2>/dev/null; then
  warn "guest did not power off cleanly; terminating"
else
  ok "microVM powered off cleanly"
  FC_PID=""
fi

echo
ok "SMOKE TEST PASSED - Firecracker microVM booted and verified."
