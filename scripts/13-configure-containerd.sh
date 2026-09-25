#!/usr/bin/env bash
# Configures firecracker-containerd: thin pool, containerd config, the
# aws.firecracker runtime, CNI networking, and systemd units.
#
# This stack is deliberately isolated from any other containerd on the box -
# its own socket, root, state dir and snapshotter - so Docker Desktop and a
# system containerd are unaffected.

source "$(dirname "$(readlink -f "$0")")/common.sh"
need_root

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

for b in /usr/local/bin/firecracker-containerd \
         /usr/local/bin/containerd-shim-aws-firecracker \
         /usr/local/bin/firecracker; do
  [ -x "$b" ] || die "missing ${b} - run 11 and 12 first"
done
[ -s "$FCC_ROOTFS" ] || die "missing ${FCC_ROOTFS} - run 12-build-agent-rootfs.sh"
[ -s "$FCC_KERNEL" ] || die "missing ${FCC_KERNEL} - run 12-build-agent-rootfs.sh"

info "Creating directories"
mkdir -p "$FCC_ETC" "$FCC_VAR/containerd" "$FCC_SHIM_BASE" \
         "$FCC_SNAPSHOTTER_DIR" "$FCC_STATE" "$CNI_CONF_DIR" /etc/containerd
ok "directories ready"

# --- thin pool ---------------------------------------------------------------
info "Installing thin-pool setup script"
install -m755 "${SCRIPT_DIR}/fcc-thinpool-setup.sh" /usr/local/sbin/fcc-thinpool-setup
ok "/usr/local/sbin/fcc-thinpool-setup"

cat > /etc/systemd/system/fcc-thinpool.service <<EOF
[Unit]
Description=Device-mapper thin pool for firecracker-containerd
Before=firecracker-containerd.service
After=local-fs.target
Requires=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=POOL_NAME=${DM_POOL_NAME}
Environment=DIR=${FCC_SNAPSHOTTER_DIR}
Environment=DATA_SIZE=${DM_DATA_SIZE_GB}G
Environment=META_SIZE=${DM_META_SIZE_MB}M
ExecStart=/usr/local/sbin/fcc-thinpool-setup

[Install]
WantedBy=multi-user.target
EOF
ok "fcc-thinpool.service written"

# --- containerd config -------------------------------------------------------
info "Writing ${FCC_ETC}/config.toml"
cat > "${FCC_ETC}/config.toml" <<EOF
version = 2
# CRI is for Kubernetes; this stack does not need it and it fails noisily
# without a CNI setup of its own.
disabled_plugins = ["io.containerd.grpc.v1.cri"]
root = "${FCC_VAR}/containerd"
state = "${FCC_STATE}"

[grpc]
  address = "${FCC_SOCK}"

[plugins]
  [plugins."io.containerd.snapshotter.v1.devmapper"]
    pool_name = "${DM_POOL_NAME}"
    base_image_size = "10GB"
    root_path = "${FCC_SNAPSHOTTER_DIR}"

[debug]
  level = "info"
EOF
ok "containerd config written"

# --- runtime config ----------------------------------------------------------
info "Writing ${FCC_RUNTIME_CFG}"
# cpu_template MUST be set explicitly to "None".
#
# Upstream examples use "T2", a static Skylake-era Intel template, and
# config.go defaults to T2 when the field is absent - so leaving it out does
# not avoid it. Firecracker rejects T2 on newer Intel parts (13th gen and up):
#   "The current CPU model is not permitted to apply the CPU template."
# "None" passes the host CPU through, which is what a local dev box wants.
# Set this back to T2/T2CL only if you need CPUID stability for snapshot
# migration across heterogeneous hardware.
#
# kernel_args also drops upstream's "noapic". That flag predates ACPI support
# in Firecracker; with Firecracker v1.12 and the ACPI-enabled 6.1 guest kernel
# it breaks virtio device enumeration, and the guest panics with:
#   VFS: Cannot open root device "vda" or unknown-block(0,0)
# Upstream still carries it because their reference images use the older
# no-ACPI kernels (note the "-no-acpi" kernel variants in the CI bucket).
cat > "$FCC_RUNTIME_CFG" <<EOF
{
  "firecracker_binary_path": "/usr/local/bin/firecracker",
  "cpu_template": "None",
  "kernel_image_path": "${FCC_KERNEL}",
  "kernel_args": "ro console=ttyS0 reboot=k panic=1 pci=off nomodules systemd.unified_cgroup_hierarchy=0 systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init",
  "root_drive": "${FCC_ROOTFS}",
  "log_levels": ["info"],
  "shim_base_dir": "${FCC_SHIM_BASE}",
  "default_network_interfaces": [
    {
      "CNIConfig": {
        "NetworkName": "fcnet",
        "InterfaceName": "veth0"
      }
    }
  ]
}
EOF
ok "aws.firecracker runtime configured"

# --- CNI ---------------------------------------------------------------------
info "Writing CNI network 'fcnet'"
# Upstream points ipam.resolvConf at the host's /etc/resolv.conf. Under WSL
# that file contains only "nameserver 10.255.255.254" - a WSL-internal NAT
# address that does not exist from inside a microVM, so guests end up with no
# working resolver. Hand CNI a resolv.conf with publicly routable servers.
cat > "${CNI_CONF_DIR}/fc-resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
ok "${CNI_CONF_DIR}/fc-resolv.conf (guest resolver)"

# Subnet differs from upstream's 192.168.1.0/24, which collides with the most
# common home LAN range and would silently break host connectivity.
cat > "${CNI_CONF_DIR}/fcnet.conflist" <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "fcnet",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "fc-br0",
      "isDefaultGateway": true,
      "forceAddress": false,
      "ipMasq": true,
      "hairpinMode": true,
      "mtu": 1500,
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.127.0/24",
        "resolvConf": "/etc/cni/conf.d/fc-resolv.conf"
      }
    },
    { "type": "firewall" },
    { "type": "tc-redirect-tap" },
    { "type": "loopback" }
  ]
}
EOF
ok "${CNI_CONF_DIR}/fcnet.conflist (192.168.127.0/24)"

for p in bridge host-local firewall loopback tc-redirect-tap; do
  [ -x "${CNI_BIN_DIR}/${p}" ] || die "missing CNI plugin '${p}' - run 11"
done
ok "all required CNI plugins present"

# --- systemd service ---------------------------------------------------------
info "Writing firecracker-containerd.service"
cat > /etc/systemd/system/firecracker-containerd.service <<EOF
[Unit]
Description=firecracker-containerd (containerd + firecracker-control)
Documentation=https://github.com/firecracker-microvm/firecracker-containerd
After=fcc-thinpool.service network.target
Requires=fcc-thinpool.service

[Service]
ExecStart=/usr/local/bin/firecracker-containerd --config ${FCC_ETC}/config.toml
Restart=always
RestartSec=2
Delegate=yes
KillMode=process
LimitNOFILE=1048576
# containerd manages its own children's OOM scores.
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
ok "firecracker-containerd.service written"

info "Enabling and starting services"
systemctl daemon-reload
systemctl enable -q fcc-thinpool.service firecracker-containerd.service
systemctl restart fcc-thinpool.service || die "thin pool setup failed - journalctl -u fcc-thinpool"
ok "thin pool active: $(dmsetup info "$DM_POOL_NAME" | awk '/^State:/{print $2}')"

systemctl restart firecracker-containerd.service
# Give containerd a moment to bind its socket before declaring success.
for i in $(seq 1 20); do
  [ -S "$FCC_SOCK" ] && break
  sleep 0.5
done
if [ ! -S "$FCC_SOCK" ]; then
  warn "containerd socket not up - recent logs:"
  journalctl -u firecracker-containerd -n 25 --no-pager
  die "firecracker-containerd failed to start"
fi
ok "firecracker-containerd listening on ${FCC_SOCK}"

info "Verifying snapshotter"
if /usr/local/bin/firecracker-ctr --address "$FCC_SOCK" plugins ls 2>/dev/null \
     | grep -q "devmapper.*ok"; then
  ok "devmapper snapshotter loaded"
else
  warn "devmapper snapshotter not reporting ok:"
  /usr/local/bin/firecracker-ctr --address "$FCC_SOCK" plugins ls 2>&1 \
    | grep -i devmapper || true
fi

echo
ok "Configuration complete. Next: sudo bash 14-run-lambda-vm.sh"
