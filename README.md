# Firecracker on Windows (via WSL2)

Reproducible setup for running [Firecracker](https://firecracker-microvm.github.io/)
microVMs on this Windows machine, in two layers:

| Layer | What you get | Entry point |
|---|---|---|
| **1. Standalone microVM** | A single Firecracker VM booting a prebuilt rootfs, with SSH and a serial console | `setup.ps1` / `run.ps1` |
| **2. Lambda-style microVMs** | [firecracker-containerd](https://github.com/firecracker-microvm/firecracker-containerd): pull any OCI image, run it in a dedicated microVM | `lambda.ps1` |

Layer 2 is what AWS Lambda and Fargate actually use: a containerd shim that
boots a fresh Firecracker VM per container, with an agent inside the guest.

> "Lambda-style" here means the **isolation model** — one microVM per workload
> — not the scheduling model. There is no warm pool, no freeze/thaw reuse and
> no enforced invocation timeout, so every run is a cold start. See
> [docs/LAMBDA-SEMANTICS.md](docs/LAMBDA-SEMANTICS.md) for what is and is not
> implemented, and what it would take to close the gap.

Firecracker needs KVM, which Windows does not provide. The path that works is
**nested virtualization**: Hyper-V runs WSL2, WSL2's kernel exposes `/dev/kvm`,
and Firecracker runs inside WSL2.

```
Windows 11 → Hyper-V → WSL2 (Ubuntu, /dev/kvm) → firecracker-containerd → microVM → your container
```

## Quick start

From PowerShell in this folder:

```powershell
.\setup.ps1          # layer 1: standalone microVM (~2 min)
.\lambda.ps1 -Setup  # layer 2: full containerd stack (~10 min, builds from source)
```

Then:

```powershell
.\lambda.ps1                  # run alpine in a microVM and verify
.\lambda.ps1 -Shell           # interactive shell inside a microVM
.\lambda.ps1 -Bench 5         # cold-start timings
.\lambda.ps1 -Status          # stack health, no VM boot
```

## Verified working state

Everything below was confirmed on this machine, not assumed.

| | |
|---|---|
| Host | Windows 11 Pro 26200.9550, Intel i9-13900H |
| WSL | 2.4.11.0, kernel 5.15.167.4-microsoft-standard-WSL2 |
| Distro | Ubuntu 24.04.2 LTS (systemd enabled) |
| Firecracker | v1.12.1 |
| firecracker-containerd | `be68640` (main @ 2026-07-16) |
| containerd | v1.7.33 |
| Guest kernel | 6.1.128 |
| Snapshotter | devmapper (thin-pool `fcc-thinpool`) |

**Layer 1:** boots to SSH in ~2 s. Guest `172.16.0.2/30`, internet + DNS working.

**Layer 2:** Alpine 3.20 and Python 3.12 OCI images both boot in their own
microVM. Guest reports kernel **6.1.128** against the host's **5.15.167.4** —
a genuinely separate kernel, not a namespaced container. Guest gets
`192.168.127.x/24` via CNI, with working internet and DNS. Cold start
(boot + run + teardown) averages **~3.2 s**.

Verified to survive `wsl --shutdown`: systemd restores the thin pool and
containerd automatically on next launch.

### Real workload

Beyond one-shot commands, `nginx:alpine` runs as a persistent service in a
microVM and serves HTTP over the full path:

```
Windows  →  localhost:8080  →  WSL relay  →  192.168.127.x:80  →  nginx in microVM
HTTP 200, Server: nginx/1.31.6
```

`.\lambda.ps1 -Publish 8080` sets this up and verifies it from Windows.

Two things this exposed that the one-shot tests did not:

- **Windows cannot route to the microVM subnet.** `192.168.127.0/24` sits
  behind WSL's NAT, so `http://192.168.127.x/` works from WSL and times out
  from Windows. WSL2 *does* forward listening sockets in the distro to Windows'
  localhost, so `--publish` runs a `socat` relay to bridge it. It has to be a
  systemd unit — a backgrounded process dies when the `wsl.exe` session ends.
- **Detached microVMs do not survive WSL's idle timeout.** The systemd services
  come back, but a running VM and its container do not. `vmIdleTimeout=-1` in
  `.wslconfig` does **not** fix this (verified ineffective on WSL 2.4.11);
  holding a session open does, so `lambda.ps1` starts a keepalive process
  automatically. Measured: service died in ~4 min without it, ran 8+ min with
  it. See `docs/LAMBDA-SEMANTICS.md`.

## Commands

### Layer 1 — standalone microVM

| Command | What it does |
|---|---|
| `.\setup.ps1` | Full setup + smoke test |
| `.\setup.ps1 -SkipSmokeTest` | Set up without booting a VM |
| `.\run.ps1` | Boot a microVM, interactive serial console |
| `.\run.ps1 -Smoke` | Boot, verify over SSH, report, shut down |
| `.\run.ps1 -Ssh` | SSH into an already-running microVM |

### Layer 2 — Lambda-style microVMs

| Command | What it does |
|---|---|
| `.\lambda.ps1 -Setup` | Build and configure the whole stack |
| `.\lambda.ps1` | Boot alpine in a microVM and verify isolation |
| `.\lambda.ps1 -Shell` | Interactive shell inside a microVM |
| `.\lambda.ps1 -Bench 5` | Cold-start timing over 5 microVMs |
| `.\lambda.ps1 -Status` | Stack health without booting |
| `.\lambda.ps1 -Image IMG -Command 'CMD'` | Run any OCI image |
| `.\lambda.ps1 -Service` | Run nginx as a persistent service, verify HTTP |
| `.\lambda.ps1 -Publish 8080` | Same, and expose it to Windows on `localhost:8080` |
| `.\lambda.ps1 -Stop` | Stop the service and remove publish relays |

Example:

```powershell
.\lambda.ps1 -Image docker.io/library/python:3.12-alpine -Command 'python3 -c "print(2**100)"'
```

All entry points accept `-Distro <name>` for a WSL distro other than `Ubuntu`.

## Layout

```
setup.ps1     layer 1 setup          run.ps1     layer 1 run
lambda.ps1    layer 2 setup + run
scripts/
  common.sh                        shared config: versions, paths, network
  01-preflight.sh                  verifies KVM / nested virt (read-only)
  02-install.sh                    Firecracker binary + guest kernel
  03-build-rootfs.sh               squashfs -> bootable ext4 rootfs
  04-network.sh                    TAP device + NAT
  05-run-microvm.sh                boots a standalone VM
  10-install-toolchain.sh          Go + devmapper build deps
  11-build-firecracker-containerd.sh  builds shim, containerd, agent, CNI
  12-build-agent-rootfs.sh         guest rootfs with the VM agent
  13-configure-containerd.sh       thin pool, configs, CNI, systemd units
  14-run-lambda-vm.sh              runs an OCI image in a microVM
  fcc-thinpool-setup.sh            devmapper thin pool (run by systemd)
  status.sh                        health report
  teardown.sh                      removes runtime state; --purge wipes all
docs/
  ARCHITECTURE.md                  sequence diagrams: VM creation, in-guest
                                   runtime, Java workload, full-OS contrast
  LAMBDA-SEMANTICS.md              how Lambda-like this is (and is not);
                                   WSL idle timeout vs Lambda's timeouts
  TROUBLESHOOTING.md
```

Scripts are numbered and run in order; each is independently re-runnable.

## Runtime artifacts

```
/srv/firecracker/                      layer 1 + build tree
  bin/firecracker, images/, keys/, run/
  src/firecracker-containerd/          pinned upstream checkout
  guest-bin/{agent,runc}               binaries baked into the guest

/var/lib/firecracker-containerd/       layer 2 state
  runtime/default-vmlinux.bin          guest kernel
  runtime/default-rootfs.img           agent rootfs (read-only, shared)
  snapshotter/devmapper/{data,metadata} thin pool backing files
  containerd/                          image store

/etc/firecracker-containerd/config.toml
/etc/containerd/firecracker-runtime.json
/etc/cni/conf.d/fcnet.conflist
```

Deliberately **not** under `/mnt/c`. The Windows drive is DrvFs, which cannot
host the unix sockets Firecracker and containerd need, and does not preserve
root-filesystem ownership. Putting the work tree on `/mnt/c` is a common reason
Firecracker setups fail on WSL.

## Design notes

**Pinned everything.** Firecracker v1.12.1, guest kernel 6.1.128,
firecracker-containerd at an exact commit, containerd v1.7.33, Go 1.27.1.
Upstream publishes no binary releases of firecracker-containerd, so the commit
hash is the only stable reference.

**Built without Docker.** Upstream's `tools/image-builder` needs Docker, and
Docker Desktop's WSL integration is a manual GUI toggle. `12-build-agent-rootfs.sh`
assembles the same image directly from the Firecracker CI squashfs — same
result, one less dependency.

**Isolated from your existing containerd.** The stack uses its own socket
(`/run/firecracker-containerd/containerd.sock`), root, state dir and
snapshotter. Docker Desktop is untouched.

**devmapper, not overlayfs.** firecracker-containerd needs a block-device
snapshotter, because each microVM gets the container image as a virtio block
device. The WSL2 kernel does ship `thin-pool` and `thin` dm targets, which is
the usual blocker on other platforms.

**Guest networking is CNI + tc-redirect-tap.** Standard CNI plugins cannot
attach a VM; `tc-redirect-tap` mirrors traffic between the CNI veth and the
microVM's tap device. Containers run with `--net-host`, which means the
*microVM's* network namespace, not the real host's — still fully isolated.

### Three upstream defaults that had to change

These were all found by hitting them, not by reading docs:

1. **`cpu_template` must be `"None"`.** Upstream examples use `T2`, and
   `config.go` defaults to `T2` when the field is absent — so omitting it does
   not help. Firecracker rejects T2 on 13th-gen Intel:
   `The current CPU model is not permitted to apply the CPU template`.

2. **`noapic` must be removed from the kernel args.** It predates ACPI support
   in Firecracker. With v1.12.1 and the ACPI-enabled 6.1 guest kernel it breaks
   virtio enumeration and the guest panics with
   `VFS: Cannot open root device "vda"`. Upstream still carries it because
   their reference images use the older no-ACPI kernels.

3. **DNS needs an explicit resolver.** CNI's `resolvConf` normally points at
   the host's `/etc/resolv.conf`, which under WSL contains only
   `nameserver 10.255.255.254` — a WSL-internal address unreachable from a
   guest. The setup writes a resolv.conf with public servers and bind-mounts it
   into each container, since `ctr` (unlike Docker) does not synthesise one.

## Cleanup

```powershell
wsl -d Ubuntu -u root -- bash /mnt/c/Users/Yonat/desktop/firecracker-script/scripts/teardown.sh
```

Removes runtime state (VMs, TAP/NAT, thin pool, loop devices) but keeps
downloaded images and built binaries. Add `--purge` to delete everything.

## Notes and limits

- **Layer 1 network state does not survive `wsl --shutdown`.** TAP and NAT are
  runtime-only; `05-run-microvm.sh` detects this and re-runs `04-network.sh`
  automatically. Layer 2 handles it through systemd units instead.
- **Default guest size is 1 vCPU / 128 MiB**, firecracker-containerd's default.
  Change it per-VM through the CreateVM API, or globally in
  `/etc/containerd/firecracker-runtime.json`.
- **The jailer is not enabled.** Firecracker's `jailer` adds seccomp, cgroup
  and chroot confinement for multi-tenant production. This is a local
  development target and runs Firecracker directly.
- **Cold start is ~3.2 s**, against ~125 ms for Firecracker's own boot. The gap
  is containerd snapshot setup, CNI plumbing and VM teardown — not the VM boot
  itself. Snapshot/resume would cut it substantially.
- **`--net-host` is required** for containers to get the microVM's network.
  Without it the container lands in an empty namespace with only loopback.
