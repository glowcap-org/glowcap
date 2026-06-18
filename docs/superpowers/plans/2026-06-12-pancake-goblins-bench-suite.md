# pancake ↔ Goblins benchmark suite — Implementation Plan

Role: a historical record. This plan has been carried out — the suite ships
under `bench/goblins/` and runs via `zig build bench-goblins`. The unchecked
task boxes below are the plan as it was written, not an open to-do list;
`bench/goblins/README.md` describes what actually shipped.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a benchmark suite that runs the _same_ Racket capability/actor
application on both Spritely Goblins and pancake (via its Racket binding) over
loopback TCP, and reports latency, throughput, connection scaling, and memory
for a fair pancake-vs-Goblins comparison.

**Architecture:** Each suite is one shared actor-behavior file that `(require)`s
a backend module supplying `{spawn,$,<-,on,methods,bcom}`; that single source
loads on both Goblins and pancake. Substrate-specific bootstrap/driving lives in
small per-backend files off the measured path. A shared, backend-agnostic
metrics module and a single orchestrator spawn each substrate's server in its
own OS process, run the workloads, and emit a comparison report.

**Tech Stack:** Racket 9.2, Spritely Goblins v0.18.0 (`goblins` collection),
pancake's Racket binding (`bindings/racket/pancake.rkt`) over `libpancake`, Zig
`build.zig` for the `bench-goblins` step. Loopback TCP + Syrup on both sides.

---

## Reference: verified facts this plan builds on

These were confirmed by running code in the devcontainer (see the design spec,
`docs/superpowers/specs/2026-06-12-pancake-goblins-bench-suite-design.md`):

- `racket` 9.2, `goblins` v0.18.0, `zig`, and `libpancake` (built by
  `zig build`) are all present.
- Goblins TCP client/server works via
  `conformance/goblins-peer/racket/tcp-netlayer.rkt` + `spawn-mycapn` +
  `($ mycapn 'register actor 'tcp)` (server) and
  `(<- mycapn 'enliven sturdyref)` (client).
- The pancake binding hosts a Goblins-shaped actor over TCP via
  `listen`/`accept`/`conn-publish`/`conn-serve` (server) and
  `connect`/`conn-fetch` +
  `<-`/`on`/`async-flush!`/`async-next-event`/`vat-serve!` (client). See
  `bindings/racket/zig-smoke.rkt` lines 239–284 for the exact verified pattern.
- A Racket module cannot `(require "/abs/path.rkt")`; use
  `(require (file "/abs/path.rkt"))` or a relative path.

## File Structure

All new files under `bench/goblins/`:

| File                  | Responsibility                                                                                                                                                                                                                   |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `metrics.rkt`         | Pure functions: percentiles, throughput math, `/proc/<pid>/status` RSS parsing. Backend-agnostic. Unit-tested.                                                                                                                   |
| `metrics-test.rkt`    | RackUnit tests for `metrics.rkt`.                                                                                                                                                                                                |
| `backend-goblins.rkt` | Re-exports `{spawn,$,<-,on,methods,bcom}` and a server/client bootstrap API, implemented on `goblins`.                                                                                                                           |
| `backend-pancake.rkt` | Re-exports the same names + bootstrap API, implemented on `bindings/racket/pancake.rkt` + `pump.rkt`.                                                                                                                            |
| `pump.rkt`            | The pancake "run-to-quiescence" driver (the fair analog of Goblins' vat loop).                                                                                                                                                   |
| `apps/echo.rkt`       | S0 shared actor behavior + client call-thunk contract.                                                                                                                                                                           |
| `apps/registry.rkt`   | S1 shared actor behavior (capability registry + pipelining).                                                                                                                                                                     |
| `apps/mint.rkt`       | S2 shared actor behavior (mint/purse).                                                                                                                                                                                           |
| `apps/taskboard.rkt`  | S3 shared actor behavior (task board).                                                                                                                                                                                           |
| `server.rkt`          | Server entrypoint: `racket server.rkt <backend> <suite> <host> <port>`; publishes the app root, prints NDJSON readiness, serves until killed.                                                                                    |
| `client.rkt`          | Client driver: connects, runs the four metric measurements for one (backend, suite), prints NDJSON result lines.                                                                                                                 |
| `bench.rkt`           | Orchestrator: for each (suite, backend) spawns `server.rkt` as its own process, runs `client.rkt`, collects results, prints a comparison table, writes a report under `zig-out/bench-reports/`. Honors `--suite=` and `--smoke`. |
| `README.md`           | Living-state: role, fairness principle, run commands.                                                                                                                                                                            |

Modified: `build.zig`, `.agents/rules/cli.md`, `tools/meta_check.zig`,
`docs/boundaries.md`.

## The app contract (every `apps/*.rkt` exports this)

Each app module provides exactly these four bindings so the harness is
app-agnostic:

```racket
;; app-name : symbol — the suite id, e.g. 'echo
(provide app-name server-build client-prepare result-ok?)

;; server-build : backend -> root-actor-ref
;;   Spawn the app's root object(s) in the current vat and return the root ref.
;;   `backend` is the backend struct (see backends) exposing spawn/$/<-/on/methods/bcom.

;; client-prepare : backend root-cap -> (-> exact-nonnegative-integer? vow)
;;   Given the fetched/enlivened root capability, return a THUNK. Calling the thunk
;;   with an iteration index returns a vow (a promise) for one unit of work.
;;   Any one-time client setup (e.g. minting a purse) happens here.

;; result-ok? : any -> boolean
;;   Predicate the harness uses to assert a settled value is correct.
```

`backend` is a struct (defined in each backend module, but with a shared shape)
carrying the actor verbs as fields so an app never imports a substrate directly:

```racket
(struct backend (spawn call send on methods-maker bcom-marker) #:transparent)
```

To keep app source identical and readable, each app begins with the same
destructuring header (shown in each app task).

---

### Task 1: Metrics module (pure, unit-tested)

**Files:**

- Create: `bench/goblins/metrics.rkt`
- Test: `bench/goblins/metrics-test.rkt`

- [ ] **Step 1: Write the failing test**

```racket
;; bench/goblins/metrics-test.rkt
#lang racket/base
(require rackunit
         (file "/workspaces/pancake/bench/goblins/metrics.rkt"))

;; percentile: p50 of 1..100 is 50 (nearest-rank, 1-indexed ceil)
(check-equal? (percentile (build-list 100 add1) 0.50) 50)
(check-equal? (percentile (build-list 100 add1) 0.99) 99)
(check-equal? (percentile '(5) 0.50) 5)

;; throughput-rps: 1000 ops in 0.5 s = 2000 rps
(check-= (throughput-rps 1000 500.0) 2000.0 0.001)

;; rss-kb-of-status parses VmRSS and VmHWM from a /proc status blob (kB)
(define sample "Name:\tracket\nVmHWM:\t  204800 kB\nVmRSS:\t  102400 kB\n")
(check-equal? (rss-kb-of-status sample 'VmRSS) 102400)
(check-equal? (rss-kb-of-status sample 'VmHWM) 204800)

(printf "metrics-test OK\n")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `racket bench/goblins/metrics-test.rkt` Expected: FAIL —
`cannot open module file ... metrics.rkt` (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

```racket
;; bench/goblins/metrics.rkt
#lang racket/base
;; Backend-agnostic measurement helpers for the cross-implementation bench
;; suite: latency percentiles, throughput math, and server-process RSS sampling
;; from /proc. Pure functions plus one filesystem read; no actor or peer code.

(require racket/list)

(provide percentile throughput-rps rss-kb-of-status rss-kb-of-pid mean)

;; Nearest-rank percentile (1-indexed ceil) over a list of reals. `p` in [0,1].
(define (percentile xs p)
  (define sorted (sort xs <))
  (define n (length sorted))
  (cond
    [(zero? n) 0]
    [else
     (define rank (max 1 (inexact->exact (ceiling (* p n)))))
     (list-ref sorted (min (sub1 n) (sub1 rank)))]))

(define (mean xs)
  (if (null? xs) 0 (/ (apply + xs) (exact->inexact (length xs)))))

;; ops over elapsed milliseconds -> requests/second.
(define (throughput-rps ops elapsed-ms)
  (if (<= elapsed-ms 0) 0.0 (/ ops (/ elapsed-ms 1000.0))))

;; Parse a /proc/<pid>/status blob for a `kB` field (VmRSS / VmHWM), in kB.
(define (rss-kb-of-status status field)
  (define rx (regexp (format "(?m:^~a:[ \t]*([0-9]+) kB)" field)))
  (define m (regexp-match rx status))
  (if m (string->number (cadr m)) #f))

;; Read VmRSS / VmHWM (kB) for a live pid, or #f if unreadable.
(define (rss-kb-of-pid pid field)
  (define path (format "/proc/~a/status" pid))
  (and (file-exists? path)
       (rss-kb-of-status (call-with-input-file path port->string) field)))

(require racket/port) ; for port->string used above
```

Note: move the `(require racket/port)` to the top with the other requires when
writing the file.

- [ ] **Step 4: Run test to verify it passes**

Run: `racket bench/goblins/metrics-test.rkt` Expected: PASS — prints
`metrics-test OK`.

- [ ] **Step 5: Commit**

```bash
git add bench/goblins/metrics.rkt bench/goblins/metrics-test.rkt
git commit -m "bench(goblins): add backend-agnostic metrics module"
```

---

### Task 2: The pancake pump (fair scheduler analog)

**Files:**

- Create: `bench/goblins/pump.rkt`

This is the load-bearing fairness piece: a _general_ driver that runs a pancake
connection+vat to quiescence, the analog of Goblins' automatic vat loop. It must
NOT contain any per-call shortcut.

- [ ] **Step 1: Write the implementation**

```racket
;; bench/goblins/pump.rkt
#lang racket/base
;; The pancake "run-to-quiescence" driver. pancake's peer is sans-io and
;; single-owner, so the application cannot rely on a background scheduler the way
;; a Goblins vat does. This pump is the fair analog of that scheduler: it flushes
;; queued outbound work, then reads and dispatches inbound events, repeating until
;; a caller-supplied `settled?` predicate holds. It is deliberately general —
;; there is no per-message fast path here, so the benchmark measures the same
;; "drive the runtime until the promises resolve" loop Goblins runs internally.

(require (file "/workspaces/pancake/bindings/racket/pancake.rkt"))

(provide pump-until!)

;; conn      : a high-level `connection` (from connect/accept)
;; settled?  : (-> boolean) — #t when the awaited work has resolved
;; Drives the connection: flush outbound, then block for one inbound event and
;; serve it into the vat, looping until `settled?` is true. Raises on EOF.
(define (pump-until! conn settled?)
  (define v (conn-vat conn))
  (define ac (conn-async conn))
  (async-flush! ac)
  (let loop ()
    (cond
      [(settled?) (void)]
      [else
       (define ev (async-next-event ac))
       (when (eof-object? ev) (error 'pump-until! "connection closed before settle"))
       (vat-serve! v ev)
       (async-flush! ac)
       (loop)])))
```

- [ ] **Step 2: Defer verification**

`pump.rkt` is exercised end-to-end by Task 4's app correctness tests; it has no
standalone test. Proceed.

- [ ] **Step 3: Commit**

```bash
git add bench/goblins/pump.rkt
git commit -m "bench(goblins): add pancake run-to-quiescence pump"
```

---

### Task 3: Backend shims

**Files:**

- Create: `bench/goblins/backend-goblins.rkt`
- Create: `bench/goblins/backend-pancake.rkt`

Both expose the identical surface so apps and the harness are substrate-blind:

```racket
;; struct backend (verbs the apps use)
(struct backend (spawn        ; (constructor . args) -> ref      [actor-lib spawn]
                  call        ; (ref method . args) -> value     [near-call $]
                  send        ; (ref method . args) -> vow       [eventual <-]
                  on          ; (vow on-ok #:catch on-err) -> void
                  methods-maker) ; a syntactic helper is exported separately
  #:transparent)
;; Plus a server/client lifecycle API (functions, not in the struct):
;;   server-run     : (suite host port build-root) -> never returns (serves)
;;   client-connect : (host port) -> conn-handle
;;   client-fetch   : (conn-handle name) -> root-cap
;;   client-pump    : (conn-handle settled?) -> void
;;   client-close   : (conn-handle) -> void
```

Because `methods` and `bcom` are macros/markers, apps import them directly from
a tiny shared re-export rather than through the struct. To keep the app source
identical, each backend provides a module-level `methods` and `bcom` with the
same name.

- [ ] **Step 1: Write the goblins backend**

```racket
;; bench/goblins/backend-goblins.rkt
#lang racket/base
;; Goblins backend for the bench suite. Wraps the native `goblins` actor verbs
;; and a TCP server/client lifecycle (via the conformance tcp-netlayer) behind the
;; suite's substrate-blind API. No application logic lives here.

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         (only-in goblins/actor-lib/methods methods)
         (file "/workspaces/pancake/conformance/goblins-peer/racket/tcp-netlayer.rkt")
         racket/async-channel)

(provide make-backend methods bcom
         server-run client-connect client-fetch client-pump client-close
         current-machine-run)

;; bcom is Goblins' become; expose under the same name the apps use.
;; (In Goblins the constructor's first arg IS bcom, so apps receive it; we also
;; export a no-op marker for symmetry with pancake. Apps call the injected one.)
(define bcom 'bcom-injected) ; placeholder; apps use the injected bcom parameter.

(struct backend (spawn call send on) #:transparent)

;; A machine-run parameter so apps' server-build can spawn in the right vat.
(define current-machine-run (make-parameter #f))

(define (make-backend)
  (backend
   (lambda (ctor . args) (apply spawn ctor args))
   (lambda (ref method . args) (apply $ ref method args))
   (lambda (ref method . args) (apply <- ref method args))
   (lambda (vow on-ok #:catch [on-err (lambda (e) e)])
     (on vow on-ok #:catch on-err))))

;; ---- server lifecycle ----
;; build-root : backend -> root-ref   (spawns the app root in the vat)
;; Publishes root under swiss-num bytes == (string->bytes/latin-1 name).
(define (server-run name host port build-root)
  (define a-vat (make-vat))
  (a-vat
   'run
   (lambda ()
     (define netlayer (spawn ^tcp-netlayer host port))
     (define mycapn (spawn-mycapn netlayer))
     (define registry ($ mycapn 'get-registry))
     (define root (build-root (make-backend)))
     ($ registry 'register root (string->bytes/latin-1 name))
     (on (<- netlayer 'our-location)
         (lambda (_loc)
           (printf "{\"v\":1,\"event\":\"ready\",\"listen\":\"~a:~a\"}\n" host port)
           (flush-output)))))
  (sync (make-semaphore))) ; serve forever

;; ---- client lifecycle ----
;; A goblins client handle bundles the machine-run, mycapn, and a done channel.
(struct gclient (machine-run mycapn) #:transparent)

(define (client-connect host port)
  (define-vat-run machine-run (make-vat))
  (define netlayer (machine-run (spawn ^tcp-netlayer host (+ port 1000))))
  (define mycapn (machine-run (spawn-mycapn netlayer)))
  (gclient machine-run mycapn))

;; Returns a root capability (a vow that the caller pumps to resolution by using
;; it; goblins resolves enliven lazily, so we hand back the vow and let sends ride
;; on it — promise pipelining is exactly this).
(define (client-fetch handle name)
  (define mr (gclient-machine-run handle))
  (define sref (mr (sturdyref-for name)))
  (mr (<- (gclient-mycapn handle) 'enliven sref)))

;; Goblins drives its own vat loop, so "pump until settled" just blocks the
;; current thread on a channel the caller fills from an `on` handler. The harness
;; uses client-pump uniformly; for goblins it spins the scheduler via sync.
(define (client-pump handle settled?)
  (let loop ()
    (unless (settled?)
      (sleep 0) ; yield to the vat's scheduler threads
      (loop))))

(define (client-close handle) (void))

;; Build the sturdyref the server registered: ocapn://host:port.tcp/s/<swiss>.
;; The harness passes name+host+port through a parameter set before fetch.
(define current-server-node (make-parameter #f))
(provide current-server-node)
(define (sturdyref-for name)
  (define node (current-server-node))
  (ocapn-sturdyref node (string->bytes/latin-1 name)))
```

Note for the implementer: the exact sturdyref/`ocapn-sturdyref` constructor name
comes from `goblins/ocapn/structs-urls`; verify with
`racket -e '(require goblins/ocapn/structs-urls) (ocapn-sturdyref? ...)'` and
adjust to the installed v0.18.0 API. The conformance `tcp-demo.rkt` registers
via `($ mycapn 'register actor 'tcp)` and enlivens via
`(<- mycapn 'enliven sturdyref)`; mirror whatever that path returns. If the
registry hands back a sturdyref object directly at register time, prefer
transporting THAT (serialize via `(require goblins/ocapn/structs-urls)`
printers) rather than reconstructing it.

- [ ] **Step 2: Write the pancake backend**

```racket
;; bench/goblins/backend-pancake.rkt
#lang racket/base
;; pancake backend for the bench suite. Wraps the binding's Goblins-shaped actor
;; verbs and its high-level TCP lifecycle behind the suite's substrate-blind API,
;; driving the sans-io peer with the shared pump. No application logic here.

(require (file "/workspaces/pancake/bindings/racket/pancake.rkt")
         (file "/workspaces/pancake/bench/goblins/pump.rkt"))

(provide make-backend methods bcom
         server-run client-connect client-fetch client-pump client-close)

;; The binding already exports `methods`; re-export it under the same name.
;; `bcom` is the injected constructor arg in the binding too, identical to goblins.
(define bcom 'bcom-injected)

(struct backend (spawn call send on) #:transparent)

;; The binding's verbs require a current-vat; the server/client set it.
(define (make-backend-for v)
  (backend
   (lambda (ctor . args) (with-vat v (apply spawn ctor args)))
   (lambda (ref method . args) (with-vat v (apply $ ref method args)))
   (lambda (ref method . args) (with-vat v (apply <- ref method args)))
   (lambda (vow on-ok #:catch [on-err (lambda (e) e)])
     (with-vat v (on vow on-ok #:catch on-err)))))

(define (make-backend) (error 'make-backend "use server-run/client-connect, which bind a vat"))

;; ---- server lifecycle ----
(define (server-run name host port build-root)
  (define srv (listen host port))
  (printf "{\"v\":1,\"event\":\"ready\",\"listen\":\"~a:~a\"}\n" host (server-port srv))
  (flush-output)
  (let accept-loop ()
    (define hconn (accept srv))
    ;; Publish the app root under `name`; conn-publish wires an export+actor.
    (conn-publish hconn name
                  (lambda (_bcom)
                    ;; build-root expects a backend; conn-publish builds the actor
                    ;; itself, so we instead pre-build the root in the conn's vat.
                    (error "see note")))
    (thread (lambda () (conn-serve hconn)))
    (accept-loop)))

;; ---- client lifecycle ----
(struct pclient (conn) #:transparent)

(define (client-connect host port)
  (pclient (connect host port)))

(define (client-fetch handle name)
  (conn-fetch (pclient-conn handle) name))

(define (client-pump handle settled?)
  (pump-until! (pclient-conn handle) settled?))

(define (client-close handle) (connection-close! (pclient-conn handle)))
```

**Important design note for the implementer (resolves the `server-run` "see
note"):** the binding's `conn-publish` takes a constructor
`(lambda (bcom) behavior)` and hosts it. The app's `server-build` returns a
_root ref_ it may have built from sub-actors. Two clean options — pick (A):

(A) Change the app contract's `server-build` to return a **constructor**
`(lambda (bcom) behavior)` instead of a spawned ref, and have apps build
sub-actors lazily inside method bodies (or via `bcom`). Then `server-run`
(pancake) does `(conn-publish hconn name (server-build))` and `server-run`
(goblins) does
`($ registry 'register (a-vat-run (spawn (server-build))) swiss)`. This keeps
both backends publishing the _same_ constructor. Update Task 4 apps accordingly:
each app's `server-build` returns `(lambda (bcom) (methods ...))`.

Adopt option (A) — it is the only shape that publishes byte-identical actor
behavior on both substrates. The app tasks below are written for option (A).

- [ ] **Step 3: Smoke-load both backends**

Run:

```bash
racket -e '(require (file "/workspaces/pancake/bench/goblins/backend-pancake.rkt")) (displayln "pancake backend loads")'
racket -e '(require (file "/workspaces/pancake/bench/goblins/backend-goblins.rkt")) (displayln "goblins backend loads")'
```

Expected: each prints its "loads" line with exit 0. Fix require/typo errors
until both load.

- [ ] **Step 4: Commit**

```bash
git add bench/goblins/backend-goblins.rkt bench/goblins/backend-pancake.rkt
git commit -m "bench(goblins): add goblins and pancake backend shims"
```

---

### Task 4: Shared apps (S0–S3)

**Files:**

- Create: `bench/goblins/apps/echo.rkt`
- Create: `bench/goblins/apps/registry.rkt`
- Create: `bench/goblins/apps/mint.rkt`
- Create: `bench/goblins/apps/taskboard.rkt`
- Create: `bench/goblins/apps-test.rkt` (correctness on BOTH backends,
  in-process)

Each app uses option (A): `server-build` returns a constructor
`(lambda (bcom) behavior)`. The app imports `methods`/`bcom` from a backend
module passed by the harness — but since `methods` is a macro, apps import it
from a _fixed_ module that the harness aliases. To keep apps backend-blind AND
use the macro, each app takes a `mk` argument that is the backend's
`methods`-maker is not possible for a macro. Therefore apps
`(require (only-in <backend> methods))` indirectly via a shim: create
`bench/goblins/actor-prelude.rkt` that re-exports `methods` and the verb
helpers, selected at load by an environment variable.

- [ ] **Step 1: Create the actor prelude (selects backend at load)**

Create: `bench/goblins/actor-prelude.rkt`

```racket
;; bench/goblins/actor-prelude.rkt
#lang racket/base
;; The single import an app uses for actor syntax. Selects the substrate by the
;; PANCAKE_BENCH_BACKEND env var ("goblins" or "pancake") at module load, and
;; re-exports `methods` (a macro) plus `spawn`/$/<-/on from that substrate. This
;; is what lets one app source compile against either runtime: the macro must come
;; from a real module path, so the choice is made here, once, by dynamic-require.

(require racket/runtime-path)
(provide methods spawn $ <- on bcom-arg)

;; bcom-arg is a no-op alias documenting that an app's constructor first parameter
;; is the injected become capability on both substrates.
(define-syntax-rule (bcom-arg) (void))

(define backend (or (getenv "PANCAKE_BENCH_BACKEND") "pancake"))

;; Re-export the chosen substrate's bindings. `methods` is a macro, so we use
;; `all-from-out` on the dynamically chosen module via a submodule trick: require
;; both, then provide the selected ones. Simplest robust approach: two thin
;; reprovider modules and a require chosen by string.
(require (for-syntax racket/base))
```

**Implementer note:** Racket macros cannot be chosen by a runtime `getenv`
because `require` is static. Resolve this cleanly by **not** sharing the macro
through one prelude. Instead:

- Apps `(require "actor-prelude.rkt")` where `actor-prelude.rkt` is a
  _symlink-free_ file that
  `(require (only-in goblins/actor-lib/methods methods) goblins ...)` — i.e.,
  the app is compiled once per backend by setting `PLTCOLLECTS`/by having TWO
  prelude files and selecting the file at the `server.rkt`/`client.rkt` level
  (which DO know the backend, since it is their argv).

Adopt this concrete shape (final):

- `actor-prelude-goblins.rkt` provides `methods spawn $ <- on` from goblins.
- `actor-prelude-pancake.rkt` provides the same from the pancake binding.
- Each `apps/<name>.rkt` does NOT require a prelude directly. Instead it is a
  **function of the actor verbs**: it provides `server-build`, `client-prepare`,
  `result-ok?`, where `server-build` returns a constructor and the constructor
  body uses `methods` passed in.

Because `methods` is a macro, the cleanest final design is: **apps define
behavior with a plain lambda dispatch, not the `methods` macro.** A plain
dispatch lambda is identical on both substrates and needs no macro import:

```racket
;; dispatch helper used by all apps — plain lambda, no macro, backend-blind.
(define (dispatch table)
  (lambda (method . args)
    (define h (assq method table))
    (if h (apply (cdr h) args) (error 'dispatch "no method: ~a" method))))
```

Put `dispatch` in `bench/goblins/dispatch.rkt` and have every app require it.
This removes the macro-portability problem entirely.

- [ ] **Step 2: Create the dispatch helper**

Create: `bench/goblins/dispatch.rkt`

```racket
;; bench/goblins/dispatch.rkt
#lang racket/base
;; A plain method-dispatch behavior builder used by every bench app. Equivalent to
;; the `methods` macro both substrates ship, but as a backend-blind function so one
;; app source runs on Goblins and pancake without importing either's macro. The
;; leading method symbol selects the handler; `($ obj 'm a)` / `(<- obj 'm a)` both
;; land here because both substrates pass the leading symbol through.
(provide dispatch)
(define (dispatch table)
  (lambda (method . args)
    (define h (assq method table))
    (if h (apply (cdr h) args) (error 'dispatch "no method: ~a" method))))
```

- [ ] **Step 3: Write `apps/echo.rkt`**

```racket
;; bench/goblins/apps/echo.rkt
#lang racket/base
;; S0 calibration: an echo actor. server-build returns a constructor; the actor
;; returns its argument. client-prepare returns a thunk that sends 'echo with a
;; fixed payload. Backend-blind: uses only the verbs/handles the harness passes.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'echo)

;; server-build : ignored backend -> constructor (lambda (bcom) behavior)
(define (server-build _backend)
  (lambda (_bcom)
    (dispatch (list (cons 'echo (lambda (x) x))))))

;; client-prepare : send -> (-> i vow). `send` is (ref method . args) -> vow.
;; root-cap is the fetched echo capability.
(define (client-prepare send root-cap)
  (lambda (_i) (send root-cap 'echo #"ping")))

(define (result-ok? v) (equal? v #"ping"))
```

- [ ] **Step 4: Write `apps/registry.rkt`**

```racket
;; bench/goblins/apps/registry.rkt
#lang racket/base
;; S1: a registry actor that hands back capability references, plus promise
;; pipelining. The root 'lookup returns a freshly-spawned cell capability; the
;; client immediately pipelines a 'get onto that returned promise without waiting
;; for it to resolve — the signature CapTP feature. Stateful: each cell holds a
;; value. Backend-blind via dispatch + injected verbs.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'registry)

;; The registry needs to spawn cells, so server-build closes over the backend's
;; spawn. A cell is a constructor too; we spawn it via the injected spawn.
(define (server-build backend)
  ;; backend exposes a `spawn` field; see backend struct. We accept the raw spawn
  ;; proc as backend here (the harness passes the backend's spawn for server-build).
  (define spawn-proc backend)
  (lambda (_bcom)
    (dispatch
     (list
      (cons 'lookup
            (lambda (key)
              ;; spawn a cell holding `key` as its value; return the capability.
              (spawn-proc
               (lambda (_b)
                 (dispatch (list (cons 'get (lambda () key))))))))))))

;; client-prepare gets (send root-cap). It pipelines: cell-vow = (send root 'lookup k),
;; then (send cell-vow 'get) BEFORE cell-vow resolves.
(define (client-prepare send root-cap)
  (lambda (i)
    (define cell-vow (send root-cap 'lookup (string->bytes/utf-8 (number->string i))))
    (send cell-vow 'get)))

(define (result-ok? v) (bytes? v))
```

**Implementer note:** `server-build` for registry needs the backend's `spawn`.
Standardize the contract: the harness calls `(server-build spawn-proc)` for
_all_ apps, passing the backend's `spawn` procedure (apps that don't need it
ignore the arg, as echo does). Update `apps/echo.rkt` Step 3 `server-build`
param name to `_spawn` for clarity; behavior unchanged. The promise-pipelining
`(send cell-vow 'get)` relies on both substrates accepting a vow as a send
target — verified true for both (Goblins promise pipelining; pancake `<-` to a
`promise-ref`). If pancake's binding rejects a `promise-ref` as a `<-` target in
the installed version, fall back to
`(on cell-vow (lambda (cell) (send cell 'get)))` and document that S1 measures
sequential-resolve rather than pipelining for pancake; prefer the pipelined form
and only fall back if a load test fails.

- [ ] **Step 5: Write `apps/mint.rkt`**

```racket
;; bench/goblins/apps/mint.rkt
#lang racket/base
;; S2: the classic ocap mint/purse. The root is a mint: 'make-purse returns a new
;; purse capability with an initial balance; a purse supports 'balance, 'deposit
;; (amount from another purse via 'withdraw). Exercises capability arguments and
;; stateful turns. One unit of client work: make a purse, deposit into it, read
;; balance. Backend-blind.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'mint)

(define (server-build spawn-proc)
  (lambda (_bcom)
    (dispatch
     (list
      (cons 'make-purse
            (lambda (initial)
              (define bal (box initial))
              (spawn-proc
               (lambda (_b)
                 (dispatch
                  (list
                   (cons 'balance (lambda () (unbox bal)))
                   (cons 'deposit (lambda (amt) (set-box! bal (+ (unbox bal) amt)) (unbox bal)))))))))))))

;; One unit: create a purse with 100, deposit 5, return new balance (105).
;; Pipelined: make-purse returns a vow; deposit rides on it.
(define (client-prepare send root-cap)
  (lambda (_i)
    (define purse-vow (send root-cap 'make-purse 100))
    (send purse-vow 'deposit 5)))

(define (result-ok? v) (equal? v 105))
```

- [ ] **Step 6: Write `apps/taskboard.rkt`**

```racket
;; bench/goblins/apps/taskboard.rkt
#lang racket/base
;; S3: a task board mirroring pancake's cross-language demos. The root board's
;; 'create returns a task capability; the task supports 'assign and 'complete and
;; 'status. One unit of client work: create a task, assign it, complete it, read
;; status. Exercises a returned capability invoked several times. Backend-blind.
(require (file "/workspaces/pancake/bench/goblins/dispatch.rkt"))
(provide app-name server-build client-prepare result-ok?)

(define app-name 'taskboard)

(define (server-build spawn-proc)
  (lambda (_bcom)
    (dispatch
     (list
      (cons 'create
            (lambda (title)
              (define state (box 'open))
              (define who (box #f))
              (spawn-proc
               (lambda (_b)
                 (dispatch
                  (list
                   (cons 'assign (lambda (p) (set-box! who p) 'assigned))
                   (cons 'complete (lambda () (set-box! state 'done) 'done))
                   (cons 'status (lambda () (unbox state))))))))))))

;; One unit: create -> assign -> complete -> status, returning 'done.
;; Uses the pump between steps via the harness (sequential within the unit is fine;
;; the harness's latency/throughput loops call this thunk and await the final vow).
(define (client-prepare send root-cap)
  (lambda (_i)
    (define task-vow (send root-cap 'create #"benchmark"))
    (send task-vow 'assign #"alice")
    (send task-vow 'complete)
    (send task-vow 'status)))

(define (result-ok? v) (eq? v 'done))
```

- [ ] **Step 7: Write the cross-backend correctness test**

Create: `bench/goblins/apps-test.rkt`

This test loads each app and exercises its `server-build` constructor +
`client-prepare` thunk _in-process_ against a plain local dispatch (no sockets),
proving the app logic is correct and identical regardless of substrate. It uses
a trivial local `spawn`/`send` to settle vows synchronously.

```racket
;; bench/goblins/apps-test.rkt
#lang racket/base
(require rackunit
         (file "/workspaces/pancake/bench/goblins/apps/echo.rkt")
         (prefix-in reg: (file "/workspaces/pancake/bench/goblins/apps/registry.rkt"))
         (prefix-in mint: (file "/workspaces/pancake/bench/goblins/apps/mint.rkt"))
         (prefix-in tb: (file "/workspaces/pancake/bench/goblins/apps/taskboard.rkt")))

;; A minimal synchronous local substrate: spawn returns a behavior proc; send
;; calls it immediately and returns its value (vows are just values here). This is
;; enough to prove app logic; the network paths are proven by the live runs.
(define (local-spawn ctor) (ctor 'bcom))
(define (local-send ref method . args) (apply ref method args))

;; echo
(let ([root (local-spawn (server-build local-spawn))])
  (define thunk (client-prepare local-send root))
  (check-true (result-ok? (thunk 0))))

;; registry (pipelining collapses to sequential under local-send)
(let ([root (local-spawn (reg:server-build local-spawn))])
  (define thunk (reg:client-prepare local-send root))
  (check-true (reg:result-ok? (thunk 7))))

;; mint
(let ([root (local-spawn (mint:server-build local-spawn))])
  (define thunk (mint:client-prepare local-send root))
  (check-equal? (thunk 0) 105)
  (check-true (mint:result-ok? (thunk 0))))

;; taskboard
(let ([root (local-spawn (tb:server-build local-spawn))])
  (define thunk (tb:client-prepare local-send root))
  (check-eq? (thunk 0) 'done)
  (check-true (tb:result-ok? (thunk 0))))

(printf "apps-test OK\n")
```

**Implementer note:** `local-send` treats a returned capability (from
`lookup`/`make-purse`/`create`) as a behavior proc and calls it directly, so the
pipelined `(send cell-vow 'get)` works because `cell-vow` _is_ the behavior proc
here. Confirm each app's returned ref is callable by `local-send`; the spawn
returns the constructor's behavior, which is the dispatch lambda — directly
callable. Good.

- [ ] **Step 8: Run the correctness test**

Run: `racket bench/goblins/apps-test.rkt` Expected: PASS — prints
`apps-test OK`. Fix app logic until green.

- [ ] **Step 9: Commit**

```bash
git add bench/goblins/dispatch.rkt bench/goblins/apps/ bench/goblins/apps-test.rkt
git commit -m "bench(goblins): add shared echo/registry/mint/taskboard apps + cross-backend correctness test"
```

---

### Task 5: Server entrypoint

**Files:**

- Create: `bench/goblins/server.rkt`

Resolves the app contract against a chosen backend and serves.

- [ ] **Step 1: Write the server**

```racket
;; bench/goblins/server.rkt
#lang racket/base
;; Bench server entrypoint: racket server.rkt <backend> <suite> <host> <port>.
;; Loads the requested app, builds its root constructor, and serves it on the
;; requested substrate over loopback TCP, printing one NDJSON readiness line.
(require racket/cmdline)

(define args (current-command-line-arguments))
(define backend-name (vector-ref args 0)) ; "goblins" | "pancake"
(define suite (vector-ref args 1))         ; "echo" | "registry" | "mint" | "taskboard"
(define host (vector-ref args 2))
(define port (string->number (vector-ref args 3)))

(define app-path
  (format "/workspaces/pancake/bench/goblins/apps/~a.rkt" suite))
(define app (dynamic-require (string->path app-path) #f))
;; dynamic-require with #f triggers instantiation; pull provides via a 2nd require:
(define server-build
  (dynamic-require (string->path app-path) 'server-build))

(define backend-path
  (format "/workspaces/pancake/bench/goblins/backend-~a.rkt" backend-name))
(define b-server-run (dynamic-require (string->path backend-path) 'server-run))
(define b-make-backend (dynamic-require (string->path backend-path) 'make-backend))

;; server-build needs the backend's spawn proc; backends expose it via make-backend
;; struct field `spawn`. We pass the spawn proc to server-build (option A contract).
;; The backend's server-run handles vat binding and passes us the live spawn.
(b-server-run suite host port server-build)
(file-stream-buffer-mode (current-output-port) 'line)
```

**Implementer note:** the exact wiring of "pass the backend's spawn to
`server-build`" must match how each backend's `server-run` invokes `build-root`.
Standardize: each backend's `server-run` calls `(build-root spawn-proc)` where
`spawn-proc` is its vat-bound spawn, and `build-root` returns the constructor
`(lambda (bcom) behavior)`; the backend then hosts that constructor (goblins:
`(spawn ctor)` then register; pancake: `(conn-publish hconn name ctor)`). Update
Task 3 backends so `server-run`'s signature is
`(server-run name host port build-root)` and internally does
`(define ctor (build-root <vat-bound-spawn>))`. For pancake, `conn-publish`
wants `(lambda (bcom) behavior)` — exactly `ctor`. For goblins, do
`(define root (a-vat-run (spawn ctor)))` then register `root`. Adjust both
backends in Task 3 to this before running Task 6.

- [ ] **Step 2: Smoke-run each (backend × a suite)**

Run (pancake echo; should print a ready line then block — Ctrl-C after you see
it):

```bash
timeout 3 racket bench/goblins/server.rkt pancake echo 127.0.0.1 0 ; echo "exit=$?"
```

Expected: a line like `{"v":1,"event":"ready","listen":"127.0.0.1:NNNNN"}` then
timeout kills it (`exit=124`).

Run (goblins echo):

```bash
timeout 3 racket bench/goblins/server.rkt goblins echo 127.0.0.1 19101 ; echo "exit=$?"
```

Expected: a `ready` NDJSON line, then `exit=124`.

Fix until both print readiness.

- [ ] **Step 3: Commit**

```bash
git add bench/goblins/server.rkt
git commit -m "bench(goblins): add backend-agnostic server entrypoint"
```

---

### Task 6: Client driver (the four metrics)

**Files:**

- Create: `bench/goblins/client.rkt`

Connects to a running server and runs latency, throughput, connections, and
memory measurements for one (backend, suite). Prints NDJSON result lines the
orchestrator parses.

- [ ] **Step 1: Write the client**

```racket
;; bench/goblins/client.rkt
#lang racket/base
;; Bench client: racket client.rkt <backend> <suite> <host> <port> <mode> <n> [conns]
;; Connects to a running bench server and runs ONE measurement `mode`:
;;   latency    — N sequential round-trips; prints p50/p99/p999/mean (ms)
;;   throughput — N units with a fixed in-flight window; prints rps
;;   connections— open `conns` connections; prints total setup ms + per-conn ms
;; (memory is measured by the orchestrator sampling the server pid, not here.)
;; Output: NDJSON result lines on stdout.
(require (file "/workspaces/pancake/bench/goblins/metrics.rkt"))

(define args (current-command-line-arguments))
(define backend-name (vector-ref args 0))
(define suite (vector-ref args 1))
(define host (vector-ref args 2))
(define port (string->number (vector-ref args 3)))
(define mode (vector-ref args 4))
(define N (string->number (vector-ref args 5)))
(define CONNS (if (> (vector-length args) 6) (string->number (vector-ref args 6)) 1))

(define backend-path (format "/workspaces/pancake/bench/goblins/backend-~a.rkt" backend-name))
(define app-path (format "/workspaces/pancake/bench/goblins/apps/~a.rkt" suite))

(define client-connect (dynamic-require (string->path backend-path) 'client-connect))
(define client-fetch   (dynamic-require (string->path backend-path) 'client-fetch))
(define client-pump    (dynamic-require (string->path backend-path) 'client-pump))
(define client-close   (dynamic-require (string->path backend-path) 'client-close))
(define b-make-backend (dynamic-require (string->path backend-path) 'make-backend))

(define client-prepare (dynamic-require (string->path app-path) 'client-prepare))
(define result-ok?     (dynamic-require (string->path app-path) 'result-ok?))

(define (now) (current-inexact-monotonic-milliseconds))

;; The backend's send proc. backend-pancake binds it to a vat at connect; expose a
;; `client-send` accessor so the harness stays substrate-blind.
(define client-send (dynamic-require (string->path backend-path) 'client-send))

(define (settle-vow handle vow)
  ;; Returns the settled value; uses the backend's pump + an observed box.
  (define result (box 'pending))
  (define on-proc (dynamic-require (string->path backend-path) 'client-on))
  (on-proc handle vow (lambda (v) (set-box! result v)))
  (client-pump handle (lambda () (not (eq? 'pending (unbox result)))))
  (unbox result))

(define (run-latency)
  (define handle (client-connect host port))
  (define root (client-fetch handle "root"))
  (define thunk (client-prepare (lambda (ref m . a) (apply client-send handle ref m a)) root))
  ;; warmup
  (settle-vow handle (thunk 0))
  (define lats
    (for/list ([i (in-range N)])
      (define s (now))
      (define v (settle-vow handle (thunk i)))
      (unless (result-ok? v) (error 'latency "bad result ~v" v))
      (- (now) s)))
  (client-close handle)
  (printf "{\"v\":1,\"metric\":\"latency\",\"backend\":\"~a\",\"suite\":\"~a\",\"n\":~a,\"p50_ms\":~a,\"p99_ms\":~a,\"p999_ms\":~a,\"mean_ms\":~a}\n"
          backend-name suite N
          (real->decimal-string (percentile lats 0.50) 4)
          (real->decimal-string (percentile lats 0.99) 4)
          (real->decimal-string (percentile lats 0.999) 4)
          (real->decimal-string (mean lats) 4)))

(define (run-throughput)
  (define handle (client-connect host port))
  (define root (client-fetch handle "root"))
  (define thunk (client-prepare (lambda (ref m . a) (apply client-send handle ref m a)) root))
  (settle-vow handle (thunk 0))
  (define t0 (now))
  ;; Sequential drain is the fair, substrate-blind baseline; an in-flight window
  ;; requires per-substrate multiplexing the pump does not yet model, so v1 issues
  ;; N units back-to-back and divides by wall time (both substrates identical).
  (for ([i (in-range N)])
    (define v (settle-vow handle (thunk i)))
    (unless (result-ok? v) (error 'throughput "bad result ~v" v)))
  (define total (- (now) t0))
  (client-close handle)
  (printf "{\"v\":1,\"metric\":\"throughput\",\"backend\":\"~a\",\"suite\":\"~a\",\"n\":~a,\"total_ms\":~a,\"rps\":~a}\n"
          backend-name suite N
          (real->decimal-string total 2)
          (real->decimal-string (throughput-rps N total) 0)))

(define (run-connections)
  (define t0 (now))
  (define handles
    (for/list ([i (in-range CONNS)])
      (define handle (client-connect host port))
      (client-fetch handle "root")
      handle))
  (define total (- (now) t0))
  ;; Hold them open briefly so the orchestrator can sample server RSS.
  (printf "{\"v\":1,\"metric\":\"connections\",\"backend\":\"~a\",\"suite\":\"~a\",\"conns\":~a,\"total_ms\":~a,\"per_conn_ms\":~a}\n"
          backend-name suite CONNS
          (real->decimal-string total 2)
          (real->decimal-string (/ total (max 1 CONNS)) 4))
  (flush-output)
  (sleep 1.0) ; window for RSS sampling
  (for ([h (in-list handles)]) (client-close h)))

(file-stream-buffer-mode (current-output-port) 'line)
(case mode
  [("latency") (run-latency)]
  [("throughput") (run-throughput)]
  [("connections") (run-connections)]
  [else (error 'client "unknown mode ~a" mode)])
```

**Implementer note (adds two backend exports):** the client needs `client-send`,
`client-on` from each backend, plus `make-backend` for symmetry. Add to BOTH
backends in Task 3:

- `client-send` : `(handle ref method . args) -> vow` — pancake:
  `(with-vat (conn-vat conn) (apply <- ref method args))`; goblins:
  `(apply <- ref method args)` inside the machine-run.
- `client-on` : `(handle vow on-ok) -> void` — pancake:
  `(with-vat (conn-vat conn) (on vow on-ok))`; goblins:
  `((gclient-machine-run handle) (on vow on-ok))`. Re-export both via
  `(provide client-send client-on)`. Keep them tiny and identical in shape.

- [ ] **Step 2: End-to-end live test (pancake echo latency)**

Start a server in the background, run the client, then kill the server:

```bash
zig build   # ensure libpancake is current
racket bench/goblins/server.rkt pancake echo 127.0.0.1 19111 &
SRV=$!; sleep 1
racket bench/goblins/client.rkt pancake echo 127.0.0.1 19111 latency 500
kill $SRV 2>/dev/null
```

Expected: a `{"metric":"latency",...,"p50_ms":...}` NDJSON line, exit 0.

- [ ] **Step 3: End-to-end live test (goblins echo latency)**

```bash
racket bench/goblins/server.rkt goblins echo 127.0.0.1 19121 &
SRV=$!; sleep 1
racket bench/goblins/client.rkt goblins echo 127.0.0.1 19121 latency 500
kill $SRV 2>/dev/null
```

Expected: a `{"metric":"latency",...}` line for goblins. If goblins
enliven/sturdyref wiring fails, fix `backend-goblins.rkt`
`client-fetch`/`current-server-node` against the installed API (use
`tcp-demo.rkt` as the working reference) until this line prints.

- [ ] **Step 4: Commit**

```bash
git add bench/goblins/client.rkt bench/goblins/backend-goblins.rkt bench/goblins/backend-pancake.rkt
git commit -m "bench(goblins): add client driver for latency/throughput/connections"
```

---

### Task 7: Orchestrator

**Files:**

- Create: `bench/goblins/bench.rkt`

Spawns each (suite × backend) server as its own process, runs the client
measurements, samples server RSS for the memory metric, prints a comparison
table, and writes a report.

- [ ] **Step 1: Write the orchestrator**

```racket
;; bench/goblins/bench.rkt
#lang racket/base
;; Orchestrator for the cross-implementation bench suite. For each selected suite
;; and each backend (goblins, pancake), spawn the bench server as its own OS
;; process, run the client measurements, sample the server's RSS for the memory
;; metric, then print a pancake-vs-Goblins comparison table and write a report
;; under zig-out/bench-reports/. Honors --suite=<name|all>, --smoke, --port=N.
(require racket/string racket/list racket/port racket/file
         (file "/workspaces/pancake/bench/goblins/metrics.rkt"))

(define-values (suite-sel smoke? base-port)
  (let loop ([args (vector->list (current-command-line-arguments))]
             [suite "all"] [smoke #f] [port 19200])
    (cond
      [(null? args) (values suite smoke port)]
      [(regexp-match #px"^--suite=(.+)$" (car args)) => (lambda (m) (loop (cdr args) (cadr m) smoke port))]
      [(equal? "--smoke" (car args)) (loop (cdr args) suite #t port)]
      [(regexp-match #px"^--port=(\\d+)$" (car args)) => (lambda (m) (loop (cdr args) suite smoke (string->number (cadr m))))]
      [else (loop (cdr args) suite smoke port)])))

(define ALL-SUITES '("echo" "registry" "mint" "taskboard"))
(define SUITES (if (equal? suite-sel "all") ALL-SUITES (list suite-sel)))
(define BACKENDS '("goblins" "pancake"))

(define LAT-N (if smoke? 20 2000))
(define TPUT-N (if smoke? 20 2000))
(define CONNS (if smoke? 4 200))

(define RACKET (find-executable-path "racket"))
(define (server-path) "/workspaces/pancake/bench/goblins/server.rkt")
(define (client-path) "/workspaces/pancake/bench/goblins/client.rkt")

;; Spawn a server process; wait for its NDJSON "ready" line; return (values proc pid stdout).
(define (start-server backend suite host port)
  (define-values (proc out in err)
    (subprocess #f #f #f RACKET (server-path) backend suite host (number->string port)))
  (let loop ()
    (define line (read-line out))
    (when (eof-object? line) (error 'start-server "~a/~a server exited before ready" backend suite))
    (unless (regexp-match? #px"\"event\":\"ready\"" line) (loop)))
  (values proc (subprocess-pid proc) out))

;; Run a client measurement, returning the parsed NDJSON result line (string).
(define (run-client backend suite host port mode n [conns 1])
  (define-values (proc out in err)
    (subprocess #f #f (current-error-port) RACKET (client-path) backend suite host (number->string port) mode (number->string n) (number->string conns)))
  (define lines (port->lines out))
  (subprocess-wait proc)
  (or (findf (lambda (l) (regexp-match? #px"\"metric\"" l)) lines)
      (error 'run-client "no result from ~a/~a/~a" backend suite mode)))

(define results (make-hash)) ; key (suite backend metric) -> alist of fields

(define (json-field line key)
  (define m (regexp-match (regexp (format "\"~a\":\"?([^,\"}]+)\"?" key)) line))
  (and m (cadr m)))

(define (bench-one suite backend)
  (define port (+ base-port (* 13 (length (hash-keys results))))) ; spread ports
  (define host "127.0.0.1")
  (define-values (proc pid out) (start-server backend suite host port))
  (with-handlers ([(lambda (_) #t) (lambda (e) (subprocess-kill proc #t) (raise e))])
    (define base-rss (or (rss-kb-of-pid pid 'VmRSS) 0))
    (define lat (run-client backend suite host port "latency" LAT-N))
    (define tput (run-client backend suite host port "throughput" TPUT-N))
    ;; connections: spawn client that holds CONNS open ~1s; sample RSS mid-hold.
    (define conn-proc-thread
      (thread (lambda () (run-client backend suite host port "connections" 0 CONNS))))
    (sleep 0.5)
    (define loaded-rss (or (rss-kb-of-pid pid 'VmRSS) base-rss))
    (thread-wait conn-proc-thread)
    (hash-set! results (list suite backend)
              (list (cons 'p50 (json-field lat "p50_ms"))
                    (cons 'p99 (json-field lat "p99_ms"))
                    (cons 'rps (json-field tput "rps"))
                    (cons 'base_rss_kb base-rss)
                    (cons 'loaded_rss_kb loaded-rss)
                    (cons 'per_conn_kb (real->decimal-string (/ (max 0 (- loaded-rss base-rss)) (max 1 CONNS)) 1))))
    (subprocess-kill proc #t)
    (subprocess-wait proc)))

(for ([suite (in-list SUITES)])
  (for ([backend (in-list BACKENDS)])
    (printf "running ~a / ~a ...\n" suite backend) (flush-output)
    (bench-one suite backend)))

;; ---- Report ----
(define (row suite)
  (define g (hash-ref results (list suite "goblins") #f))
  (define p (hash-ref results (list suite "pancake") #f))
  (define (f r k) (if r (cdr (assq k r)) "-"))
  (format "~a\n  goblins: p50=~ams p99=~ams rps=~a per_conn=~akB\n  pancake: p50=~ams p99=~ams rps=~a per_conn=~akB"
          suite
          (f g 'p50) (f g 'p99) (f g 'rps) (f g 'per_conn_kb)
          (f p 'p50) (f p 'p99) (f p 'rps) (f p 'per_conn_kb)))

(define report
  (string-append
   "pancake vs Goblins — bench suite\n"
   (format "mode=~a suites=~a\n\n" (if smoke? "smoke" "full") (string-join SUITES ","))
   (string-join (for/list ([s (in-list SUITES)]) (row s)) "\n\n")
   "\n"))

(display report)
(define out-dir "/workspaces/pancake/zig-out/bench-reports")
(make-directory* out-dir)
(define stamp (number->string (current-seconds)))
(call-with-output-file (build-path out-dir (format "goblins-compare-~a.txt" stamp))
  (lambda (o) (display report o)) #:exists 'replace)
(printf "\nreport written to ~a/goblins-compare-~a.txt\n" out-dir stamp)
```

- [ ] **Step 2: Run the orchestrator in smoke mode**

```bash
zig build
racket bench/goblins/bench.rkt --smoke --suite=echo
```

Expected: prints `running echo / goblins ...`, `running echo / pancake ...`,
then a comparison block for `echo` with non-`-` numbers on both rows, then a
"report written to ..." line. Fix wiring until both backends report.

- [ ] **Step 3: Run full echo + registry**

```bash
racket bench/goblins/bench.rkt --suite=echo
racket bench/goblins/bench.rkt --suite=registry
```

Expected: full-count comparison blocks; both backends populated. Investigate any
`-` (means that backend's measurement failed).

- [ ] **Step 4: Commit**

```bash
git add bench/goblins/bench.rkt
git commit -m "bench(goblins): add orchestrator with comparison report"
```

---

### Task 8: Build integration

**Files:**

- Modify: `build.zig` (add `-Dbench-suite`/`-Dbench-smoke` options near line
  196; add the step near the goblins-interop block, ~line 570)

- [ ] **Step 1: Add the options**

After the `pin_port`/`attach` options (around `build.zig:197`), add:

```zig
const bench_suite = b.option([]const u8, "bench-suite", "Select a bench-goblins suite (echo|registry|mint|taskboard|all; default all)");
const bench_smoke = b.option(bool, "bench-smoke", "Run bench-goblins with tiny smoke counts") orelse false;
```

- [ ] **Step 2: Add the step**

After the `goblins_clients` loop (around `build.zig:570`), add:

```zig
// Cross-implementation benchmark suite: the SAME Racket actor application run
// on both Spritely Goblins and pancake (via the Racket binding) over loopback
// TCP, reporting latency, throughput, connection setup, and per-connection
// memory. Needs `racket` + the `goblins` collection on PATH, so it is a
// sibling of `check`, never part of the hermetic gate. Numbers are reported,
// never gated on wall-clock (matching the other benches).
const run_bench_goblins = addInstalledSystemRun(b, &.{ "racket", "bench/goblins/bench.rkt" });
if (bench_smoke) run_bench_goblins.addArg("--smoke");
if (bench_suite) |s| run_bench_goblins.addArg(b.fmt("--suite={s}", .{s}));
if (pin_port) |p| run_bench_goblins.addArg(b.fmt("--port={d}", .{p}));
const bench_goblins_step = b.step("bench-goblins", "Cross-impl benchmark: same Racket app on Goblins vs pancake (needs racket + goblins)");
bench_goblins_step.dependOn(&run_bench_goblins.step);
```

- [ ] **Step 3: Verify the step is registered and runs**

Run:
`zig build bench-goblins -Dbench-smoke=true -Dbench-suite=echo 2>&1 | tail -20`
Expected: builds libpancake, runs the orchestrator, prints the echo comparison +
"report written" line, exit 0.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: add zig build bench-goblins (cross-impl bench, sibling of check)"
```

---

### Task 9: Docs + meta-check

**Files:**

- Create: `bench/goblins/README.md`
- Modify: `.agents/rules/cli.md` (add the `bench-goblins` line to the command
  inventory)
- Modify: `tools/meta_check.zig` (register the README as a living-state surface
  if it tracks per-file living-state; confirm the build-step-doc check passes)
- Modify: `docs/boundaries.md` (note the cross-impl comparison exists and is
  reported, not gated)

- [ ] **Step 1: Write the README**

````markdown
# bench/goblins

The cross-implementation benchmark suite. It runs the _same_ Racket
capability/actor application on both Spritely Goblins and pancake (through the
Racket binding over `libpancake`), across loopback TCP, and reports latency,
throughput, connection setup, and per-connection memory.

## Fairness

One application source per suite (`apps/*.rkt`) loads unchanged on both
substrates. Both run the same programming model (eventual-send plus promise
observers) and the same driving model: Goblins drains turns through its vat
loop; pancake drains through the general `pump.rkt`, never a per-message fast
path. The only intended difference is the substrate — pancake's compiled Zig
protocol core versus Goblins' native Racket runtime. Numbers are reported, never
gated on wall-clock.

## Suites

- `echo` — calibration baseline (raw round-trip overhead).
- `registry` — capability lookup returning references, plus promise pipelining.
- `mint` — ocap mint/purse: capabilities created and passed as references.
- `taskboard` — a returned task capability invoked several times.

## Running

```sh
zig build bench-goblins                      # all suites, full counts
zig build bench-goblins -Dbench-suite=echo   # one suite
zig build bench-goblins -Dbench-smoke=true   # tiny counts (liveness)
```
````

Reports are written under `zig-out/bench-reports/`.

```
- [ ] **Step 2: Add the cli rule line**

In `.agents/rules/cli.md`, in the `zig build` command inventory list, add (keep alphabetical/grouped with the other bench lines):
```

zig build bench-goblins # cross-impl benchmark: same Racket app on Goblins vs
pancake (needs racket + goblins)

```
- [ ] **Step 3: Run meta-check**

Run: `zig build meta-check 2>&1 | tail -20`
Expected: PASS. The meta-check enforces that every documented `zig build` step is real and every step is documented; the new step + its cli-rule line must agree. If meta-check tracks `bench/goblins/README.md` as a living-state surface, register it where the registry lives (search `tools/meta_check.zig` for how `bench/` or other READMEs are listed). Fix until green.

- [ ] **Step 4: Note the boundary in docs/boundaries.md**

Find the benchmark paragraph in `docs/boundaries.md` (it mentions `zig build bench-codec` and `zig build bench-peer-scaling`) and add one sentence:
```

`zig build bench-goblins` reports the same Racket application's latency,
throughput, connection setup, and per-connection memory on Goblins versus
pancake; like the other benches its numbers are reported, not gated.

````
- [ ] **Step 5: Commit**

```bash
git add bench/goblins/README.md .agents/rules/cli.md tools/meta_check.zig docs/boundaries.md
git commit -m "docs: document the cross-impl bench suite + wire meta-check"
````

---

### Task 10: Final verification

- [ ] **Step 1: Run the hermetic gate (must be unaffected)**

Run: `zig build check 2>&1 | tail -20` Expected: PASS. The bench suite is a
sibling step, so `check` must not run it and must not regress.

- [ ] **Step 2: Run the full bench suite once**

Run: `zig build bench-goblins 2>&1 | tail -40` Expected: comparison blocks for
all four suites, both backends populated, a report written under
`zig-out/bench-reports/`.

- [ ] **Step 3: Run the smoke path (future liveness hook)**

Run: `zig build bench-goblins -Dbench-smoke=true 2>&1 | tail -20` Expected: same
shape, tiny counts, completes in a few seconds.

- [ ] **Step 4: Final commit (if anything changed during verification)**

```bash
git add -A
git commit -m "bench(goblins): final verification fixes"
```

---

## Self-Review

**Spec coverage:**

- Verified foundation → Task 0 reference section + live tests in Tasks 5/6.
- Fairness principle (one app source, same programming + driving model, general
  pump) → Task 2 (`pump.rkt`), Task 4 (shared `apps/`), Task 3 (backends
  symmetric).
- Three suites + echo baseline → Task 4 (echo/registry/mint/taskboard).
- Four metrics → Task 6 (latency/throughput/connections) + Task 7 (memory via
  RSS sampling).
- Separate-process memory attribution → Task 7 (`subprocess` server +
  `rss-kb-of-pid`).
- Build step, sibling of check, `--smoke`, suite select → Task 8.
- Docs + meta-check living-state → Task 9.
- Out-of-scope boundaries (no full Goblins lib, no wall-clock gate, loopback
  only) → respected; not implemented.

**Placeholder scan:** The macro-portability and backend-spawn wiring carried
real "implementer notes" with the concrete resolution (use `dispatch.rkt` not
the `methods` macro; option (A) constructor contract; add
`client-send`/`client-on` to backends). These are decisions, not TBDs. The
Goblins sturdyref/enliven exact constructor is flagged to verify against the
installed v0.18.0 API using `tcp-demo.rkt` as the working reference — this is
necessary because the installed API is the authority, and Task 6 Step 3 is the
gate that forces it correct.

**Type consistency:** `server-build` takes the backend spawn proc and returns a
constructor `(lambda (bcom) behavior)` in every app and both backends (option A,
fixed in Task 3/5 notes). `client-prepare` takes a `send` proc + root-cap and
returns `(-> i vow)` in every app. `result-ok?` is `(-> any boolean)`
everywhere. Backends export the same names: `make-backend`, `server-run`,
`client-connect`, `client-fetch`, `client-pump`, `client-close`, `client-send`,
`client-on`, `methods`, `bcom`. Metrics: `percentile`, `throughput-rps`,
`rss-kb-of-status`, `rss-kb-of-pid`, `mean` — used consistently in client +
orchestrator.

**Known risk carried into execution:** the Goblins client `enliven`/sturdyref
transport is the one place the installed API must be matched empirically (Task 6
Step 3). If reconstructing the sturdyref proves fiddly, the robust alternative
is to have the Goblins server print its full sturdyref string in the readiness
NDJSON and have the Goblins client parse + `string->ocapn-sturdyref` it — add
that field to `server-run` (goblins) and `client-fetch` (goblins) if needed.
