# How Lambda-like is this, really?

This project is named for Lambda's **isolation model** — one Firecracker
microVM per workload — not its **scheduling model**. The difference matters,
and the WSL idle timeout you will hit while using it is unrelated to either.

---

## 1. The WSL idle timeout is not a Lambda analogue

While testing a long-running nginx service, it kept dying after a few minutes.
That is WSL2, not the microVM stack:

> WSL2 shuts down **the VM that hosts everything** once no client session is
> attached. It takes out containerd, the devmapper thin pool, and every running
> microVM at once.

In AWS terms that is your **EC2 bare-metal host vanishing**, not a Lambda
feature. Lambda reaps individual execution environments as a deliberate
capacity decision while the fleet stays up. WSL removes the floor.

### What does not fix it

```ini
# %USERPROFILE%\.wslconfig
[wsl2]
vmIdleTimeout=-1
```

**Verified ineffective on WSL 2.4.11.** The distro still shut down; confirmed
by `uptime` showing a restart two minutes earlier while the service was
supposed to be running. The setting is documented by Microsoft but is not
honoured in this configuration.

### What does fix it

Hold an actual session open, so the distro is never idle:

```powershell
Start-Process wsl.exe -WindowStyle Hidden -ArgumentList @(
    '-d','Ubuntu','-u','root','--','sleep','infinity'
)
```

`lambda.ps1` does this automatically before starting a persistent service, and
clears it on `-Stop`.

**Measured:** without it the service died within ~4 minutes. With it, the
distro stayed up 8+ minutes continuously and nginx kept returning HTTP 200.

Two caveats: the keepalive is an ordinary background process, so it does not
survive a reboot or `wsl --shutdown` — re-run `.\lambda.ps1 -Publish 8080`
after either. And it keeps WSL resident for *all* distros, including
docker-desktop.

---

## 2. Lambda's "timeout" is three different things

These get conflated constantly:

| Concept | What it is | Value |
|---|---|---|
| **Function timeout** | Max wall-clock for one invocation; exceeding it kills the call with `Task timed out` | 3 s default, **900 s max**, configurable |
| **Freeze / thaw** | After a response the execution environment is *paused*, not destroyed; the next invocation thaws it (warm start). Background threads stop while frozen | immediate |
| **Idle reap** | No invocations for a while → environment destroyed → next call is a cold start | **not documented by AWS**; commonly observed ~5–15 min |

Only the third rhymes with the WSL behaviour, and only in outcome
("idle → it is gone"). The mechanism and the layer are different.

---

## 3. What this setup actually implements

Honestly: **none of Lambda's lifecycle.**

| | AWS Lambda | This setup |
|---|---|---|
| Isolation | one microVM per execution environment | same — one Firecracker VM per container |
| Environment reuse | warm environments reused across invocations | **none** — VM destroyed after every run |
| Freeze / thaw | yes | not wired up (primitive exists, see below) |
| Snapshot restore | SnapStart (Java/.NET/Python) | no |
| Invocation timeout | 3 s–900 s, enforced | **none** — a command runs until it exits |
| Idle reap | yes, deliberate | no (WSL kills the host instead) |
| Cold start | ~100–500 ms typical | **~3.2 s measured** |

Two consequences worth being clear about:

- **`lambda.ps1` (one-shot) is *worse* than Lambda**, not equivalent. It
  destroys the VM after each command, so *every* invocation is a cold start.
  Lambda reuses warm environments and only pays cold start occasionally.
- **`lambda.ps1 -Publish` (nginx) is not Lambda-shaped at all.** The VM lives
  until killed. That is ECS/Fargate behaviour — a long-running service in a
  microVM.

---

## 4. What it would take to close the gap

Checked against the pinned source rather than assumed.

### Freeze/thaw: the primitive is already there

```
proto/firecracker.proto:54   PauseVMRequest
proto/firecracker.proto:58   ResumeVMRequest
runtime/service.go:663       func (s *service) ResumeVM(...)
runtime/service.go:681       func (s *service) PauseVM(...)
```

This is enough to build a **warm pool**: keep N microVMs booted and paused,
thaw one per request, pause it again afterwards. That removes the ~1.3 s guest
boot from the critical path — the single largest component of the 3.2 s cold
start (see `ARCHITECTURE.md`).

### Snapshot restore: not exposed

There is no `CreateSnapshot` / `LoadSnapshot` in firecracker-containerd's
proto. Firecracker itself supports it (`PUT /snapshot/create`,
`PUT /snapshot/load`) — that is the mechanism behind Lambda SnapStart — but
reaching it means driving the Firecracker API directly and bypassing the shim.

### Invocation timeout: trivial, not implemented

Nothing enforces a maximum runtime. The closest equivalent today is wrapping
the call in `timeout(1)`. A real implementation would enforce it in the shim
so the VM is destroyed, not just the process.

---

## Summary

The isolation story is real: every workload gets its own kernel, verified by
`uname -r` reporting **6.1.128** inside the guest against **5.15.167.4** on the
host. The scheduling story is not implemented — no reuse, no warm pool, no
enforced timeouts. Treat this as a correct Firecracker/containerd substrate
that a Lambda-style scheduler could be built on, not as a Lambda clone.
