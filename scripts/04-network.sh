#!/usr/bin/env bash
# Creates the TAP device the microVM attaches to and NATs guest traffic out
# through WSL's uplink. Idempotent: safe to re-run.
#
# WSL2 does not persist network state across `wsl --shutdown`, so this must be
# re-run after every WSL restart. 05-run-microvm.sh calls it automatically.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

# Interface holding the default route - WSL's NAT uplink, usually eth0.
UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$UPLINK" ] || die "no default route found; WSL has no network uplink"
info "Uplink interface: ${UPLINK}"

info "Configuring TAP device ${TAP_DEV}"
if ip link show "$TAP_DEV" >/dev/null 2>&1; then
  ip link del "$TAP_DEV"
fi
ip tuntap add dev "$TAP_DEV" mode tap
ip addr add "${TAP_IP}/${TAP_PREFIX}" dev "$TAP_DEV"
ip link set "$TAP_DEV" up
ok "${TAP_DEV} up at ${TAP_IP}/${TAP_PREFIX} (guest: ${GUEST_IP})"

info "Enabling IPv4 forwarding"
sysctl -q -w net.ipv4.ip_forward=1
ok "net.ipv4.ip_forward=1"

# -C tests for an existing identical rule, so re-runs do not stack duplicates.
add_rule() { # add_rule <table> <chain> <rule...>
  local table="$1" chain="$2"; shift 2
  if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    ok "rule already present: ${chain} $*"
  else
    iptables -t "$table" -A "$chain" "$@"
    ok "added rule: ${chain} $*"
  fi
}

info "Installing NAT rules"
add_rule nat POSTROUTING -o "$UPLINK" -s "${TAP_IP}/${TAP_PREFIX}" -j MASQUERADE
add_rule filter FORWARD -i "$TAP_DEV" -o "$UPLINK" -j ACCEPT
add_rule filter FORWARD -i "$UPLINK" -o "$TAP_DEV" \
  -m state --state RELATED,ESTABLISHED -j ACCEPT

echo
ok "Network ready. Next: sudo bash 05-run-microvm.sh"
