---
id: ADR-0152
status: accepted
date: 2026-09-13
tags: [net, linux, runtime, resilience, performance]
decision: "Linux TCP completion loops prefer io_uring and fall back to epoll when the kernel or host policy cannot provide the required io_uring facilities. Both backends implement the same completion and shared-buffer ownership contract. The selected implementation and fallback reason are public runtime status, while applications own how they report that status."
supersedes: []
superseded_by: []
amends: [ADR-0051, ADR-0054]
amended_by: []
---

# ADR-0152 Linux completion backend selection

## Context

Linux hosts can lack the io_uring facilities glowcap needs in three recognized
ways. The kernel can predate the required io_uring features, host policy can
deny io_uring initialization, or io_uring can be available without the
provided-buffer rings used for bounded shared receive memory. In the last case,
`io_uring_setup` succeeds but `IORING_REGISTER_PBUF_RING` returns `EINVAL`.
Treating these hosts as unusable makes io_uring a hidden installation
requirement. Silently changing backends would make performance and diagnosis
harder for the application that owns the process.

## Decision

`src/net/completion/linux.zig` owns Linux backend selection. It tries io_uring
first. The io_uring backend names `SystemOutdated` and `PermissionDenied`
returned by the standard library's `IoUring.init` as `IoUringSystemOutdated`
and `IoUringInitDenied`. It names `EINVAL` from provided-buffer registration as
`ProvidedBufferRingUnsupported`. The selector uses epoll only for those three
source-specific errors. Allocation failure, invalid resource configuration,
descriptor quotas, and unrelated setup errors remain fatal.

The epoll backend implements the existing completion contract. It uses
nonblocking sockets, converts readiness into one completion per admitted
operation, and lends receive bytes from the same bounded `BufferPool` used by
kqueue. `net.tcpBackendStatus` reports `io_uring` or `epoll` through the TCP,
onion, keyed-relay, Noise, and iroh loop compositions. An epoll status also
names which of the three host conditions selected it. On an iroh loop, the
status describes the wrapped Linux platform layer rather than the QUIC
transport. The library does not write to stderr because the embedding owns
logging and user presentation. The many-sessions example and Rooms peer report
the status through their own diagnostic streams.

## Scope (what this does not decide)

The recorded 500,000-session result remains io_uring evidence. This decision
does not claim equivalent epoll throughput or syscall cost. It does not fall
back for transient resource pressure, invalid configuration, or an unclassified
io_uring failure.

## Alternatives Considered

- **Require a newer or differently configured kernel.** Rejected because a
  library user often cannot change the host, and io_uring is not necessary for
  correct completion-loop behavior.
- **Print a warning during library initialization.** Rejected because a library
  does not own the process log. Typed status lets an embedding that owns the
  loop present the fact in its own format.
- **Use epoll on every Linux host.** Rejected because io_uring remains the
  measured high-scale path and provides true completion with kernel buffer
  selection.

## Consequences

`net.Backend` is a runtime-selected Linux union, so wrappers such as onion,
relay, Noise, and iroh keep using one platform type. Those adapters delegate the
platform status they wrap. The portable loop and its operation accounting do
not branch on the selected backend. Applications can read
`net.tcpBackendStatus` after constructing any of these native loop compositions
and report a non-null fallback reason.

## Evidence and check

`test/net/linux_completion_test.zig` pins selection status, the fallback
classifier, epoll's interrupted-wait deadline, transactional registration,
read/write coexistence, exact cancel, close retirement, buffer recycling, and
TCP socket policy. `test/net/uring_test.zig` pins the same interrupted-wait
behavior for io_uring and the two source-specific initialization classifiers.
The ordinary completion-loop, bridge, and interop tests exercise the selected
backend on the host running them. The io_uring-only socket proof reports a
skipped test when the required io_uring facilities are unavailable instead of
treating the whole TCP loop as unsupported.
