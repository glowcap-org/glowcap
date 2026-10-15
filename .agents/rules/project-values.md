---
description: "Project values: explicit systems design, polished library surface, no hidden costs."
alwaysApply: true
---

# glowcap — Project Values

glowcap is a Zig systems library for OCapN / CapTP, serving
[`docs/vision.md`](../../docs/vision.md). Read the vision when two values
below conflict.

- **Protocol evidence over folklore.** OCapN behavior, Goblins fixtures, and
  Zig scenarios justify semantic claims. A binding proves consumability only.
- **Explicit over implicit.** Ownership, allocation, copying, I/O, scheduling,
  and authority are visible at the API boundary. Accept a user-authored value
  exactly or refuse it without effect, and never suffix, truncate, substitute,
  or reroute it. In JS/TS, use `== null` for ordinary absence.
- **Effects have a commit point.** Prepare fallible work before mutation or
  external effect. A refusal is retryable only if it committed nothing. A
  callback, finalizer, or detached task with no result channel pre-reserves,
  defers to a fallible owner, or latches its exact failure. Never dequeue work
  before success. A discarded error in first-party Zig carries an inline
  `// best-effort:` or `// tolerant:` reason naming its bounded loss.
- **Failure has a boundary.** An operation succeeds with committed effects or
  reports its exact failure, leaves its state documented, and settles its
  waiters. Retire the smallest irrecoverable scope. Input, I/O, pressure,
  cancellation, and callbacks never terminate the process. Reserve `panic` and
  `unreachable` for internal invariants.
- **Errors climb to the tier that can act.** The library returns the typed
  cause, settles the owning waiter, or latches it in the diagnostic journal
  (ADR-0115). It logs nothing and chooses no recovery. Applications retry,
  propagate, or record, and the outermost handler shows a person what happened
  and one next action. Count expected-but-rare failures where they are caught.
- **No hidden runtime.** The core is deterministic, sync, and no-I/O.
- **A small C surface.** Composable archives (`libglowcap_ocapn`,
  `libglowcap_host`, optional `libglowcap_driver`, provider archives), each
  with its own header: fixed-width types, `ptr + len` views, opaque handles,
  return codes, explicit release.
- **Examples compile.** A command or pattern a README shows has a build step.
- **One authority per fact.** Duplicated bodies, tables, constants, and claims
  drift. Prefer a shared seam, generated mirror, or check over a parallel copy.
  Of two equal shapes, pick the easier to change. Do not merge code whose facts,
  owners, lifetimes, or failure recipients differ.
- **Small modules, sharp boundaries.** A reader knows what a file owns before
  reading it. Names and structure are architecture, so a misleading name is a
  boundary bug. Name the owner, mechanism, or execution environment: Zig,
  C ABI, LMDB, driver loop, or the specific OS. Avoid "native" as a software
  label, and rename historical names with their owning migration.
- **Every source file fits one read.** `source-check` holds a line limit with
  no exceptions. A file you open is yours to split by subject to make room
  for a change, never to squeeze by deleting lines. The
  [file-budget skill](../skills/file-budget/SKILL.md) is the procedure.
- **Taste lands as structure.** External taste-reference names, the
  maintainer's biography, line-audit claims, and destination slogans stay out
  of committed files. Save agent tokens through routing and checks, never by
  weakening code, tests, or evidence.

## Release bar

At 1.0, someone comparing every option at this layer should pick glowcap and
find no cleaner design that keeps its performance, architecture, and interop
across bindings.

Judge each choice against the optimum: the best balance of performance and
comprehension, working for advanced cases, and obvious to both a computer
scientist and an application developer. Two ways to do one job, a concept that
could merge into a simpler one at no cost, or an advanced case that forces an
awkward path all fall short. Say how far short, then fix it or explain why it
must stay.

- Substantial work follows the [work skill](../skills/work/SKILL.md): fix what
  the assessment finds, or show the checks and boundaries that justify leaving
  it.
- Order findings by severity and blast radius. A fix inside a pending
  structural change waits for the structural change, and you name what waits.
- A touched layer leaves sharper, with code, tests, docs, and examples aligned
  in the same change.
- Before adding surface, ask whether it moves toward the vision, keeps
  framework ambition above the sans-io core, simplifies first use, and keeps
  every allocation, copy, runtime, and authority decision visible in review.
