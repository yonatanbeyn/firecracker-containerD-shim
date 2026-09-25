# Troubleshooting

Failure modes seen on this setup, and what actually fixes them.

## Preflight failures

### `nested virtualization (vmx flag)` FAILS

`/proc/cpuinfo` in WSL has no `vmx` flag, so KVM cannot work.

1. **Enable virtualization in UEFI/BIOS.** Intel VT-x must be on.
2. **Enable nested virtualization for WSL2.** Create `%USERPROFILE%\.wslconfig`:
   ```ini
   [wsl2]
   nestedVirtualization=true
   ```
   Then `wsl --shutdown` and reopen. On Windows 11 this is the default, so an
   explicit `.wslconfig` is only needed if something disabled it.
3. **Confirm you are on WSL2, not WSL1:** `wsl --list --verbose` must show
   `VERSION 2`. Convert with `wsl --set-version Ubuntu 2`.

> Note: `Get-CimInstance Win32_Processor` on Windows reports
> `VirtualizationFirmwareEnabled: False` whenever Hyper-V is already running,
> because Windows itself is then a guest. This is **not** a real failure — check
> for `vmx` inside WSL instead, which is what `01-preflight.sh` does.

### `/dev/kvm exists` FAILS

The WSL kernel was built without KVM. Update WSL:

```powershell
wsl --update
wsl --shutdown
```

### `warn /dev/kvm not accessible as <user>`

Cosmetic here — these scripts run Firecracker as root. To run unprivileged:

```powershell
wsl -d Ubuntu -u root -- usermod -aG kvm <user>
wsl --shutdown
```

Group changes need a full WSL restart, not just a new shell.

## Boot failures

### `microVM died during boot`

Read the serial log, which holds the guest's own output:

```powershell
wsl -d Ubuntu -u root -- tail -50 /srv/firecracker/run/firecracker.log
```

Common causes:

| Symptom in log | Cause | Fix |
|---|---|---|
| `Cannot create socket` / `Address in use` | Stale API socket, or work tree on `/mnt/c` | `rm /srv/firecracker/run/firecracker.socket`; keep the work tree off `/mnt/c` |
| `No such device (os error 19)` | TAP device missing after `wsl --shutdown` | Re-run `04-network.sh` |
| `VFS: Unable to mount root fs` | rootfs image missing or corrupt | Re-run `03-build-rootfs.sh` |
| `Kernel panic - not syncing` | Wrong kernel format | Kernel must be an uncompressed `vmlinux` ELF, not `bzImage` |

### Boot times out after 90s

The VM may be up but unreachable. Check whether it booted at all:

```powershell
wsl -d Ubuntu -u root -- tail -20 /srv/firecracker/run/firecracker.log
```

- If you see a login prompt, the guest booted and the problem is networking —
  re-run `04-network.sh`.
- If the log stops mid-boot, a guest service is hanging. `03-build-rootfs.sh`
  masks the usual culprits (`cloud-init`, `snapd`,
  `systemd-networkd-wait-online`); add any new offender to that list.

## Networking

### Guest cannot reach the internet

```powershell
# All three must be true
wsl -d Ubuntu -u root -- ip addr show fc-tap0
wsl -d Ubuntu -u root -- sysctl net.ipv4.ip_forward
wsl -d Ubuntu -u root -- iptables -t nat -L POSTROUTING -n -v
```

Re-running `04-network.sh` reasserts all three. It is idempotent and will not
duplicate rules.

### Everything broke after `wsl --shutdown`

Expected. The TAP device, forwarding sysctl and NAT rules are runtime-only
state that WSL does not persist. `05-run-microvm.sh` detects the missing TAP
device and re-runs `04-network.sh` itself, so normally this self-heals.

### Guest IP conflicts with something on your LAN

Edit `TAP_IP` / `GUEST_IP` in `scripts/common.sh`, then re-run `04-network.sh`.
The `/30` subnet only needs to avoid overlapping your real networks.

## Firecracker process will not exit

`poweroff` inside the guest halts the vCPU but leaves Firecracker running,
because Firecracker exposes no ACPI power button. Use `reboot` instead — with
`reboot=k` the guest resets through the i8042 controller, which Firecracker
traps and exits on.

To kill a stuck instance:

```powershell
wsl -d Ubuntu -u root -- pkill -f /srv/firecracker/bin/firecracker
```

## firecracker-containerd (layer 2)

Start with `.\lambda.ps1 -Status`, then `journalctl -u firecracker-containerd -n 50`.

### `The current CPU model is not permitted to apply the CPU template`

Firecracker refuses upstream's `T2` CPU template on 13th-gen Intel and newer.
Note that **omitting** `cpu_template` does not avoid this — `config.go` defaults
to `T2`. It must be set explicitly:

```json
"cpu_template": "None"
```

in `/etc/containerd/firecracker-runtime.json`. `13-configure-containerd.sh`
already does this.

### `failed to dial the VM over vsock: connection refused`

The VM started but the agent inside never came up, so the shim had nothing to
talk to. Almost always the guest failed to boot. The shim discards the guest
console, so reproduce it with plain Firecracker to see why:

```powershell
wsl -d Ubuntu -u root -- bash -c 'cat > /srv/firecracker/run/dbg.json <<EOF
{
  "boot-source": {
    "kernel_image_path": "/var/lib/firecracker-containerd/runtime/default-vmlinux.bin",
    "boot_args": "ro console=ttyS0 reboot=k panic=1 pci=off nomodules systemd.unified_cgroup_hierarchy=0 systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init"
  },
  "drives": [{ "drive_id": "rootfs", "path_on_host": "/var/lib/firecracker-containerd/runtime/default-rootfs.img", "is_root_device": true, "is_read_only": true }],
  "machine-config": { "vcpu_count": 2, "mem_size_mib": 1024 }
}
EOF
rm -f /srv/firecracker/run/dbg.sock
timeout 30 /usr/local/bin/firecracker --api-sock /srv/firecracker/run/dbg.sock --config-file /srv/firecracker/run/dbg.json < /dev/null 2>&1 | tail -40'
```

A healthy boot reaches a login prompt in ~1.5 s and logs
`agent[...]: msg="creating task service"`.

### `VFS: Cannot open root device "vda"` / kernel panic on boot

Caused by `noapic` in the kernel args. It predates ACPI support in Firecracker;
with v1.12 and an ACPI-enabled guest kernel it breaks virtio enumeration.
Remove it from `kernel_args` in `/etc/containerd/firecracker-runtime.json`.

Upstream docs still include `noapic` because their reference images use the
older no-ACPI kernels (see the `-no-acpi` variants in the CI bucket).

### Container has only `lo`, no network

Run with `--net-host`. In this context "host" is the **microVM**, not the
Windows/WSL host, so the container joins the VM's namespace and picks up the
CNI-assigned `eth0`. Without it the container gets an empty namespace.

### DNS fails inside the microVM but IP traffic works

The container has no `/etc/resolv.conf`. `ctr` is a low-level client and does
not synthesise one the way Docker does.

Also note WSL's own `/etc/resolv.conf` holds `nameserver 10.255.255.254`, a
WSL-internal address that does **not** resolve from inside a guest — so
pointing CNI at it silently produces a broken resolver.

The setup writes a resolv.conf into the guest rootfs and bind-mounts it:

```
--mount type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro
```

Verify with `.\lambda.ps1 -Command 'cat /etc/resolv.conf; nslookup example.com'`.

### `devmapper` snapshotter not loading

```powershell
wsl -d Ubuntu -u root -- dmsetup targets
```

`thin-pool` and `thin` must both be listed. If they are missing, the WSL kernel
lacks thin-provisioning and the devmapper snapshotter cannot work — `wsl --update`
and retry.

If the targets exist but the pool does not:

```powershell
wsl -d Ubuntu -u root -- systemctl restart fcc-thinpool.service
wsl -d Ubuntu -u root -- journalctl -u fcc-thinpool -n 30
```

### Thin pool is busy and will not delete

Shims outlive containerd and hold snapshot devices open:

```powershell
wsl -d Ubuntu -u root -- pkill -f containerd-shim-aws-firecracker
wsl -d Ubuntu -u root -- bash /mnt/c/Users/Yonat/desktop/firecracker-script/scripts/teardown.sh
```

### Image pull fails

The pull happens on the WSL host, not in a VM, so it uses WSL's network.
Check `wsl -d Ubuntu -- curl -sI https://registry-1.docker.io/v2/`. Rate limits
from Docker Hub surface as 429s in the containerd log.

### Build fails: `go: module requires go >= 1.25`

Ubuntu's packaged Go is too old. `10-install-toolchain.sh` installs Go 1.27.1
to `/usr/local/go`; make sure it ran and that `/usr/local/bin/go` resolves there.

### `go install pkg@version` fails with "exclude directives"

containerd's `go.mod` carries `exclude` directives, which `go install` refuses.
`ctr` is taken from the official containerd release tarball instead. This is
already handled in `11-build-firecracker-containerd.sh`.

## Starting over

```powershell
wsl -d Ubuntu -u root -- bash /mnt/c/Users/Yonat/desktop/firecracker-script/scripts/teardown.sh --purge
.\setup.ps1
.\lambda.ps1 -Setup
```

`--purge` deletes `/srv/firecracker` and `/var/lib/firecracker-containerd`
entirely, forcing a full rebuild and re-download. Go and the CNI plugins are
left in place, so the second build is much faster than the first.
