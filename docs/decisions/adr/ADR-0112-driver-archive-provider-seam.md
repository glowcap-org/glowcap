---
id: ADR-0112
status: accepted
date: 2026-08-09
tags: [c-abi, bindings, netlayer, driver, iroh, webrtc, archives]
decision: "One driver archive, libpancake_driver, projects driver.HostRuntime to C beside the byte-fed libpancake_host archive: it exports only pancake_driver_* and adopts a Host through pancake_driver_take_host. A new loop starts with zero transports and accepts provider packages through the standalone pancake_transport_provider.h ABI. The TCP transport archive owns tcp, keyed-tcp, noise-tcp, and its low-level framed connection API. Provider retain/release is the native transport lifetime authority. The byte-fed seam remains the primitive."
supersedes: []
superseded_by: []
amends: [ADR-0057, ADR-0059, ADR-0072, ADR-0078, ADR-0090]
amended_by: [ADR-0113, ADR-0117]
---

# ADR-0112 The driver archive and the provider seam

## Context

Every language binding drives the byte-fed host with its own transport
plumbing, and the plumbing is the same machine four times. The iroh readiness
loop alone is about five thousand lines across Rust, TypeScript, Python, and
Racket: park on the endpoint's readiness descriptor, drain ready events,
dispatch, try-read and try-write, feed the shared pump. The byte pump, the
dial executor, and the listen and accept admission logic repeat the same way.
Only the parking primitive (`AsyncFd`, `add_reader`, a descriptor semaphore)
is genuinely language-specific. This is the drift
[ADR-0059](ADR-0059-composable-c-abi-archives.md) removed for value
vocabulary, reappearing one tier up as behavior re-implemented per language,
and it engages the DRY value directly: one fact, the transport-to-host
choreography, held in four places that drift.

[ADR-0072](ADR-0072-driver-tier-over-c-abi.md) drafted and then withdrew a
callback-vtable netlayer registration, settling on the pull-based byte-fed
seam. What it rejected by name was wrapping the host "wholesale so Zig always
owns the loop", because that forecloses bring-your-own-loop and the browser.
An optional native loop beside the byte-fed seam was not rejected, and the
native tier it would project has since been built:
`driver.PollHost` (now [`driver.HostRuntime`](../../architecture.md) under
ADR-0113; introduced by ADR-0090) owns a
`driver_core.Host`, polls its wires and the settle mailbox in one `poll(2)`
set, and steps. At the time of this decision `PollHost` could not host the
endpoint-readiness shape iroh and WebRTC expose (one descriptor per endpoint,
connections multiplexed behind it), which ADR-0113 now names the
multiplexed-resident shape. That was exactly the shape the duplicated binding
loops existed to drive.

## Decision

Three moves, one rule.

**The rule: a function-pointer seam exists exactly where an artifact boundary
is compulsory.** iroh and WebRTC are Rust sidecars; no Zig archive can contain
them, so they cross the standalone provider ABI. The Host and driver remain
separate C archives, with the driver importing no Host symbols: it adopts a
quiescent Host through `pancake_driver_take_host`. The native TCP implementation
is one transport archive. It owns the complete `tcp` / `keyed-tcp` /
`noise-tcp` provider package and the low-level framed connection API used by an
embedder driving a byte-fed Host. The driver knows only provider metadata and
callbacks; it never enumerates TCP profiles. Provider retain/release is the
native lifetime authority. The browser composes neither way: its transports
are JavaScript APIs, wasm owns no I/O, and the byte-fed seam stays its permanent
contract.

**First, the Zig root.** `net` gains a multiplexed-resident contract, the
runtime execution form of the shape `src/net/transport/iroh.zig` already has: a
readiness descriptor, a drain of ready events over stable integer connection
ids, per-connection try-read and try-write with a would-block sentinel and
partial writes, and start, finish, and cancel for connects. `driver.HostRuntime`
hosts such multiplexed residents beside its
per-descriptor wires, the same move it already makes for the settle mailbox
descriptor, and its dial path resolves multiplexed providers before stream
netlayers.
This retires the recorded HostRuntime boundary for multiplexed-readiness
transports; `inproc` stays on `driver.BlockingSession`, having no readiness
primitive at all.

**Second, the archive.** A new self-contained archive, `libpancake_driver`
(the name ADR-0059 reserved), rooted at `src/c_abi/driver/`, exports only the
`pancake_driver_*` family. Its `pancake_driver_take_host` operation adopts a
quiescent `PancakeHost` created through `libpancake_host`; failure leaves the
Host with its caller, while success transfers Host teardown to the loop. The
loop family has the exact C spelling landed in its generated header: Host
adoption and release, provider registration, a non-blocking locator dial that
answers with an operation id, listen, one readiness descriptor for the whole loop,
step with a timeout, wake, and one event queue. Construction installs no
transport. The caller creates a transport package and registers it once through
`pancake_transport_provider.h`; the TCP archive's package carries all three TCP
profiles without per-profile setup verbs for bindings to repeat.
Listeners are stable loop-local ids. ACCEPTED events retain that id through
every binding's queue, and each listener has explicit locator selection and
close operations. Deployment policy may replace a bound listener's advertised
designator or direct-address hint through the listener id; the loop validates
the transport's typed locator metadata and atomically updates both its retained
URI and the Host's transport registry. Bindings never mutate a parallel Host
locator. Closing cancels that listener's still-handshaking accepts,
preserves events already committed, removes its advertised route, and never
selects another route by map iteration; callers select a remaining listener
explicitly.
Step executes transport-shaped actions internally and forwards the
application-visible ones, so the one-queue rule of ADR-0072 survives with the
queue moved one tier up. A native-loop consumer links `libpancake_host` and
`libpancake_driver` together, plus the provider archives it installs. A
byte-fed consumer links `libpancake_host` without the driver. The symbol
families remain disjoint, so there is one owner for each diagnostic slot and
one explicit Host-to-driver ownership transfer.

**Third, the provider.** `c_abi_shared` owns the layout-only provider contract,
including stream and multiplexed implementation tables, while the standalone
`pancake_transport_provider.h` header is the C authority shared by the driver
and transport archives. A transport archive fills one package and the driver
copies its profiles and callback tables after acquiring the package lease. The
binding's whole transport role is: load the Host archive, the driver archive,
and the provider archive; register the package; park on one descriptor; step;
drain one queue. Nothing allocates across the provider ABI; events drain into
caller arrays, writes are consumed by bounded copy, and multiplexed connection ids
are stable integers, never addresses. The provider release callback is invoked
only after all copied callbacks and transport handles retire.

Configuration equivalence follows the same ownership rule. A package supplies
`same_configuration`, and the driver invokes it only for the exact same profile
set and the exact same callback implementation. An equivalent registration is
idempotent; a different callback, profile set, or effective configuration is a
conflict. Bindings therefore construct and submit a candidate package every
time and retain no configuration registry of their own. A generic hash was
rejected: the driver cannot define transport equivalence, and hashing Tor
passwords or service keys would create a credential-guessing artifact.

Inside the driver archive, `ProviderRegistry` is the sole owner of package
validation, copied execution adapters, and leases; the loop owns only loop and
event lifecycle. Stream and multiplexed listeners share one locator projection and
canonicalization callback ABI because those semantics are identical. Their I/O
tables remain distinct because per-stream handles and multiplexed ids
have different ownership and readiness contracts.

The table owns the inbound half too: listener start, canonical designator and
direct-address metadata projection, accepted-connection claim, and stop. An
accept readiness record is therefore never an unowned notification a binding
must interpret or discard. A provider with no hosting posture returns a typed
listener-start refusal while retaining the same dial and connection contract.

One multiplexed runtime may realize several provider profiles. Entries in one
package identify that shared runtime by pointing at the same multiplexed
implementation table; the driver then holds one copied runtime table, one
readiness descriptor and connection namespace, and one package lease. Each
listener remains independent. `listen` receives the selected profile and a
driver-minted route id, then returns a tagged result: an immediate
provider-owned listener handle, or pending setup completed by a listen
readiness record and claimed through `finish_listen`. The base listener
capability and pending-completion capability are separate complete-or-absent
groups. An immediate provider supplies no `finish_listen`/`cancel_listen` pair
and must return ready; only a provider supplying both may return pending.
`finish_listen` consumes the operation on every return, while `cancel_listen`
owns every route abandoned before finish. Connect request ids and listener route ids are scoped
to the multiplexed runtime whose readiness stream echoes them. The generic
driver therefore knows neither the concrete transport set nor provider policy,
while a shared runtime never collapses distinct profile listeners into
runtime-global state.

Cancellation ends the transport operation, not only its publication. A stream
provider interrupts the `std.Io` task that owns a blocked connect or listener
setup and retires the attempt after that task has joined. The provider keeps
one reserved cancellation worker; each pending attempt embeds its own task
group, so cancellation adds no heap allocation and never parks the driver
thread. Multiplexed providers apply the same contract to the operation behind
their stable request id.

## Scope (what this does not decide)

- The byte-fed seam remains the primitive for wasm and for an embedder that
  explicitly supplies byte channels. It is not an automatic fallback from a
  native driver refusal.
- WebRTC signaling remains outside the generic driver. Its provider claims an
  already-open DataChannel in either session role, preserving the authority
  placement from ADR-0089.
- No completion-loop projection. `driver.Bridge` and `completion.Loop` remain
  the native scale spine, and the 500,000-session path stays theirs.
- Native bindings route archive-owned transports through one loop. A quiescent
  caller-owned Host transfers transactionally into it; the browser and
  explicit embedder-owned channels remain byte-fed.
- Stream providers begin connects through a nonblocking `start_connect`
  contract and publish readiness-driven completion. Outside this provider
  seam, each native Zig netlayer advertises exactly one tagged dial execution
  form: blocking or staged, never parallel callbacks for both.
- One `max_pending_opens` bound covers every pre-open session and wire across
  dial, accept, external adoption, and redeem. A deadline bounds duration; this
  admission bound independently prevents silent connectors from multiplying
  retained handshake memory without limit.
- `inproc` does not join the loop tier.

## Alternatives Considered

- **Project `Bridge` + `completion.Loop` instead of `HostRuntime`**: it already
  hosts iroh, keyed-relay, and WebRTC backends. Rejected because it is
  comptime-generic per backend and owns a blocking run loop; a C projection
  would need one exported instantiation per backend or full type erasure,
  which is what `HostRuntime`'s runtime netlayer slice already is, and ADR-0072
  already ratified that a blocking mode belongs to the loop's owner.
- **A host-to-netlayer C vtable, symmetric with the transport one**: rejected
  by the rule above; both halves are Zig, so the seam would be a second ABI
  where an import already composes at native cost.
- **Fold iroh into the driver archive statically**: rejected; the sidecar is a
  Rust staticlib behind cargo, which is the compulsory artifact boundary this
  design exists to cross (ADR-0055). Its provider package crosses the common
  ABI instead.
- **The loop family inside `libpancake_host`**: no second archive.
  Rejected because the wasm root imports `c_abi_host`, and the loop family
  drags `net` and sockets into a build that must stay net-free.
- **Callback vtables for scheduling, as first drafted in ADR-0072**: stays
  rejected; the driver archive schedules nothing for the binding, it only turns
  one readiness descriptor and a step call into I/O.

## Consequences

`driver.HostRuntime.core` is a pointer because the C archive's `Instance` embeds
the core by value and one core cannot live by value in two owners. `net` owns
the multiplexed-resident contract and HostRuntime owns its hosting arm, proven by a
hermetic fake provider in `test/driver/`. The driver archive, standalone
provider header, generated headers, binding FFI mirrors, and iroh provider are
one checked surface. Rust,
TypeScript, Python, and Racket all project the same loop contract; none owns a
parallel transport registry.

Thread affinity is the standing hazard: one thread drives one loop and its
host, callbacks fire on the stepping thread, and the surface says so.
The listener lifecycle is symmetric at the ABI: bind, read the complete
locator, select, close. A loop permits at most one active listener per
registered provider profile; a package may narrow that set when its runtime
cannot distinguish profiles (the relay runtime permits one listener total).
The binding spine gate requires every ACCEPTED decoder to carry the listener id
into its corresponding server queue.
Successful Host adoption is a durable promotion to loop mode. A later provider
or listener setup failure preserves a caller-supplied Host and its valid loop so
the caller can retry; only a Host minted by the failed operation is torn down.
The transactional claim is the `pancake_driver_take_host` call itself: if that
call refuses, the original Host remains byte-fed and untouched.
Final driver release has the same ownership distinction. A non-consuming
refusal leaves one binding-owned release lease, which retries once per later
safe runtime boundary rather than spinning or disappearing with a background
task. A consuming result commits Host-wrapper retirement once; release and
wrapper-cleanup failures remain ordered consequences of the terminal primary.
Retained outbound frames on partial multiplexed-provider writes and the settle mailbox
minted at init so its descriptor is in the set from the start are each
owned by a named test. The self-wake nudge when step returns with work
remaining (`HostRuntime.nudgeIfWorkRemains`) is proven for the pause shape a
test can construct (a held `feed_tail` of incomplete outer-frame bytes) in
`test/driver/host_runtime_step_test.zig`; the wake path it shares with
cross-thread `wakeReadiness` is pinned there too. A deterministic
construction of reader-buffered raw below the kernel's sight is not
available from this tier's public surface.

## Evidence and gate

`zig build test` carries the fake multiplexed-provider HostRuntime suite and
claimed-resource failure injection. `zig build source-check` holds the archive
and binding spines; the generated-header checks hold the C contract.
`zig build iroh-driver-provider` proves the common provider ABI over real QUIC,
and `zig build webrtc-driver-provider` proves external adoption of both WebRTC
session roles. Each binding's checks hold its runtime projection.

## Notes

Builds on [ADR-0090](ADR-0090-owning-host-face.md) (the projected tier),
[ADR-0059](ADR-0059-composable-c-abi-archives.md) (the composable archive
set), and [ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) (the endpoint
readiness shape). Amends [ADR-0072](ADR-0072-driver-tier-over-c-abi.md) by
adding the optional loop tier beside its byte-fed primitive. The sealed
channel of [ADR-0107](ADR-0107-sealed-byte-channel.md) is orthogonal and has
two thin owners: byte-fed sessions compose it in `HostSession`, while
completion-loop dials compose it in `net.noise_completion` before publishing
connect.
