# Interface definitions

Status: execution authorized, milestone 2 in progress, authoring continuation proposed.
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

The current work is milestone 2. Conversation, generation-cost, and proposed
text comparisons are retained. Tasks' Rust read workflow and six Zig server
reads use generated checks for declared bounds and exact arity. Complete authored
Tasks and Loam modules feed generation and match the independent Syrup fixture.
Syrup remains supported input. The [continuation proposal](#continuation-proposal)
recommends the text frontend. Frontend selection and the full-target budget remain open.

| Work | State and next action | Owner |
| --- | --- | --- |
| Contract and independent messages | Authored and checked | [Fixture contract](../../test/interface/contract.md) |
| Compiler and first Tasks migration | Bounded reader/model, Zig creation and read checks, Rust preparation and replay run | [Compiler](../../tools/interface/README.md) |
| Rust and TypeScript callbacks | Both profiles preserve pending admission, callbacks, pipelines, wrong replies and remote breaks. Rust drops polled observations, and TypeScript cancels sessions with observers active | [Proof suite](../../test/interface/README.md) |
| Binding prerequisites | Rust retention and TypeScript owning-thread capability fulfillment are implemented using existing Host operations | `bindings/rust`, `bindings/ts` |
| Prepared pending arguments | Rust capture, drop/observation, submission/replay, cancellation, and cross-Host refusal run on both profiles. Binding tests check final retain retirement | Milestone 2 ownership case |
| Conversation coverage | Zig creation export failure and retry are qualified. Generated Rust recipient handoff and plain Goblins calling the generated Zig Tasks boundary run on Syrup/V1.0 | Milestone 2 runtime cases |
| Invocation shape | Rust and TypeScript callers preserve selector presence. A generated Zig two-value direct receiver restores leading-symbol data on both profiles | General receiver projections remain |
| Scalar calls | Rust and TypeScript qualify boolean, bytes with byte bounds, symbol, float64 and fulfilled error values through calls and tells on both profiles | Null and compound inputs remain unsupported |
| TypeScript scalar bounds | Exact arbitrary bigint values and UTF-8 text limits cover required/optional calls and tells, including nested compound replies | [Fixture contract](../../test/interface/contract.md#typescript-scalar-bounds) |
| Argument presence | Rust and TypeScript distinguish omission from explicit undefined and refuse invalid holes on both profiles. Null remains unsupported by the targets | [Proof suite](../../test/interface/README.md) |
| Profile requirements | Ordinary descriptions require the value mapping. Receipt methods also require their convention, checked across the whole bundle | [Fixture contract](../../test/interface/contract.md) |
| Text imports | Rooted file loading, cached cyclic headers, exact imported descriptions and bound/reference source locations run through the shared model | [Authoring checks](../../test/interface/authoring/README.md#imported-modules) |
| Complete authored contract | Tasks, shared Loam and qualification modules match the full independent description. Text consumers reuse the checked Model and existing generated output stays byte identical | [Authoring bundle](../../test/interface/authoring/README.md#complete-contract-bundle) |
| Generated Rust support | Selected methods determine imports and helpers. Isolated consumers compile with warnings denied | [Authoring checks](../../test/interface/authoring/README.md) |
| Compound replies | Rust owned replies drive Watcher polling. TypeScript validates existing arrays and records. Both profiles check tags, bounds, notices, opaque capabilities, and raw settlement | [Fixture contract](../../test/interface/contract.md#typescript-compound-replies) |
| Tasks read workflow | Five generated Rust reads replace manual wire calls and text/count decoding. Zig handlers use generated checks for arguments and scalar replies. Real Board reads and independent raw peers check bounds and failures | Milestone 2 application qualification |
| Cap'n Proto comparison | The compiler-request comparison is retained in [#65](https://github.com/glowcap-org/glowcap/pull/65) | Milestone 2 comparison |
| Cost and authoring decision | [Generation costs](../../bench/interface/results.md) and the [text comparison](../../test/interface/authoring/README.md) retain measurements and limits. Review the continuation proposal and complete its measurement checkpoint | [Continuation proposal](#continuation-proposal) |

The [earlier experiment](../research/interface-design-proof.md) is background
research. Its live results are not reproducible from the retained sources.
The proof suite above is the executable evidence for this implementation.
[ADR-0069](../decisions/adr/ADR-0069-proposed-interface-language.md) remains a
proposal until the adoption decision at milestone 4.

The read workflow extends milestone 2's application evidence before the complete
Tasks migration. It removes handwritten wire calls, decoders, and a String
copy in the Rust read path. Records, unions, declared failure types, and complete target mappings
remain language work. The comparison adapters' size and passing cases do not establish those features or their cost.

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
| Independently owned pending arguments | Host and binding API under ADR-0068 | Rust `retain` and `retain_for` project the existing C operation. Prepared-request qualification runs on both profiles |
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
| Remaining Rust capability checks, watcher poll/cancel and registration decoding, receipt packing for move and observation | Board workflow, connection setup, cursor lifecycle, user error presentation |
| Zig content selector/argument projection, index/text checks, and client reply and receipt helpers | Storage schemas, authorization, transactions, child materialization, participant admission, membership, capacity policy |
| TypeScript, Python and Racket Tasks call layouts, reply checks, watcher decoding and receipt packing | Session ownership, persistence, retry decisions, cancellation policy |
| Rooms control method names, argument packing and reply shapes for policy, labels and lifecycle | Revision selection, deadlines, admission, effect handling and recovery |
| Existing Rooms generator tables and emitters, plus consumer shape checks covered by the replacement contract | Room membership, message queues, registration and application policy |

Tasks creation and read projections own `max_name_bytes`, `max_text_bytes`,
`max_lists`, and `max_tasks`. The board converts them to its storage types.
Fixture limits remain independently checked expectations.
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

These are stop-and-review ceilings for milestone 2. The proposal below does not
replace them until accepted. Generated output and deleted application code do
not offset compiler maintenance cost.

Measure raw and generated build time, allocations, copied bytes, and latency
in the same pinned environment and harness. The retained paired benchmark
establishes costs for its selected Rust calls. Tasks test wall time is not call
latency. Extend the paired measurements when the generated value or ownership
path changes. No general performance improvement is claimed.

### Continuation proposal

Continue generation and use the proposed text frontend for the next authoring
proof. The retained conversation and paired costs justify that work. Final
frontend selection and the full-target budget remain milestone-2 decisions.
ADR-0069 stays proposed through complete Tasks migration and the adoption proof.

Text expresses methods, exact symbols, bounds and pending references directly.
It adds no production dependency, but makes this project responsible for imports,
diagnostics and formatting. Cap'n Proto supplies a compiler and schema tooling,
but its adapter still needs glowcap mappings and imported-bundle assembly.

| Remaining authoring work | Proposed text | Cap'n Proto adapter |
| --- | --- | --- |
| Value mapping | Complete container, recursive and failure syntax | Mappings for integers, symbols, dynamic values, null, promises and positional records |
| Imports | Rooted loading, resolution and bounded bundle assembly | Adapter currently accepts one requested file and refuses external references |
| Diagnostics | Preserve syntax locations through shared validation | Mapping errors need source positions beyond compiler syntax diagnostics |
| Formatting | Preserve comments, which the comparison parser discards | Qualify the annotation and formatting workflow |
| Dependencies | Existing Zig modules | Compiler 1.1.0 and locked Rust capnp 0.27.3 |

Both adapters reproduce the independent comparison description. Neither proves
complete authoring support. Prefer text for its direct contract notation, and
reconsider that choice if the imported-module proof cannot fit the existing
frontend limit or produces worse authoring than the mapped Cap'n Proto input.

The [generation report](../../bench/interface/results.md) qualifies selected
Rust/Syrup 1.0 calls. It records matching raw/generated allocation counts and
message histograms, with no extra payload copies in the reviewed wrappers.
The [text](../../test/interface/authoring/README.md#process-and-build-costs-2026-11-03)
and [Cap'n Proto](../../tools/interface/authoring/capnp/README.md#dependencies-and-measurements)
process measurements use different harnesses and do not rank parser speed.

### Current source and missing budget evidence

At `39678c7c`, the implementation inventory is 1,772 nonblank lines: shared
reader/model 443, Zig/Rust emitters and helpers 630, TypeScript 207, text 258,
and command/build integration 234. Comments count. Embedded Zig tests, standalone
tests, generated output and the Cap'n Proto comparison are separate.

These counts can be reproduced from tracked blobs at that revision. Use the
literal masker and brace-balanced test-block exclusion in
[`measure.py`](../../bench/interface/measure.py). Shared code comprises
`description`, `model`, `calls`, `call_type` and `literal`. Zig/Rust comprises
`callbacks`, `exports`, `rust*`, `zig` and the Rust templates. TypeScript comprises
`typescript*` and its template. Integration comprises `generate`,
`authoring_check` and `tools/build/interface.zig`.

The compound-reply batch is additional, unmerged work. Its Rust reply checks
and Watcher migration do not establish compound inputs or other targets.
Historical benchmark results keep their original source revisions.

No supported estimate yet covers complete values, generic receivers and
receipts, authoring tools, distribution, and all five targets. Keep the existing
ceilings while measuring the next complete module. A later budget proposal must
charge each remaining feature to its owner and distinguish estimated additions
from measured source. Deleted consumer code and generated output do not offset
compiler maintenance cost.

### Next measurement checkpoint

Complete these steps before closing milestone 2:

1. Load Tasks and shared Loam definitions through bounded text imports. Compare
   their checked graph with the independent description. Include lists, tuples
   and positional records without changing the source language's string-keyed
   record meaning. Check missing files, import cycles and resource limits.
2. Preserve an imported bound error's source location through validation.
   Repeat bound, reply and method edits through imported declarations.
3. Record the resulting compiler/frontend source, tests, generated output and
   deleted wire decisions. Measure bundle checking and supported emission
   against the existing 1-second warm and 64-MiB RSS limits.
4. Extend paired raw/generated measurements to compound replies. Use an
   equivalent typed raw decoder, accounting for result-vector storage, payload
   copies, retained bytes, messages and cleanup after partial decoding.

This checkpoint keeps the existing 1,200-line frontend ceiling. Full grammar,
formatting, packaging and remaining targets retain their milestone exits.
If the checkpoint exceeds a ceiling, review its design and cost before extending
it. A passing scalar benchmark does not qualify container allocation costs.
