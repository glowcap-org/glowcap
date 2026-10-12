# One I/O runtime, lane C: a stock Zig Loam worker

Status: active plan. The [one I/O runtime plan](one-io-runtime.md) owns the
rules every batch follows, the survey, the baseline, and the description of
what already exists. Read it first. This lane adds `loam.hosting.Worker` and
builds the C work contract on it. This file is deleted when its last batch is.

Order: C1, then C2 and C3 in any order.

### C1 seam: `loam.hosting.Worker`

Scope: a new `src/loam/hosting/worker.zig` and its re-export from
`src/loam/hosting/mod.zig`, `src/loam/hosting/storage.zig` only if `nextWork` needs a
sibling, `test/loam/hosting/worker_test.zig` (new), `test/all_test.zig`,
`docs/loam.md` (the worker table row and the "three lines" paragraph),
`docs/loam/api.md`. Out of scope: every existing loop (C2), `src/c_abi/loam`
(C3), `bench/`.

Tier assumed: the planner's own tier.

Read first: `src/c_abi/loam/work.zig` (the slot and retirement contract),
`bench/loam/worker_pool.zig` (the threaded shape that exists),
`test/loam/hosting/fixture.zig:86` to `98`, and the sentence in
`docs/loam/architecture.md` that says no worker pool is added (Loam starts no
thread and adds no pool).

The mechanism:

- `Worker(Backend)` is a value the application owns. It holds a fixed number
  of slots (`capacity` is a comptime parameter with the C default of
  `src/c_abi/loam/work.zig` as its documented default). `next(attachment, force_recovery)`
  takes the next request into a free slot or returns null or `error.Busy` on
  the C `Work.next` rules. `run(slot, backend)` executes exactly the four
  arms `glowcap_loam_lmdb_work_run` executes (read, commit, lookup, recover)
  against `Backend`. `complete(slot, attachment)` installs the result through
  `completeRead` / `completeWrite` / `completeLookup` / `resolve` and retires
  the slot. `drive(attachment, backend)` is the synchronous composition
  (`next`, `run`, `complete` until `next` returns null), which is the loop
  every Zig consumer writes today.
- `run` is the one function that may execute on another thread: it reads
  only the slot's borrowed request and the backend. `next` and `complete`
  stay on the owner. The doc comment says so and names
  `bench/loam/worker_pool.zig` as the threaded driver built on it.
- Loam still starts no thread: `Worker` has no `start`.
- `worker_test.zig` proves: `drive` quiesces a fixture to the same state the
  hand loop reaches. A second `next` on a full worker is `error.Busy`.
  Recovery work excludes ordinary work. `complete` on an unrun slot is
  `error.WorkerNotRetired`.

Preserve: `attachment.nextWork`, `completeRead`, `completeWrite`,
`completeLookup`, and `resolve` keep their names and contracts.

Refusals: a worker that owns a backend or a thread.

Verify: `zig build test -Dtest-layer=loam`, `zig build test`, then
`zig build check`.

Commit authorized. Close by replacing this section with the worker's exact
names (type, `drive`, `next`, `run`, `complete`) so C2 and C3 cite them.

### C2 sweep: the hand-written loops use the worker

Scope: the 22 files the lane C survey lists other than
`src/loam/hosting/storage.zig` and `src/c_abi/loam/work.zig`, plus
`bench/loam/README.md` and `docs/loam.md` where they describe the loop. Out of
scope: `src/`.

Tier assumed: mid tier. `zig build test -Dtest-layer=loam`,
`zig build examples`, `zig build bench-loam`, and the crash probes hold it.

Predecessor: C1 on `dev`. Read first: C1's closing note,
`examples/zig/07_durable_card.zig:160` to `170`.

Rule per site:

- A loop of the shape `while (try attachment.nextWork()) |work| switch (work) { .read => ..., .lookup => ..., .write => ... }`
  whose arms only call the backend and the matching `complete*` becomes one
  `worker.drive(&attachment, &db)` on a `Worker` the enclosing fixture or
  main owns. Example: `test/loam/hosting/fixture.zig:90` to `94`.
- A loop with an arm that does more than execute (the crash probes'
  `beginCommit` with a kill boundary, `test/loam_actors_crash.zig:118`. The
  sharing test's ordered expectations, `test/loam/access/sharing_test.zig:206`)
  uses `next`, `run`, and `complete` separately so the extra step sits
  between `run` and `complete`. The probe's `READY` print and kill boundary
  stay exactly where they are relative to the commit.
- `bench/loam/worker_pool.zig`: `execute` calls `Worker.run` on its slot. The
  pool's own slot bookkeeping, events, and threads stay. `bench/loam/executor.zig`
  uses `drive`.
- A prose sentence that describes the caller's own loop names the worker:
  the `docs/loam.md` sentence that says a write is three lines in the worker
  (grep `three lines`), and the `bench/loam/README.md` paragraphs on the four
  persistent workers (grep `four persistent`).

Preserve: every test name. Every bench row name in `bench/loam/README.md`.
The crash probes' output lines.

Refusals: a loop whose arm order a test asserts and the worker would change.

Verify: `zig build test -Dtest-layer=loam`, `zig build examples`,
`zig build loam-actors-crash-test loam-managed-crash-test`, then
`zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section.

### C3: the C `Work` is built on the Zig worker

Scope: `src/c_abi/loam/work.zig`, `src/c_abi/loam/execution_abi.zig`,
`src/c_abi/loam_lmdb/mod.zig:65` (`glowcap_loam_lmdb_work_run`), `test/c_abi/`,
`docs/loam/c-and-rust.md` where it states the worker contract,
`docs/roadmap.md`. Out of scope: bindings, `src/loam`.

Tier assumed: the planner's own tier for the first read of `work.zig`
against the worker. The edit itself is small.

Predecessor: C1 on `dev`. Read first: C1's closing note,
`src/c_abi/loam/work.zig`, `src/c_abi/loam_lmdb/mod.zig:60` to `80`.

Rule: `Work.next` delegates slot selection and the recovery exclusion to the
worker's `next`. `glowcap_loam_lmdb_work_run` calls the worker's `run`.
`Work.complete` calls the worker's `complete`. The C `Work` keeps its
`planned` and `evaluation` fields (the off-thread plan/finish path in
`execution_abi.zig` has no Zig twin and stays). Every `glowcap_loam_*`
signature is unchanged. `docs/roadmap.md`: delete the "One policy home" row
once B2 and B4 have emptied it, or remove its Loam worker clause if they
have not.

Preserve: `loam-rust-test`, the Rust `loam/work.rs` custody contract, the
`glowcap_loam_work_*` symbol rows.

Verify: `zig build test -Dtest-layer=c_abi`, `zig build loam-rust-test`,
then `zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section and this file.
