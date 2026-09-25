# Sequence diagrams: how a microVM is created and how the container runs

Traced against this installation — API calls, vsock ports, drive names and log
lines below are taken from `journalctl -u firecracker-containerd` and the
pinned source at `/srv/firecracker/src/firecracker-containerd`, not from
upstream docs.

---

## First, the thing that trips everyone up

**containerd does not run inside the microVM.**

A reasonable guess at the architecture is "boot a VM, install containerd in it,
run containers there". That is not how firecracker-containerd works.

```
            HOST (WSL2 Ubuntu)              │        GUEST (microVM)
  ──────────────────────────────────────────┼──────────────────────────────
   firecracker-containerd   (daemon)        │
   containerd-shim-aws-firecracker (per VM) │   agent      (vsock :10789)
   devmapper snapshotter                    │   runc
   CNI plugins                              │   your container process
   firecracker                (VMM process) │
  ──────────────────────────────────────────┼──────────────────────────────
                        control plane over vsock
```

- **containerd + shim stay on the host.** They own image pull, snapshots,
  networking and VM lifecycle.
- **Inside the guest runs `agent`** (built from `agent/`), which registers a
  containerd **TaskService** over ttrpc on **vsock port 10789**
  (`agent/main.go:103`, `runtime/service.go:74`).
- **The agent shells out to `runc`** to actually create the container
  (`agent/main.go:89`, "Create a runc task service").

So the guest's "container runtime" is `agent` + `runc`. The agent speaks the
same task API a local shim would, just across a vsock instead of a unix socket.
That is why the host needs no containerd in the guest image, and why the guest
rootfs only needs two extra binaries.

---

## Diagram A — cold start: `ctr run` → running container

What `.\lambda.ps1` does. Measured end to end at **~3.2 s** on this machine.

```
PHASE 1 — IMAGE PREP (host only, no VM yet)
────────────────────────────────────────────────────────────────────────────
 1  you        → ctr           : run --runtime aws.firecracker
                                     --snapshotter devmapper
                                     --net-host alpine:3.20
 2  ctr        → containerd    : Images.Pull  (skipped if already local)
 3  containerd → devmapper     : Prepare(snapshot) for the container rootfs
 4  devmapper  → dm thin-pool  : create thin device from 'fcc-thinpool'
                                 └─ /dev/mapper/fcc-thinpool-snap-N
                                    a BLOCK DEVICE, not an overlay dir —
                                    this is why devmapper is mandatory
 5  ctr        → containerd    : Containers.Create + Tasks.Create
 6  containerd → shim          : start containerd-shim-aws-firecracker

PHASE 2 — VM CREATION (shim drives the Firecracker API)
────────────────────────────────────────────────────────────────────────────
 7  shim       → shim          : "creating new VM" vmID=00d6b5a3-…
 8  shim       → CNI           : ADD  (bridge → firewall → tc-redirect-tap)
    CNI        → host netns    : veth pair + fc-br0 + tap0
                                 tc-redirect-tap mirrors veth ⇄ tap, because
                                 standard CNI cannot attach to a VM
    CNI        → shim          : IP 192.168.127.x/24, gw, DNS
 9  shim       → firecracker   : spawn VMM, "setting up a VMM on firecracker.sock"
10  shim       → API GET  /machine-config        → 200
11  shim       → API PUT  /boot-source           → 204
                                 kernel = default-vmlinux.bin
                                 args   = ro console=ttyS0 … init=/sbin/overlay-init
12  shim       → API PUT  /drives/root_drive     → 204
                                 default-rootfs.img, is_root_device=true,
                                 is_read_only=TRUE  (runtime/service.go:1062)
13  shim       → API PUT  /drives/ctrstub0       → 204
                                 a PLACEHOLDER drive. Firecracker cannot
                                 hot-add drives, so the shim pre-attaches N
                                 stubs now and re-points them later.
                                 (runtime/drive_handler.go:58)
14  shim       → API PUT  /network-interfaces/1  → 204
                                 "Attaching NIC tap0 (hwaddr e2:24:f1:…)"
15  shim       → API PUT  /actions {InstanceStart} → 204
                                 "startInstance successful"

PHASE 3 — GUEST BOOT  (inside the VM; ~1.3 s measured)
────────────────────────────────────────────────────────────────────────────
16  kernel 6.1.128 boots, virtio-blk finds /dev/vda (the read-only rootfs)
17  kernel        → /sbin/overlay-init   (init= from step 11)
18  overlay-init  : mount -t tmpfs /overlay
                    mount -t overlay lowerdir=/ upperdir=/overlay/root
                    pivot_root /mnt /mnt/rom
                    └─ root is read-only and SHARED by every microVM, so the
                       writable layer must be per-VM tmpfs
19  overlay-init  → exec /sbin/init (systemd)
20  systemd       → isolate firecracker.target   (systemd.unit= from step 11)
21  firecracker.target wants → firecracker-agent.service
22  systemd       → exec /usr/local/bin/agent --debug   (WorkingDirectory=/container)
23  agent         : "creating task service"
                    listen vsock :10789, become subreaper (agent/main.go:83)

PHASE 4 — HANDSHAKE
────────────────────────────────────────────────────────────────────────────
24  shim  → agent  : dial vsock :10789      ("calling agent")
                     retries ~100 ms apart; if the guest failed to boot this
                     is where you see "connection refused" and nothing else
25  agent → shim   : TaskService ready

PHASE 5 — GIVING THE CONTAINER ITS ROOTFS
────────────────────────────────────────────────────────────────────────────
26  shim  → API PATCH /drives/ctrstub0      → 204
                     re-point the stub at /dev/mapper/fcc-thinpool-snap-N.
                     THIS is how the container image crosses the VM boundary:
                     as a patched block device, not a filesystem share.
27  shim  → agent  : DriveMounterService.MountDrive
                     (runtime/drive_handler.go:373)
28  agent          : scan /sys/block, find the patched device,
                     mount it → /container/rootfs
                     (retries: the guest may not see the patch immediately —
                      agent/drive_handler.go:187)

PHASE 6 — RUN
────────────────────────────────────────────────────────────────────────────
29  shim  → agent  : Task.Create (OCI spec, rootfs=/container/rootfs)
30  agent → runc   : runc create   (namespaces, cgroups, seccomp)
31  shim  → agent  : Task.Start
32  agent → runc   : runc start
33  runc  → PID 1  : exec the container entrypoint  (e.g. /bin/sh)
34  I/O proxy      : stdin vsock :11000, stdout :11001, stderr :11002
                     one triplet allocated per task (internal/common.go:26-30,
                     runtime/service.go:424)
35  container      → host terminal  (via those vsock streams)

PHASE 7 — TEARDOWN
────────────────────────────────────────────────────────────────────────────
36  container exits → runc reaps → agent → shim : Task.Exit
37  shim  → agent   : unmount /container/rootfs
38  shim  → firecracker : stop VMM   (whole VM dies; --rm was passed)
39  shim  → CNI     : DEL  (veth, tap, IP released)
40  shim  → devmapper : Remove snapshot thin device
41  shim exits
```

### Where the ~3.2 s actually goes

| Phase | Cost | Note |
|---|---|---|
| Image prep + snapshot (1–6) | tens of ms | image already pulled |
| VM create + API calls (7–15) | ~200 ms | includes CNI |
| **Guest boot (16–23)** | **~1.3 s** | measured directly |
| Handshake (24–25) | ~100 ms | poll interval |
| Drive patch + mount (26–28) | ~100 ms | plus mount retries |
| runc + exec (29–35) | ~100 ms | |
| Teardown (36–41) | ~1 s | VM stop, CNI DEL, dm remove |

Firecracker's own VMM boot is ~125 ms (upstream's figure). Almost everything
above it is systemd inside the guest plus orchestration — which is why
snapshot/resume, not a faster VMM, is the lever for cutting cold start.

---

## Diagram B — second runtime: a Java workload

`.\lambda.ps1 -Image docker.io/library/eclipse-temurin:21-jre -Command 'java -version'`

The control plane is **byte-for-byte the same as Diagram A**. Only the guest-side
work changes. That is the point of the design: the runtime is just an OCI image.

```
  Steps 1–28 : IDENTICAL to Diagram A
               └─ except step 3/4: a JRE image is ~280 MB vs alpine's ~8 MB,
                  so the devmapper thin snapshot copies more blocks on first
                  use. Subsequent runs reuse the cached image.

PHASE 6' — RUN (this is the only part that differs)
────────────────────────────────────────────────────────────────────────────
29  shim  → agent  : Task.Create  rootfs=/container/rootfs  (now a JRE image)
30  agent → runc   : runc create
31  shim  → agent  : Task.Start
32  agent → runc   : runc start
33  runc  → PID 1  : exec java -version
      │
      ├─ 33a  ld.so maps libjvm.so from the mounted thin device
      ├─ 33b  JVM reserves heap  ← sizes itself from the VM's RAM, not the
      │                            host's: 106 MiB visible at the default
      │                            128 MiB machine config
      ├─ 33c  JVM loads rt modules / CDS archive
      └─ 33d  main() runs
34  stdout → vsock :11001 → shim → your terminal
  Steps 36–41 : IDENTICAL to Diagram A
```

**What this shows:** swapping the "runtime" (Alpine shell → JVM → Python →
anything) changes nothing above the OCI layer. Cold start grows by JVM startup
plus first-pull snapshot cost — not by anything in the VM control plane.

Measured on this machine, at the stock 1 vCPU / 128 MiB:

```
openjdk version "21.0.12" 2026-07-21 LTS
OpenJDK 64-Bit Server VM Temurin-21.0.12+8 (mixed mode, sharing)
Mem: total 106   used 45   available 61      (MiB, inside the microVM)
```

So a JRE starts fine at the default size — `java -version` needs ~45 MiB. The
figure that matters is that the JVM ergonomically sizes its heap from the
**guest's** 106 MiB, not the host's 32 GB, so a real application with a working
set will hit the ceiling long before the host notices. Raise `mem_size_mib` in
`/etc/containerd/firecracker-runtime.json` for actual workloads.

---

## Diagram C — the other model: full-OS microVM (layer 1)

This is `.\run.ps1`, and it is a genuinely different shape. No containerd, no
shim, no agent, no OCI image — you boot an operating system and log into it.
Useful to contrast, because it shows how much of Diagram A exists purely to
make *containers* work.

```
 1  you        → 05-run-microvm.sh : bash script, no daemon involved
 2  script     → 04-network.sh     : create tap fc-tap0 172.16.0.1/30,
                                     iptables MASQUERADE  (re-created if WSL
                                     restarted and dropped the state)
 3  script     → vm-config.json    : kernel, rootfs, NIC, 2 vCPU / 1024 MiB
 4  script     → firecracker       : --config-file vm-config.json
                                     (no API calls at all — one static file)

 5  kernel 6.1.128 boots, mounts /dev/vda  READ-WRITE
                                     └─ no overlay-init: this rootfs belongs
                                        to exactly one VM, so it can be rw
 6  kernel     → /sbin/init (systemd)   ← default target, NOT firecracker.target
 7  systemd    : ip= kernel arg already configured eth0 172.16.0.2/30
                 (no DHCP client in the guest)
 8  systemd    → serial-getty@ttyS0 : root autologin  → shell on the console
 9  systemd    → sshd                : key auth on 172.16.0.2
10  you        → ssh root@172.16.0.2 : full Ubuntu 24.04 userspace
11  you        → 'reboot'            : i8042 reset → Firecracker traps → exits
                                       ('poweroff' would hang: no ACPI button)
```

### The two models side by side

| | Layer 1 — full OS | Layer 2 — Lambda-style |
|---|---|---|
| Boot target | `default.target` | `firecracker.target` |
| Root drive | read-write, one VM | read-only, shared + tmpfs overlay |
| Init | `/sbin/init` | `/sbin/overlay-init` → systemd |
| In-guest runtime | none — you are the workload | `agent` + `runc` |
| Workload source | baked into the rootfs | any OCI image, attached as a block device |
| Networking | static `ip=` kernel arg | CNI + tc-redirect-tap |
| Control plane | a shell script | containerd + shim over vsock |
| Lifetime | until you log out | one container, then destroyed |
| Time to usable | ~2 s to SSH | ~3.2 s to container exit |

---

## Why the awkward parts are the way they are

Three bits of Diagram A look over-engineered until you hit the constraint
behind them:

**Stub drives (steps 13, 26).** Firecracker cannot hot-plug block devices. The
shim therefore attaches placeholder drives *before* boot and PATCHes their
backing file when a container needs a rootfs. `ContainerCount` at CreateVM time
sets how many containers a VM can ever host.

**Read-only root + overlay-init (steps 12, 18).** One `default-rootfs.img` is
shared by every microVM simultaneously. Mounting it read-write would corrupt it
across VMs, so it is attached read-only and each guest pivots onto a private
tmpfs overlay. Guest writes therefore consume guest RAM.

**tc-redirect-tap (step 8).** CNI plugins were designed to move a veth into a
container's network namespace. A VM has no namespace to move anything into, so
this plugin instead sets up tc filters that mirror packets between the CNI veth
and the VM's tap device.
