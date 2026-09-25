#!/usr/bin/env bash
# Runs a real, long-lived workload in a microVM and proves it serves traffic.
#
# Scripts 14-* run a command and exit, which only exercises egress. This one
# starts a persistent service, discovers its address, and connects to it FROM
# THE HOST - the ingress path a Lambda-style workload actually depends on.
#
#   sudo bash 15-run-service.sh              nginx, verify, tear down
#   sudo bash 15-run-service.sh --keep       leave it running
#   sudo bash 15-run-service.sh --image IMG --port N
#   sudo bash 15-run-service.sh --stop       tear down a --keep'd service

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

IMAGE="docker.io/library/nginx:alpine"
PORT=80
CID="fc-service"
KEEP=0
STOP=0
PUBLISH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --image)   IMAGE="$2"; shift 2 ;;
    --port)    PORT="$2";  shift 2 ;;
    --name)    CID="$2";   shift 2 ;;
    --keep)    KEEP=1;     shift ;;
    --stop)    STOP=1;     shift ;;
    --publish) PUBLISH="$2"; KEEP=1; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

PUBLISH_UNIT="fc-publish-${PUBLISH}"

CTR="/usr/local/bin/firecracker-ctr --address ${FCC_SOCK}"
[ -S "$FCC_SOCK" ] || die "firecracker-containerd not running - run 13-configure-containerd.sh"

cleanup_container() {
  $CTR task kill -s SIGKILL "$CID" >/dev/null 2>&1 || true
  sleep 1
  $CTR task rm "$CID"        >/dev/null 2>&1 || true
  $CTR container rm "$CID"   >/dev/null 2>&1 || true
}

if [ "$STOP" -eq 1 ]; then
  info "Stopping service '${CID}'"
  cleanup_container
  # Tear down any publish proxies this script created.
  for u in $(systemctl list-units --plain --no-legend 'fc-publish-*' 2>/dev/null | awk '{print $1}'); do
    systemctl stop "$u" >/dev/null 2>&1 && ok "stopped ${u}"
  done
  ok "stopped and removed"
  exit 0
fi

# A previous run may have left the container behind.
cleanup_container

info "Pulling ${IMAGE}"
if $CTR images ls -q 2>/dev/null | grep -qx "$IMAGE"; then
  ok "already pulled"
else
  $CTR image pull --snapshotter devmapper "$IMAGE" >/dev/null \
    || die "image pull failed"
  ok "pulled"
fi

info "Starting '${CID}' detached in a microVM"
$CTR run -d --snapshotter devmapper --runtime aws.firecracker --net-host \
  --mount "type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro" \
  "$IMAGE" "$CID" \
  || die "failed to start container"

# Only tear down on failure; on success honour --keep.
trap 'cleanup_container' EXIT

info "Waiting for the task to reach RUNNING"
state=""
for i in $(seq 1 60); do
  state="$($CTR task ls 2>/dev/null | awk -v c="$CID" '$1==c{print $3}')"
  [ "$state" = "RUNNING" ] && break
  sleep 1
done
[ "$state" = "RUNNING" ] || die "task did not start (state='${state:-none}')"
ok "task RUNNING"

# Ask the guest for its own address rather than parsing CNI's allocation
# files - this also proves `task exec` works into a live microVM.
info "Discovering the microVM's IP"
guest_ip=""
for i in $(seq 1 20); do
  guest_ip="$($CTR task exec --exec-id "probe${i}" "$CID" \
              ip -4 -o addr show eth0 2>/dev/null \
              | awk '{print $4}' | cut -d/ -f1 | tr -d '\r')"
  [ -n "$guest_ip" ] && break
  sleep 1
done
[ -n "$guest_ip" ] || die "could not determine guest IP"
ok "microVM address: ${guest_ip}"

info "Connecting from the HOST to ${guest_ip}:${PORT}"
http_code=""
body=""
for i in $(seq 1 30); do
  http_code="$(curl -s -o /tmp/fc-svc-body -w '%{http_code}' \
                --max-time 3 "http://${guest_ip}:${PORT}/" 2>/dev/null || true)"
  [ "$http_code" = "200" ] && break
  sleep 1
done
body="$(head -c 200 /tmp/fc-svc-body 2>/dev/null)"
rm -f /tmp/fc-svc-body

echo
info "==================== REAL WORKLOAD VERIFICATION ===================="
row() { printf '%s  ok%s %-24s %s\n' "$C_OK" "$C_OFF" "$1" "$2"; }
bad() { printf '%sFAIL%s %-24s %s\n' "$C_ERR" "$C_OFF" "$1" "$2"; }

row "image"            "$IMAGE"
row "guest kernel"     "$($CTR task exec --exec-id k "$CID" uname -r 2>/dev/null | tr -d '\r')"
row "host kernel"      "$(uname -r)"
row "microVM IP"       "$guest_ip"

if [ "$http_code" = "200" ]; then
  row "HTTP host -> microVM" "200 OK"
  row "response"             "$(printf '%s' "$body" | tr -d '\n' | head -c 60)..."
else
  bad "HTTP host -> microVM" "got '${http_code:-no response}' (expected 200)"
  info "==================================================================="
  die "service is not reachable from the host"
fi

# Serve a second request to show the VM persists between connections, which is
# what separates a service from the one-shot runs in 14-run-lambda-vm.sh.
srv="$(curl -s --max-time 3 -D- -o /dev/null "http://${guest_ip}:${PORT}/" \
        2>/dev/null | sed -n 's/^[Ss]erver: //p' | tr -d '\r')"
row "second request"   "ok (VM persists) - Server: ${srv:-unknown}"
info "==================================================================="
echo

# --- optional: expose the service to Windows -------------------------------
# The microVM subnet sits behind WSL's NAT, so Windows cannot route to
# 192.168.127.0/24 directly. WSL2 does forward *listening sockets* in the
# distro to Windows' localhost, so a userspace relay bridges the gap. It must
# be a systemd unit: a backgrounded process dies when the wsl.exe session ends.
if [ "$PUBLISH" != "0" ]; then
  info "Publishing to Windows on localhost:${PUBLISH}"
  command -v socat >/dev/null 2>&1 || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null 2>&1 \
      || die "failed to install socat"
  }
  systemctl stop "$PUBLISH_UNIT" >/dev/null 2>&1 || true
  systemd-run --unit="$PUBLISH_UNIT" --collect \
    socat "TCP-LISTEN:${PUBLISH},fork,reuseaddr" "TCP:${guest_ip}:${PORT}" \
    >/dev/null 2>&1 || die "failed to start publish relay"
  sleep 1
  if [ "$(systemctl is-active "$PUBLISH_UNIT")" = "active" ]; then
    ok "relay active: WSL:${PUBLISH} -> ${guest_ip}:${PORT}"
    local_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                  "http://127.0.0.1:${PUBLISH}/" 2>/dev/null || true)"
    if [ "$local_code" = "200" ]; then
      ok "relay verified from inside WSL (HTTP ${local_code})"
      info "From Windows: http://localhost:${PUBLISH}/"
    else
      warn "relay returned '${local_code}' from inside WSL"
    fi
  else
    warn "relay unit failed to start"
  fi
  echo
fi

if [ "$KEEP" -eq 1 ]; then
  trap - EXIT
  ok "SERVICE RUNNING at http://${guest_ip}:${PORT}/"
  echo
  info "From WSL:     curl http://${guest_ip}:${PORT}/"
  info "Exec a shell: firecracker-ctr --address ${FCC_SOCK} task exec --exec-id sh -t ${CID} /bin/sh"
  info "Stop it:      sudo bash 15-run-service.sh --stop"
else
  ok "REAL WORKLOAD VERIFIED - service served HTTP from inside a microVM."
  info "tearing down (pass --keep to leave it running)"
fi
