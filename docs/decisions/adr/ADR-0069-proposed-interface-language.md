---
id: ADR-0069
status: proposed
date: 2026-10-26
tags: ["interface", "language", "syrup", "bindings", "codegen"]
decision: "Use one interface model with canonical Syrup descriptions and a small method-oriented authoring language, subject to the complete application proof."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0069 Proposed interface language and model

## Context

Application callers repeat method names, positional encoding, bounds, reply
checks, and reference handling. Rooms has protocol emitters, but Tasks and
management callers still maintain wire details by hand. The
[vision](../../vision.md) requires usable application APIs with explicit
ownership and costs, while OCapN behavior remains authoritative.

The [prior-art review](../../research/interface-goblins.md) establishes precedent
for optional interface descriptions above CapTP. It establishes no community
endorsement of this language. Untyped calls and actors without descriptions
remain ordinary participants.

## Proposed decision

Use one authored message contract, a checked semantic model, and its canonical
Syrup description. Generate callers, value conversion/check helpers, and
server adapters over existing runtime bindings. Source declarations own method
names, argument and reply shapes, static bounds, recognized failures, and
required profiles. Shared protocols are imported rather than copied into
application or per-language catalogs.

Recommend a method-oriented text frontend. Its implementation lives in build
tooling, with internal compiler APIs and a distributed executable. Users of
prebuilt compiler and runtime artifacts need no Zig installation. Compiling
the compiler from source requires Zig. Ordinary calls load no schema, parser,
or separate validation archive.

Text and Syrup input pass through the same resolution and validation to one
checked graph. A serialized description cannot bypass checks because it claims
to be canonical. Keep source locations for diagnostics. Emit reusable helpers
per needed type and small method wrappers, without repeating semantic analysis
in each backend or expanding recursive definitions at every use.

Syrup is the primary description data language. The checked model and its
serialization represent the same contract. OCapN calls retain the selected
runtime wire profile. Descriptions neither negotiate another protocol nor
require discovery, and foreign compiler ASTs are not runtime authorities.
Support Syrup input and one selected authoring frontend. Comparison adapters
are experiments, not a commitment to ship multiple language toolchains.

## Scope and ownership

The [language reference](../../research/interface-language-example.md) specifies
the concrete source forms. The initial language has named declarations,
parameterized built-in containers, explicit unions, bounded recursive data,
capability expectations, and promises. User-defined generics and inheritance
are excluded. Cursors, observers, resolvers, and subscriptions are ordinary
interfaces rather than compiler features.

The compiler owns syntax, resolution, static restrictions, and generation.
Session and Host state own reference identity, admission, routing, settlement,
and release. Existing bindings project those operations into each language.
Loam owns receipts and transaction outcomes. Applications own authorization,
effects, and recovery decisions. Extract runtime helpers only at those owners
when actual generated consumers demonstrate the need.

Copied-value checks occur before a typed handler consumes the value.
References carry expectations, not certified behavior. Object and promise
references can share an opaque representation, so generated views do not infer
remote kind from a handle or perform inspection calls.
A promise is passed without waiting, and its fulfillment is checked on observation.
A failed typed observation does not rewrite shared runtime settlement.

Typed call handles preserve immediate sending, pipelining, and passable
arguments. Pipelined calls can execute before local validation of their source
answer. No generated membrane, new promise state machine, or implicit retry
is introduced to promise otherwise.

Server checks belong where public inputs and outputs exist. Loam can produce
a capability reply from an internal creation placeholder, so the handler's
return is not always the public result. Preserve admission and commit ordering,
and never report an invalid or missing reply as proof that no effect occurred.
Prepared mutations retain target, identity, and inputs across submission.
Receipt expiry and uncertain outcomes remain observable.

Model every draft value category and required existing extension. Preserve
supported values without lossy conversion. An existing runtime/profile limit
permits explicit refusal. Missing generator support for a value the raw binding
supports remains unfinished work. Source expressiveness alone does not prove
runtime coverage.

Discovery, compatibility analysis, semantic-equivalence hashes, plugin systems,
and editor services are separate work. A canonical content digest identifies
a description, not remote behavior or authority.

## Alternatives and costs

| Approach | Savings | Remaining cost |
| --- | --- | --- |
| Zig-authored shared schemas | Custom parsing and imports | Zig authoring and compilation, plus the shared model and generators |
| Direct Syrup descriptions | Separate source grammar | More description notation for ordinary methods |
| Preserves Schema | Pattern grammar and schema compiler | Interface semantics and another interpretation of annotations |
| Cap'n Proto frontend | Imports, resolution, annotations, plugins | OCapN mappings, helper types, ordinals, compiler dependency |
| Method-oriented text | Direct application declarations and standalone generation | Parser, diagnostics, formatter, maintenance |

Generation and authoring are separate investments. Zig declarations could
feed the same generators. The text frontend must justify its additional cost
through clearer definitions and the non-Zig authoring workflow, not claim all
of generation's savings as its own. Reuse the existing generation harness and
emitters where their output fits.

The [Preserves experiment](../../research/interface-preserves-spike.md) tested
one-file annotations, not only companion JSON. The tested compiler discarded
reply and bounds metadata. A complete solution still requires interpreting
those semantics. Cap'n Proto can target OCapN without adopting its RPC, but
requires mappings for the full value and invocation model.
The [reuse review](../../research/interface-idl-reuse.md) owns sources and limits.

Measure frontend, shared compiler, emitters, runtime helpers, tests, generated
output, and code removed separately. Include build and call costs.
No measured total size estimate exists. Fewer independently maintained wire
decisions must justify the new implementation. A failed cost or semantic proof
reopens the responsible design choice rather than silently reducing guarantees.

## Evidence and adoption

The [experiment record](../../research/interface-design-proof.md) reports
selected Rust calls and Zig argument checks over a real session, including
bounds, capabilities, malformed replies, and retained mutation replay.
Its committed artifacts do not reproduce the live run or establish a cost
comparison with existing frontends.
It did not qualify a production compiler, complete application, full value
mapping, asynchronous generated APIs, cleanup, or distribution.

Establish useful generation from Syrup before implementing alternative
frontends. Then compare authoring through the same checked model and generators.
Before full application migration, require reproducible evidence, an early
TypeScript promise probe, and an accepted implementation budget. Generation
can succeed while the proposed text frontend fails that decision.

This decision remains proposed through the first generated conversation and
complete Tasks migration. Adoption additionally requires successful reuse in
Rooms management, a qualified TypeScript projection, and a prebuilt-compiler
consumer workflow without Zig installed. The cost and change-workflow evidence
must support the frontend as well as generation before broad rollout.
Implementation order and milestone status belong to the work plan reached from
[the roadmap](../../roadmap.md#what-starts-next).
