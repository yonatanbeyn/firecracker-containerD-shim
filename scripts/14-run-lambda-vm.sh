#!/usr/bin/env bash
# Runs an OCI container inside a Firecracker microVM via firecracker-containerd.
#
#   sudo bash 14-run-lambda-vm.sh                    verify the stack end to end
#   sudo bash 14-run-lambda-vm.sh --image IMG --cmd "..."   run something custom
#   sudo bash 14-run-lambda-vm.sh --bench 5          cold-start timing over 5 microVMs
#   sudo bash 14-run-lambda-vm.sh --shell            interactive shell in a microVM
#
# The proof that this is a real microVM and not a container on the host: the
# kernel reported inside is the Firecracker guest kernel (6.1.x), not WSL's
# 5.15.x. Each invocation boots its own VM with its own kernel.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

IMAGE="docker.io/library/alpine:3.20"
CMD=""
BENCH=0
SHELL_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --cmd)   CMD="$2";   shift 2 ;;
    --bench) BENCH="$2"; shift 2 ;;
    --shell) SHELL_MODE=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

CTR="/usr/local/bin/firecracker-ctr --address ${FCC_SOCK}"
RUNTIME="aws.firecracker"
SNAPSHOTTER="devmapper"

[ -S "$FCC_SOCK" ] || die "firecracker-containerd is not running - run 13-configure-containerd.sh"

info "Stack status"
echo "     containerd : $(/usr/local/bin/firecracker-containerd --version | head -1)"
echo "      thin pool : $(dmsetup info "$DM_POOL_NAME" 2>/dev/null | awk '/^State:/{print $2}' || echo MISSING)"
echo "     host kernel: $(uname -r)"
echo

info "Pulling ${IMAGE}"
if $CTR images ls -q 2>/dev/null | grep -qx "$IMAGE"; then
  ok "already pulled"
else
  $CTR image pull --snapshotter "$SNAPSHOTTER" "$IMAGE" >/dev/null \
    || die "image pull failed"
  ok "pulled ${IMAGE}"
fi

# --net-host puts the container in the *microVM's* network namespace, not the
# real host's. That is what gives it the CNI-assigned eth0; without it the
# container gets an empty namespace with only loopback. Still fully isolated
# from the WSL host, since the "host" here is the guest VM.
#
# The resolv.conf bind mount comes from the microVM's rootfs (written by
# 12-build-agent-rootfs.sh). ctr, unlike Docker, does not generate one for the
# container, so without this the container has no resolver at all.
RESOLV_MOUNT="type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro"

run_vm() { # run_vm <container-id> <command...>
  local cid="$1"; shift
  $CTR run --snapshotter "$SNAPSHOTTER" --runtime "$RUNTIME" --rm --net-host \
    --mount "$RESOLV_MOUNT" "$IMAGE" "$cid" "$@"
}

# ----------------------------------------------------------------- shell mode
if [ "$SHELL_MODE" -eq 1 ]; then
  cid="fc-shell-$$"
  info "Starting interactive microVM (container ${cid})"
  warn "type 'exit' to shut the microVM down"
  echo
  exec $CTR run --snapshotter "$SNAPSHOTTER" --runtime "$RUNTIME" --rm \
    --net-host --mount "$RESOLV_MOUNT" --tty "$IMAGE" "$cid" /bin/sh
fi

# ----------------------------------------------------------------- bench mode
if [ "$BENCH" -gt 0 ]; then
  info "Cold-start benchmark: ${BENCH} sequential microVMs"
  echo
  total=0
  for i in $(seq 1 "$BENCH"); do
    cid="fc-bench-${$}-${i}"
    start=$(date +%s%N)
    run_vm "$cid" /bin/true >/dev/null 2>&1 || warn "run ${i} failed"
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    total=$(( total + ms ))
    printf '       microVM %-3s boot + run + teardown : %5s ms\n' "$i" "$ms"
  done
  echo
  ok "mean over ${BENCH} runs: $(( total / BENCH )) ms"
  exit 0
fi

# ----------------------------------------------------------------- custom cmd
if [ -n "$CMD" ]; then
  cid="fc-run-$$"
  info "Running in microVM: ${CMD}"
  echo
  run_vm "$cid" /bin/sh -c "$CMD"
  exit $?
fi

# ------------------------------------------------------------- default verify
info "Booting microVM and verifying isolation"

# Everything is gathered in a single microVM boot. Probing one fact per VM
# would be clearer to read but would boot a VM per line.
PROBE='
echo "KERNEL=$(uname -r)"
echo "OS=$(sed -n "s/^PRETTY_NAME=//p" /etc/os-release 2>/dev/null | tr -d \")"
echo "CPUS=$(nproc)"
echo "MEM=$(awk "/MemTotal/{printf \"%d MiB\", \$2/1024}" /proc/meminfo)"
echo "IP=$(ip -4 -o addr show eth0 2>/dev/null | awk "{print \$4}")"
ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo "EGRESS=reachable" || echo "EGRESS=unreachable"
(nslookup example.com >/dev/null 2>&1 || getent hosts example.com >/dev/null 2>&1) \
  && echo "DNS=resolves" || echo "DNS=failed"
'

cid="fc-verify-$$"
start=$(date +%s%N)
out="$(run_vm "$cid" /bin/sh -c "$PROBE" 2>/dev/null | tr -d '\r')"
end=$(date +%s%N)
boot_ms=$(( (end - start) / 1000000 ))

[ -n "$out" ] || die "microVM produced no output - check: journalctl -u firecracker-containerd -n 40"

field() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

guest_kernel="$(field KERNEL)"
[ -n "$guest_kernel" ] || die "microVM did not report a kernel version"

echo
info "==================== MICROVM VERIFICATION ===================="
row() { printf '%s  ok%s %-26s %s\n' "$C_OK" "$C_OFF" "$1" "$2"; }

row "guest kernel"      "$guest_kernel"
row "host (WSL) kernel" "$(uname -r)"

if [ "$guest_kernel" = "$(uname -r)" ]; then
  printf '%sFAIL%s %-26s %s\n' "$C_ERR" "$C_OFF" "isolation" \
    "guest shares the host kernel - NOT running in a microVM"
  exit 1
fi
row "isolation"    "separate kernel - genuine microVM"
row "container os" "$(field OS)"
row "guest vCPUs"  "$(field CPUS)"
row "guest memory" "$(field MEM)"
row "guest IP"     "$(field IP)"
row "internet"     "$(field EGRESS)"
row "dns"          "$(field DNS)"
row "cold start (boot+run+stop)" "${boot_ms} ms"
info "=============================================================="
echo

ok "LAMBDA-STYLE MICROVM VERIFIED - OCI image booted in its own Firecracker VM."
echo
info "Try next:"
echo "     sudo bash 14-run-lambda-vm.sh --shell"
echo "     sudo bash 14-run-lambda-vm.sh --bench 5"
echo "     sudo bash 14-run-lambda-vm.sh --image docker.io/library/python:3.12-alpine --cmd 'python3 -c \"print(2**100)\"'"
