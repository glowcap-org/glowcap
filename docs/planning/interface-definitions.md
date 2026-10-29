# Interface definitions

Status: execution authorized, milestone 2 in progress.
This file owns the execution order and completion criteria for generation.
Delete it after milestones 5 and 6 pass. Discovery is not a completion condition.

## What this is for

Replace handwritten message encoding, decoding, bounds checks, and dispatch
with code generated from one interface definition. Applications retain their
behavior and policy. The generated paths must preserve OCapN values, promises,
capability ownership, and Loam's mutation outcomes.

The deliverable is a compiler executable, generated support for Zig, Rust,
TypeScript, Python, and Racket, and migrated Tasks, Rooms, and Loam-management
consumers. Application developers using prebuilt compiler and runtime artifacts
need no Zig installation. Building the compiler from source requires Zig.

## Execution map

The current work is milestone 2. Complete its conversation and cost evidence
before comparing authoring frontends. Syrup remains the direct compiler input.

| Work | State and next action | Owner |
| --- | --- | --- |
| Contract and independent messages | Authored and checked | [Fixture contract](../../test/interface/contract.md) |
| Compiler and first Tasks migration | Bounded reader/model, Zig creation checks, Rust preparation and replay run | [Compiler](../../tools/interface/README.md) |
| Rust and TypeScript callbacks | Pending admission, callbacks, pipelines, wrong replies and independent observation pass | [Proof suite](../../test/interface/README.md) |
| Binding prerequisites | Rust retention and TypeScript owning-thread capability fulfillment are implemented using existing Host operations | `bindings/rust`, `bindings/ts` |
| Prepared pending arguments | Next: retain before sequence acquisition, drop or observe the original, submit and replay, then prove release | Milestone 2 ownership case |
| Remaining conversation coverage | Qualify breaks, cancellation, export failure, supported handoff and Goblins in both directions | Milestone 2 runtime cases |
| Invocation shape | Runtime preserves absent, empty, and named selectors | Generated-path qualification still required |
| Cost and authoring decision | Measure generation first, then compare text and Cap'n Proto adapters | Milestone 2 decision |

The [earlier experiment](../research/interface-design-proof.md) is background
research. Its live results are not reproducible from the retained sources.
The proof suite above is the executable evidence for this implementation.
[ADR-0069](../decisions/adr/ADR-0069-proposed-interface-language.md) remains a
proposal until the adoption decision at milestone 4.

## Fixed scope

The [language reference](../research/interface-language-example.md) owns the
candidate syntax and semantics. User-defined generics and inheritance are excluded.

The compiler covers the draft value vocabulary and the existing value forms
needed by its selected runtime profiles, including Loam's Syrup records.
It never coerces null into undefined or an arbitrary integer into a lossy number.
An existing runtime limitation is recorded explicitly. Refusing a value that
the raw binding supports is incomplete generator work, not successful acceptance.

Keep parsing, resolution, and emission in build tooling. Emitters consume one
checked graph and generate reusable type helpers plus method wrappers.
Generated programs use the existing bindings, without a parser, description
exchange, schema interpreter, or new validation archive on ordinary calls.
Shared protocols are imported, not copied into application catalogs.

Keep runtime, Loam, and application responsibilities at the owners named in
[ADR-0069](../decisions/adr/ADR-0069-proposed-interface-language.md#scope-and-ownership).

Discovery, structural compatibility analysis, editor services, executable
annotations, and a plugin framework are outside this implementation.
The [discovery proposal](interface-discovery.md) needs its own consumer and decision.
Neither generation nor opening the repository waits for it.

## Runtime prerequisites

The [runtime boundaries](../boundaries.md#protocol-and-interop) own current limits.
They affect specific qualification cases, not all compiler work:

| Dependency | Owner | Work that waits |
| --- | --- | --- |
| Stored resolutions retaining partner objects | [ADR-0070](../decisions/adr/ADR-0070-stored-resolutions-hold-imports.md) | Implemented in `25ae1ce6`, with generated-path qualification still required |
| Direct invocation versus an empty-symbol method | Actor `Message`/`Delivery`, driver and every binding preserve selector presence | Exact preservation through generated clients and servers |
| Independently owned pending arguments | Host and binding API under ADR-0068 | Rust `RemotePromise::retain()` projects the existing C operation, with prepared-request qualification still required |
| Pending and local promise projection, remote pipelines across sessions | Host, actor, and engine owners, under the [runtime repairs](../roadmap.md#what-starts-next) | Exact target, outcome, ordering, cancellation, and release qualification |

Descriptions, copied-value checks, and ordinary calls can be developed while a
required runtime fix proceeds. Frontend comparison still follows the generation
proof below. An affected acceptance case
stays unmet until its dependency passes. Record explicit supported-profile limits
and never substitute a generated proxy for an owning runtime fix.

## Milestones and dependencies

| Milestone | Prerequisite | Exit that permits dependent work |
| --- | --- | --- |
| 1. Contract and fixtures | Plan approval | Concrete definitions, target mappings, and independent expected messages |
| 2. Conversation and continuation decision | 1 | Reproducible frontend comparison, Zig/Rust behavior, TypeScript promise probe, and accepted cost budget |
| 3. Complete Tasks | 2 passes and continuation is recorded | Deleted handwritten wire paths, complete core coverage, and mutation failure proof |
| 4. Adoption decision | 3 | Rooms-management reuse, TypeScript Tasks, and no-Zig consumer proof all pass |
| 5. Distribution and remaining bindings | 4 | Packaged compiler and independently qualified Python/Racket projections |
| 6. Remaining migrations | 4, plus each consumer's qualified emitter | Remaining Rooms and management wire code replaced and tested |

### 1. Establish the contract

The [fixture contract](../../test/interface/contract.md) owns the versioned Syrup
input, independent expected messages, target mappings, and API sketches.
The cost budget below owns the measurement criteria. `interface-fixtures-check` checks fixture integrity and
`tasks-app-test` checks the raw application behavior. Compiler, frontend,
ownership, and cost qualification remain milestone-2 work.

Write Tasks' complete declarations, shared Loam definitions, and a small
factory/callback fixture. Include watchers, receipt sequences, and actual
argument and reply forms. Record which handwritten paths will be deleted and
which policy code stays. Moving a static bound also moves its server constant
to the generated owner, avoiding two independently maintained facts.

Specify the versioned Syrup description, generated API sketches, and
mapping of every core type against Zig/Rust and both current wire profiles.
Independent fixtures cover exact messages, value boundaries, and refusals.
Include hostile names and literals, identifier collisions, and generated-file
paths. Generated code must compile and preserve wire names without code injection.
Identify missing runtime operations at their owner before relying on them.

Specify pending-call and prepared-request lifetimes against the prerequisites
above. Distinguish borrowed argument views from independently owned references.

Sketch candidate syntax only for the comparison cases. Complete the chosen
grammar after the frontend decision. Schema names remain project-local.

Fix separate generation and frontend budgets before implementation. Measure
handwritten wire decisions, source and test size, dependencies, builds, and
calls against existing emitters and equivalent raw calls. Record numerical
ceilings with rationale. Net line reduction is useful evidence, not a substitute
for removing duplicated decisions or preserving semantics.

### 2. Qualify one conversation and decide whether to continue

**First establish generation's value.** Start with a directly authored Syrup
description, one checked model, and Zig/Rust emitters. Use Tasks creation as
the retained mutation and returned-capability case, plus a small callback fixture.
Exercise Loam's internal creation result becoming a public capability reply.
Replace one real consumer path and identify the handwritten decisions removed.
Retain sources, pinned inputs, commands, and independent assertions so it runs
from a clean checkout without manual product-source edits.

Make that creation call the first runnable change. Add the callback, pending
argument, and interop cases afterward. All remain milestone exit requirements.

Cross raw and generated peers. Hold a factory answer pending while admitting
a dependent call and passing that answer as an argument. Exercise direct and
send-only calls, callbacks, adoption, breaks, wrong fulfillment, cross-Host
refusal, supported handoff, and plain Goblins in both directions. Record exact
roles and profiles rather than expanding unrelated transport tests.

Prove cleanup after partial decoding, discarded results, cancellation, close,
and export failure. Borrow within hosting lifetimes and retain asynchronous
state through existing owners. Failed typed observation must not change an
independent raw observer's outcome. Bound input, graph size, validation work,
depth, and output, with allocation-failure tests and fuzz seeds.

Use a fixture whose raw contract accepts pending references. Prepare a request
containing a pending argument. Validate ownership and retain it before issuing
the sequence request, then drop or observe the original handle before submitting
and replaying. Cover data, capability, and broken outcomes, including observation
after settlement. Failed preparation and cancellation must release their retains
without submitting a mutation. Release the prepared request and prove its final
retain is gone while the session remains usable.

A missing ownership operation is binding or Host work that blocks this exit,
not a generator-owned promise registry.

Generate a narrow TypeScript projection of the same conversation. Verify
immediate sending, pipelining, passable pending arguments, invalid fulfillment,
and a wire method named `then`. Measure shared compiler, emitters, helpers,
tests, and generated code. If generation fails semantics or its cost budget,
revise or stop here before building alternative frontends.

**Then compare authoring.** Feed the same checked model from proposed text
and a Cap'n Proto compiler adapter, against the direct Syrup baseline. Include
bounds, exact method symbols, absent/null/undefined, unknown breaks, and pending
references. Keep each adapter limited to these cases. A mapping failure leaves
that candidate incomplete for the requirement.

Compare each frontend against independent expected descriptions. Exercise the
runtime corpus through each emitter, without repeating it for every frontend.
One end-to-end case per frontend checks integration. Compare diagnostics and
edits to a bound, reply, and method, including frontend dependencies and costs.
Preserves' annotation experiment remains partial evidence, not a qualified
competitor. Retain comparison sources and commands with the results.

Record a continue, revise, or stop decision before milestone 3. Continuing
requires passing semantics, reproducible evidence, and maintainer acceptance
of measured cost and the completion budget. Generation and authoring receive
separate verdicts. If custom text loses, retain the generators and revise the
authoring choice. An exceeded ceiling requires a new decision.

Keep one production authoring frontend alongside Syrup input. Experimental
adapters do not become supported compilers by surviving the comparison.
This decision permits migration, not final adoption.

### 3. Replace complete Tasks

Complete the chosen grammar and generate Zig/Rust content, observation, poll,
cancel, and sequence paths.
Delete replaced encoding, decoding, and dispatch while preserving application
state, permissions, participant admission, and extension dispatch.
Complete the core value corpus in both bindings, including explicit existing
runtime limits. A narrow factory fixture alone does not satisfy core coverage.

Integrate checks where public requests and replies exist. A Tasks creation
handler can return an internal placeholder before Loam constructs its capability
reply. Check preparable structure before commit where possible, and preserve
known or uncertain commit outcomes if later reply materialization fails.

Prepared mutations snapshot copied inputs, validate the snapshot, and retain
reference arguments before the first suspension for sequence acquisition.
Change the caller's input while acquisition is pending and verify submission
uses the validated snapshot. Inject reply loss after commit,
cancellation during submission, competing preparation, receipt expiry, and
server restart with retained client state. Assert effects and returned outcomes.
Retries retain the original target, sequence, and arguments. No automatic
sequence refresh or client-process recovery is implied.

Change a bound, reply, and method name. Regenerate, compile affected consumers,
and verify diagnostics and stale-output detection. Report deleted wire decisions
and code, build cost, allocations, copied bytes, and messages against raw calls.

### 4. Decide adoption from independent uses

Three lanes depend on milestone 3, not on one another:

- **Rooms management:** migrate its existing Rust control client's policy,
  label, and lifecycle calls and shared Loam contracts. Test revision conflicts,
  exact replay, uncertain outcomes, and existing browser consumers. Coordinate
  ownership with Rooms work, without waiting for its recursive resource model.
- **TypeScript:** generate complete Tasks calls and available server adapters.
  Run core, asynchronous, lifetime, and mutation scenarios. Verify that generated
  methods preserve passable promises and that a wire name such as `then` cannot
  become a JavaScript promise hook. Remove replaced wire code.
- **Consumer workflow:** provide generation/check commands and a formatter,
  build a compiler executable, and exercise them without Zig installed.
  Use prebuilt runtime artifacts through the binding's existing setup path.
  Test imports, deterministic output, version mismatch, stale files, and errors.

Adopt only when all three lanes and milestones 1 through 3 pass. Review actual
maintenance costs and authoring changes, separating generation's benefits from
the text frontend's cost. A needed correction reopens its affected contract and
proofs. It does not silently lower acceptance or invalidate unrelated evidence.
Update the ADR from the result before broad rollout or release packaging.

### 5. Deliver qualified targets

Prepare prebuilt compiler packages for supported release targets and document
source builds, grammar, profile mappings, and compiler/runtime compatibility.
Verify clean installation and regeneration from packaged inputs.
Publication is a separate maintainer action, not an automatic plan step.

Qualify Python and Racket independently using complete Tasks migrations and the
same core and applicable runtime scenarios. Delete replaced code and record
incremental costs. A target is advertised only after its own tests pass.
A missing hosting facility stays with its runtime owner, not in the generator.
Already qualified targets need not wait for another binding's limitation.

### 6. Complete consumer migrations

Migrate remaining Rooms protocol and Loam-management operation families.
Each family waits for the emitters its consumers need and a settled application
contract. It can proceed alongside milestone 5 when those dependencies hold.
Use one authored contract and remove replaced tables and wire helpers.

Preserve deadlines, registration policy, session effects, authorization, and
recovery wrappers at their owners. Run existing server, client, browser, and
mutation-failure scenarios through the generated paths. Coordinate shared files
with the Rooms plan's owner rather than running competing consumer sweeps.

## Completion and verification

Every migration updates runnable examples and supported-behavior documentation
with its code. Completion means all required bindings are qualified, the named
consumers are migrated, obsolete wire paths are removed, and the total cost
report explains the new compiler's maintenance burden. Optional discovery and
additional syntax do not keep this plan open.

Independent expected behavior holds three properties:

| Property | Evidence |
| --- | --- |
| Representation | Preserve copied values, target identity, and the runtime's promise adoption and shortening rules |
| Calls | Equivalent well-formed generated and raw calls preserve arguments, outcomes, required ordering, and promise admission |
| Failure ownership | Local argument refusal admits no application send, partial decoding cleans up, and failed observation does not claim rollback |

Compare logical messages and required ordering, not transient reference numbers
or one scheduling order for independent calls. Generation adds no discovery,
inspection, or validation messages. Measure preparation calls against the same
raw receipt workflow, not a bare send that omits its sequence acquisition.

Use focused compiler tests, `source-check`, `tasks-app-test`, binding tests,
and affected Rooms tests while iterating. Use `check-external` for the changed
interop paths. Finish implementation milestones with `check` and `runtime-check`
when their changed boundaries require them. Record commands, results, and limits.
Documentation checks alone establish neither language acceptance nor runtime proof.

## Ownership and priority

One integration owner holds the model, grammar, shared fixtures, generation,
ADR, and this plan. Milestones 1 through 3 run in order. Milestone 4's three
lanes own separate application, emitter, and tooling files, with shared compiler
changes integrated by that owner. Later migrations split by operation family
only when file ownership and prerequisite emitters permit it.

The roadmap owns project priority. Protocol correctness comes first. Bounded
compiler work can run beside Rooms, and a Rooms operation being redesigned
blocks only its own migration.

## Deletion boundary and cost budget

Baseline at `25ae1ce6`: Tasks' Zig board is 147 lines, Zig client 140, Rust board
215, and TypeScript board 82. These whole-file counts include policy and workflow, so
they are an upper bound on removable code, not promised savings. The existing
Rooms generator and its seven emitter files total 1,461 lines, including 22
lines of embedded tests. Tasks' server tests were 419 lines.

These counts include blank lines and comments. The compiler
ceilings below count nonblank lines. Generated output never offsets compiler
maintenance cost.

The raw creation
exchange is one sequence query followed by one mutation submission. An exact
replay sends only the retained mutation. No compiler dependency is added by
this leg: the fixture check uses the already-pinned Python conformance reader.

The contract has nine content method layouts, six shared protocol layouts,
five receipt lowerings, four static size/count bounds, and the observation
record shape. Migration must remove each duplicated decision from its client
or adapter owner. A count of method strings alone misses reply interpretation,
arity, bounds, and sequence handling.

| Remove when generated | Retain at current owner |
| --- | --- |
| Rust capability/integer/text reply helpers, call packing, watcher record decoding, receipt envelope packing | Board workflow, connection setup, cursor lifecycle, user error presentation |
| Zig content selector/argument projection, generated shape and bounds checks | Storage schemas, authorization, transactions, child materialization, participant admission, membership, capacity policy |
| Client copies of method names and return shapes | Session ownership, persistence, retry decisions, cancellation policy |

Move `max_name_bytes`, `max_text_bytes`, `max_lists`, and `max_tasks` to the
shared generated owner when their consumers migrate. The generated creation
projection owns `max_text_bytes`, and `board.zig` keeps the other three until
their consumers migrate. Fixture
limits remain independently checked expectations.
Do not introduce a second production constants table during this leg.

Initial ceilings, fixed before compiler implementation:

| Cost | Milestone 2 ceiling and reason |
| --- | --- |
| Shared description reader, validator, checked graph | 3,000 nonblank source lines, reuse Syrup primitives, no new general parser framework |
| Zig and Rust emitters together | 3,000 nonblank source lines, one reusable helper per named type, not per method |
| Narrow TypeScript promise probe | 750 nonblank source lines, qualify async shape before full emitter investment |
| Additional authoring frontend | 1,200 nonblank source lines each, adapter scope is the comparison corpus only |
| Handwritten tests | Report separately, review above twice implementation size rather than omit semantic coverage |
| New production dependencies | Zero for direct Syrup and proposed text, account for Cap'n Proto toolchain separately |
| Ordinary generated call | Zero added messages and zero persistent schema state compared with equivalent raw call |
| Prepared mutation | Same sequence query plus submission as raw, one retained snapshot, no second full snapshot or automatic resend |
| Generation | Under 1 second warm for this corpus, at most 64 MiB peak resident memory |

These are stop-and-review ceilings, not measurements of software that does not
exist yet. Full-target completion needs a revised measured budget at the
milestone-2 decision. Multiplying a tiny prototype's line count is not evidence.

Measure raw and generated build time, allocations, copied bytes, and latency
in the same pinned environment and harness. The existing Tasks test exercises
behavior, not a calibrated call benchmark. Its wall time must not be presented
as call latency. Establish that paired benchmark before accepting generation's
cost result. No performance improvement is claimed by this leg.
