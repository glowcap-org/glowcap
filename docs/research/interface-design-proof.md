# Interface design comparison and experiment record

A small authoring language over one interface model, serialized canonically
as Syrup, is the candidate recommended for evaluation. The experiments below
have unequal scope and do not establish its superiority over existing frontends.
[ADR-0069](../decisions/adr/ADR-0069-proposed-interface-language.md) owns the
architecture and its alternatives.

## The application author writes one file

The [Tasks example](interface-comparison/tasks.interface) declares all nine
content methods across the board, lists, and tasks. It includes bounds,
capability arguments and results, and receipt-backed changes in one file.
The compiler supplies method symbols, the mutation envelope, and reply checks.
There is no companion method/reply catalog.

A compact part of that file reads:

```text
interface TaskList {
  name() -> Name
  count() -> Count
  task(index: TaskIndex) -> Task

  @loam.receipt
  add(text: Text) -> Task

  @loam.receipt
  move(task: Task, destination: TaskList) -> Count
}
```

The experiment recorded the following generated application workflow:

```rust
let todo = board.list(0).await?;
let done = board.list(1).await?;

let request = todo.prepare_add("generated interface proof").await?;
let task = request.submit().await?;

let movement = todo.prepare_move(&task, &done).await?;
let count = movement.submit().await?;
```

After an uncertain reply, the caller resubmits the same request. There is no
sequence lookup or wire-envelope construction in application code.
The prepared request retains its target and arguments. Rust reference values
continue to use the binding's existing ownership mechanism.

## Why this authoring form is recommended

Preserves Schema expresses message patterns well, but replies, delivery mode,
bounds, and receipt behavior need additional conventions. The
[single-file experiment](preserves-spike/annotated-tasks.prs) puts those
conventions beside the patterns. The upstream compiler accepts the source,
but the [result](preserves-spike/one-source-result.json) shows that it discards
the annotations. A second interpretation step is still necessary.

The [Cap'n Proto source comparison](interface-comparison/tasks.capnp) keeps
annotations in one file and could reuse its compiler. It also exposes ordinals and needs helper types for the OCapN model.
It was reviewed, not compiled in this comparison, so it is an authoring
comparison rather than an executed equivalent.
Direct Syrup descriptions avoid foreign schema semantics but make common
operations read as nested description data. That is a useful baseline rather
than an automatic authoring choice.

The proposed language puts the concepts authors need in the declaration and
keeps serialization in the compiler. Its cost is maintaining a parser and
diagnostics. That cost earns its place only if the complete application and
change workflow remain simpler than the alternatives. The large
[coverage example](interface-language-example.md) remains a set of requirements,
not permission to add transport mechanisms or unrelated framework features.

## Recorded run on 2026-10-26

One typed model generated a Rust caller and Zig argument checks. The Zig checks
were temporarily installed at the existing Tasks content invocation entry
points. The actual Tasks server compiled and ran with its SQLite store.
The generated Rust caller connected over loopback TCP through the existing
binding. It fetched the board and called the generated methods without
interface discovery.

The caller checked bounds, obtained capabilities, and submitted the same
retained add and move requests twice. The task was created once and moved
once, and replay returned the same result. Raw calls with excess arguments
were refused by the generated Zig checks. A malformed reply from a local
actor was refused by the generated Rust decoder.

The model was also encoded and decoded through the pinned OCapN suite's Syrup
codec. Reordering its method dictionary left the canonical bytes unchanged.
The [description snapshot](interface-comparison/tasks-description.json)
shows that serialized model as JSON for inspection, not as another authored
contract. The [observation record](interface-comparison/live-observations.json)
records input and description hashes and the tested scope.

The server ran through `glowcap-dev zig build tasks-server`, and the caller
built and ran through `glowcap-dev cargo` against the existing Rust binding.
Each client run had a 25-second deadline. The server was stopped and every
temporary production-source change restored after the run.

The committed files retain inputs, a description snapshot, and observations.
They omit the generator, client harness, and temporary server integration.
Input hashes identify those inputs but do not verify execution. The live
results cannot be reproduced from a clean checkout and are historical
observations, not independently runnable acceptance evidence.

## What has not passed

This experiment is deliberately narrower than language acceptance.
Discarding a completed reply and replaying a request does not prove recovery
from actual packet loss, cancellation, process death, or every commit outcome.
The text reader is limited, and its diagnostics are not a production language.
No generated Zig client, complete error projection, or broad value-model
implementation was built here.

Pipelining, passable promise arguments, reverse callbacks, failure cleanup,
Goblins optionality, packaging costs, and removal of the old application
encoding remain unproved by this experiment. The implementation plan linked
from [the roadmap](../roadmap.md#what-starts-next) owns the remaining proofs
and the adoption decision.
Neither a working parser nor a successful subset lowers that acceptance bar.
