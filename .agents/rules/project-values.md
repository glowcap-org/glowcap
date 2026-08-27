---
description: "Zig pancake project values: explicit systems design, polished library surface, no hidden costs."
alwaysApply: true
---

# pancake — Project Values

pancake is a native Zig systems library for OCapN / CapTP. Keep the repository
small, direct, and product-grade.

The destination these values serve is [`docs/vision.md`](../../docs/vision.md).
The values below are how that destination is protected in day-to-day work; read
the vision itself when a tradeoff between them is unclear.

## Values

- **Protocol evidence over implementation folklore.** OCapN behavior, Goblins
  fixtures, and Zig protocol scenarios justify semantic claims. A C ABI dogfood
  consumer proves consumability, not the source of truth.
- **Explicit over implicit.** Ownership, allocation, copying, I/O, scheduling,
  and authority must be visible at their API boundary. Accept a user-authored
  value exactly or refuse without effect; never silently suffix, truncate,
  substitute, or reroute it. In JavaScript and TypeScript, use `== null` /
  `!= null` for ordinary absence; reserve strict equality for discriminants or
  when `null` and `undefined` differ.
- **Effects have a commit point; failures have an owner.** Prepare fallible
  work before mutation or external effect. A refusal is retryable only when it
  committed nothing. After commit, consume success and retain or convert any
  cleanup failure in the state that owns diagnosis. A callback, finalizer,
  destructor, or detached task with no result channel must pre-reserve, defer
  to a fallible owner, or latch its exact failure for the next observable
  boundary. Never dequeue work before success or erase a cause because its
  immediate caller is gone. A discarded error in first-party Zig (`catch` with
  an empty body or a bare return/continue/break) carries an inline
  `// best-effort:` or `// tolerant:` justification naming its bounded loss;
  `zig build source-check` holds this across `src/`, `cli/`, `apps/`,
  `examples/`, and `tools/`.
- **Failure has a boundary, not a blast radius.** Every runtime operation either
  succeeds with committed effects or reports its exact failure after leaving
  the state it owns in a documented condition and settling its owned waiters.
  Retire the smallest irrecoverable scope; independent work stays live. Input,
  I/O, resource pressure, cancellation, and callbacks must not terminate the
  process or leave state ambiguously usable. Initialization may fail before
  publishing a live object; whether that failure ends the process is consumer
  policy. A panic or `unreachable` is reserved for an internal invariant whose
  preconditions exclude runtime input, never an error path.
- **No hidden runtime.** The protocol core is deterministic, sync, and no-I/O.
  Adapters own host integration.
- **Boring public surface.** The C ABI ships as a small declared set of
  composable archives linked à la carte — `libpancake_ocapn`,
  `libpancake_host`, optional `libpancake_driver`, and provider archives such
  as `libpancake_net_transport_tcp` and `libpancake_net_transport_iroh` — each
  with its own header naming only the family it exports (ADR-0059, ADR-0112).
  The standalone provider header is shared vocabulary, not another runtime.
  Each archive
  is itself boring: fixed-width types, `ptr + len` views, opaque handles,
  callbacks, return codes, and explicit release functions.
- **Examples must compile.** Public examples are part of the contract. If a
  README shows a command or a usage pattern, a build step should keep it honest.
- **Performance is correctness pressure.** A wire-path allocation or copy is a
  design event: forbid it, name it, or measure it.
- **DRY, orthogonal, and easier to change.** DRY protects the other values; it
  is not a target for textual deduplication. One authority per fact keeps
  ownership explicit, gives each failure one boundary, makes one test or
  generator sufficient evidence, and prevents performance policy from
  diverging between copies. A new file that re-expresses an already-owned
  subject creates two plausible edit locations and makes the module tree lie
  about ownership; duplicated bodies, tables, constants, and claims drift for
  the same reason. Keep concerns orthogonal: changing one thing must not
  require touching an unrelated one, and an effect stays local to the seam
  that owns it. When two shapes are otherwise equal, pick the one easier to
  change — a shared seam over parallel representations, a generated mirror
  over a hand-kept copy, a check over a convention. Do not merge merely
  similar code when its facts, owners, lifetimes, or failure recipients differ.
- **Small modules, sharp boundaries.** Split by responsibility. A reader should
  know what a file owns before reading its body.
- **The file-length exception list is going to zero.** The list in
  `tools/check/source_check/file_length.zig` names every file still over the
  limit. It is closed, so nothing joins it, and the destination is an empty
  list. Everyone who works here — agent or human — is expected to take turns at
  it, and retiring a file from it is welcome work on its own, needing no other
  reason.
- **A file you open is yours to shorten.** Not whoever wrote it, not the session
  that set its ceiling. "Another agent owns this file", "that is not what this
  change is about", and "the split is bigger than my diff" are the same sentence
  wearing three coats, and none of them is a reason: there are no owners here,
  only the next reader. Splitting a file to make room for a change is the
  ordinary way to work, not a detour from it. The tell that this rule is being
  dodged is a diff that deleted its own lines to stay under a ceiling, which
  leaves the file exactly as long as it was and the debt exactly where it was.
  The [file-budget skill](../skills/file-budget/SKILL.md) is the procedure.
- **Polish matters.** A rough edge in the build, README, examples, or agent
  rules becomes a rough edge in every contribution.
- **Taste becomes code shape.** Do not commit external taste-reference names
  from prompts. Express the prompt through Zig-native control, clear lifetime
  surfaces, small modules, sharp tests, and boring public APIs. Agent economy
  follows the same rule: spend fewer tokens through progressive disclosure,
  focused reads, and deterministic automation, never by weakening code, tests,
  boundaries, ownership, or cost evidence. The maintainer's biography, a
  line-audit claim, and the destination's ambition stay out of human docs;
  they steer the work, they are not copy.

## Release Bar

Work toward a 1.0 where the shape feels inevitable: the networking library a
competent reader would pick at this layer, not a polite CapTP port. A reader
should not be able to imagine a cleaner one without breaking what pancake
protects (performance, architecture, cross-binding interop). Write that
ambition as the work's shape. It is not a slogan for a first-read page.

- **Assess, then act or prove inaction.** Substantial work uses the
  [work skill](../skills/work/SKILL.md): fix what the assessment finds, or show
  gates and documented boundaries that justify leaving it.
- **Names and structure are architecture.** A misleading module or type name is
  a boundary bug, not cosmetics.
- **Order a findings list by severity and blast radius together.** Severity
  says what has to be fixed; blast radius says in what order, because a finding
  that moves a type, an owner, or a boundary decides the shape the others get
  fixed into. Take the severe ones that stand alone straight away. Where a fix
  sits inside a pending structural change, do the structural one first: its
  interim form is not "quick", it is rework with a delay, and the honest
  move when the reshaping change is too big for the session is to name which
  findings are waiting on it rather than spend the session on forms that
  will be torn up. [`ladder.md`](../../docs/ladder.md) already argues this for
  the route to 1.0 ("The order is an argument, not a wish list"); a review's
  findings deserve the same argument.
- **No half measures on touched surfaces.** If you open a layer, leave it
  sharper, code, tests, docs, and examples aligned in the same change.
- **Compound for the next agent.** Accurate living-state docs and passing gates
  matter more than session-local narration.

## Setup Litmus

Before adding setup, build, API, or documentation surface, ask:

- Does this move toward [`docs/vision.md`](../../docs/vision.md), or at least
  hold a line that protects it, rather than trading performance, the
  architecture, or cross-binding interop for local convenience?
- Does this keep framework-shaped ambition (actors, the simulator) _above_ the
  sans-io core instead of pushing authority or I/O down into it?
- Does this make `zig build`, `zig build check`, or first use simpler?
- Does this preserve plain `pancake` artifact names?
- Can a C consumer understand the ABI without knowing Zig?
- Can a Zig consumer understand ownership without reading implementation code?
- Would a hidden allocation, copy, runtime, or protocol authority decision
  become obvious in review?
