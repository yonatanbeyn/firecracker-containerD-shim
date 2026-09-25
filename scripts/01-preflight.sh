#!/usr/bin/env bash
# Verifies this WSL2 distro can actually run Firecracker before anything is
# downloaded. Read-only: makes no changes.

source "$(dirname "$(readlink -f "$0")")/common.sh"

fail_count=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    printf '%sFAIL%s %s\n' "$C_ERR" "$C_OFF" "$label" >&2
    fail_count=$((fail_count + 1))
  fi
}

info "Firecracker preflight"
echo

info "Platform"
echo "     distro : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "     kernel : $(uname -r)"
echo "       arch : $(uname -m)"
echo "       user : $(id -un) (uid $(id -u))"
echo

info "Hard requirements"
check "x86_64 architecture"              test "$(uname -m)" = "x86_64"
check "running under WSL2"               grep -qi microsoft /proc/version
check "nested virtualization (vmx flag)" grep -q '\bvmx\b' /proc/cpuinfo
check "/dev/kvm exists"                  test -e /dev/kvm
check "/dev/net/tun exists"              test -e /dev/net/tun
echo

info "KVM access"
if [ -e /dev/kvm ]; then
  echo "      perms : $(stat -c '%A %U:%G' /dev/kvm)"
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm is read-write for $(id -un)"
  else
    warn "/dev/kvm not accessible as $(id -un); 02-install.sh will add you to the 'kvm' group."
    warn "These scripts run Firecracker under sudo, so this does not block setup."
  fi
fi
echo

info "Required tools"
# Only tools that cannot be auto-installed are hard failures.
for t in curl ip; do
  check "$t" command -v "$t"
done
for t in iptables unsquashfs mkfs.ext4 ssh-keygen truncate; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t"
  else
    warn "$t missing - 02-install.sh will install it"
  fi
done
echo

info "Disk space on $(df -P / | awk 'NR==2{print $6}')"
echo "      avail : $(df -Ph / | awk 'NR==2{print $4}')"
echo

if [ "$fail_count" -gt 0 ]; then
  die "$fail_count hard requirement(s) failed - see docs/TROUBLESHOOTING.md"
fi

ok "Preflight passed - this machine can run Firecracker."
