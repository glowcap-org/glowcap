#lang racket/base
;; ── Actors: Spritely Goblins for Racket, the local half ───────────────────────
;; This is Goblins, faithful to its feel: you write an actor as a constructor
;; `(define (^name bcom arg …) <behavior>)` that the vat calls once at spawn, and
;; the behavior it returns is a procedure the vat invokes on each call. State
;; lives in the constructor's closure; `bcom` ("become") swaps the behavior for
;; the next turn. `methods` gives you a behavior that dispatches on a leading
;; method symbol. You reach an actor three ways: `$` is the synchronous near-call
;; (local actors only), `<-` is the location-transparent eventual-send that
;; returns a promise (a "vow"), and `on` registers a one-shot listener on a vow.
;;
;; The vat is the LOCAL half only: cells, the queued-turn loop (`drive`), local
;; vows and their listeners, `bcom`, and the time-travel history. Everything
;; wire-shaped — hosting exports, far sends, far vows, three-party redemption —
;; lives in the byte-fed host archive (libpancake_host) behind
;; `private/session.rkt`. A session installs a `far-ops` record into its
;; vat, so `<-` to a far reference and `on` over a far vow stay
;; location-transparent for the application; a pure-local vat (no session)
;; refuses far work with a clear error, as a peerless Goblins vat would.

(require racket/match
         "constants.rkt"
         "finalizer-diagnostics.rkt"
         "value.rkt"
         (for-syntax racket/base))

(provide (all-defined-out))


;; A local actor reference: the vat that owns it and the actor's id within it.
;; Carries no behavior itself, the behavior is mutable state the vat holds, so a
;; reference stays valid across `bcom`.
(struct actor-ref (vat id) #:transparent)

;; A promise for a local eventual-send's result, settled during `drive`. (A far
;; send's promise is the connection's vow handle, settled by the host when the
;; partner's resolution arrives.)
(struct local-vow (vat id) #:transparent)

;; `bcom` is a capability the vat injects into a constructor, never a value a
;; user can forge. `(bcom new-behavior)` swaps this actor's behavior for the next
;; turn; `(bcom new-behavior result)` also returns `result` from the current
;; turn. We tag the swap so the vat can recognize it on the way out of a turn.
(struct become (behavior result) #:transparent)

;; The vat that `spawn`/`$`/`<-`/`on` act in. Bound for the extent of a turn (and
;; by `with-vat`/`vat-run`), the way Goblins binds its current syscaller.
(define current-vat (make-parameter #f))

(define (the-vat who)
  (or (current-vat) (error who "no current vat, call inside (with-vat v …) or (vat-run v thunk)")))

;; The turn loop. `cells` maps an actor id to a box holding its current behavior
;; procedure; `next` hands out fresh ids; `queue` holds pending local sends;
;; `listeners` maps a local vow id to its one-shot listener; `exports` maps a
;; peer export id to a local actor id, so a near reference resolves to its own
;; actor in process (`vat-resolve-target`).
;; `tt` is #f for the default (fast, in-place) vat, or a `time-travel` record
;; when the vat retains a revisable history of behaviors (see `make-vat
;; #:time-travel?`); it never touches the live near-call path.
;; `far` is a box holding the connection-installed far half (`far-ops`), or #f
;; for a pure-local vat: how `<-`/`<-np` reach a far reference, how `on`
;; observes a far vow, and how `break-far-vows!` severs them on disconnect. The
;; box keeps the vat itself connection-agnostic.
;; `revocables` maps a caretaker proxy's actor id to the shared `live` box
;; `session-caretaker` installs; `session-revoke!` clears the flag and drops the row.
(struct vat (cells next queue listeners exports tt far revocables) #:transparent)

;; A behavior's tail-forward of its answer to another reference — the binding's
;; `Turn.forward` (ADR-0064). A behavior returns `(forward target method args)`
;; instead of a value, and the vat resolves the caller's answer from
;; `(<- target method . args)`: a local target near-calls (composing if it
;; forwards again), a far target eventual-sends and defers until the reply
;; settles. It is the whole mechanism behind a caretaker/attenuator — each is an
;; ordinary spawned actor whose behavior forwards (or raises to refuse), so the
;; proxy is a plain near capability called locally or over the wire alike.
(struct forward (target method args) #:transparent)

;; Hop cap and cycle message live in constants.rkt (mirrored against
;; PANCAKE_MAX_LOCAL_FORWARD_HOPS). Sentinels the shared chase returns so
;; callers translate them into error / on-break / turn-break.
(struct forward-cycle () #:transparent)
(struct hop-broke (message) #:transparent)

;; Chase a Forward chain while each *resolved* target is a local `actor-ref`.
;; `run-hop` runs one near hop: `(target method args) -> next-value` (may
;; return a `hop-broke`). `#:resolve-target` maps the forward's target before
;; the actor-ref? test (vat-resolve-target on the wire path; identity under
;; `$`). Returns a plain value, a surviving `forward` (target already
;; resolved), a `forward-cycle`, or a `hop-broke`. Shared by `$`
;; (`near-resolve`), local drive (`resolve-behavior`), and the wire trampoline
;; (`settle-turn-reply`).
(define (chase-local-actor-forwards value run-hop
                                    #:resolve-target [resolve-target values])
  (let loop ([value value] [hops 0])
    (cond
      [(forward? value)
       (define target (resolve-target (forward-target value)))
       (cond
         [(actor-ref? target)
          (if (>= hops MAX-LOCAL-FORWARD-HOPS)
              (forward-cycle)
              (let ([next (run-hop target
                                   (forward-method value)
                                   (forward-args value))])
                (if (hop-broke? next)
                    next
                    (loop next (add1 hops)))))]
         [else (forward target (forward-method value) (forward-args value))])]
      [else value])))

;; The connection-installed far half. `send` is
;; `(ref method-symbol args answer?) -> vow-or-void` — the wire `<-`/`<-np`;
;; `on` is `(a-vow listener) -> void`, registering the one-shot `(value
;; broken?)` listener on a far vow (firing immediately from the vow's settled
;; state when the resolution already arrived); `break` is `(message) -> void`,
;; breaking every far vow still parked on the connection.
(struct far-ops (send on break) #:transparent)

;; Install the far half into `v`. Binding-internal: `private/session.rkt`
;; calls it as a connection's vat is built.
(define (vat-install-far! v ops) (set-box! (vat-far v) ops))

(define (vat-far-ops who v)
  (or (unbox (vat-far v))
      (error who "this vat has no connection — far sends need a connection's vat")))

;; Time-travel state for a vat opted into snapshotting. `mirror` is an immutable
;; id→behavior map kept in step with the live `cells` — each spawn and each
;; `bcom` writes the new behavior into it in O(log n). `history` is the stack of
;; mirror versions, one per state-changing turn. Because behaviors are immutable
;; and the maps share structure, a snapshot is just the current mirror (O(1)) and
;; retaining every turn costs only the changed path — the same shape Goblins's
;; `snapshot-whactormap` has. This is the standing cost of the feature being on;
;; it captures behaviors only, so it buys revisability only for actors whose
;; state lives in their behavior (functional `bcom`), not in a private box.
(struct time-travel (mirror history) #:transparent)

;; (make-vat #:time-travel? #f), a vat of local actors. `#:time-travel? #t` opts
;; every actor in this vat into a retained, revisable behavior history reachable
;; through `vat-snapshot` / `vat-restore!`; the default vat keeps no history and
;; its turn path is the in-place box write below, unchanged. This is the
;; adapter-local Racket actor runtime, not the native Vat owned by PancakeHost. A
;; connection builds one and installs the far half; an application uses
;; `session-vat`.
(define (make-vat #:time-travel? [time-travel? #f])
  (vat (make-hasheqv) (box 1) (box '()) (make-hasheqv) (make-hasheqv)
       (and time-travel? (time-travel (box (hasheqv)) (box '())))
       (box #f)
       (make-hasheqv)))

;; Record an actor's current behavior into the time-travel mirror and push the
;; new mirror version onto the history, but only when the vat opted in. For the
;; default vat this is a single predicate test, so the hot turn path pays nothing
;; when the feature is off.
(define (tt-record! v id behavior)
  (define tt (vat-tt v))
  (when tt
    (define snapshot (hash-set (unbox (time-travel-mirror tt)) id behavior))
    (set-box! (time-travel-mirror tt) snapshot)
    (set-box! (time-travel-history tt) (cons snapshot (unbox (time-travel-history tt))))))

;; (vat-snapshot v) — the current revisable state of every actor as an immutable
;; id→behavior map, captured in O(1). Errors on a vat that did not opt in.
(define (vat-snapshot v)
  (define tt (vat-tt v))
  (unless tt (error 'vat-snapshot "vat is not in time-travel mode — make it with #:time-travel? #t"))
  (unbox (time-travel-mirror tt)))

;; (vat-restore! v snap) — rewind every actor present in `snap` to the behavior
;; it held there and reset the mirror to it. Actors spawned after `snap` keep
;; their live cell but are absent from the restored mirror, so a later snapshot
;; reflects the rewound set. Errors on a vat that did not opt in. A hosted
;; actor's trampoline reads the CURRENT cell on every call, so a restore
;; retargets wire delivers the moment it returns — nothing is captured.
(define (vat-restore! v snap)
  (define tt (vat-tt v))
  (unless tt (error 'vat-restore! "vat is not in time-travel mode — make it with #:time-travel? #t"))
  (for ([(id behavior) (in-hash snap)])
    (define cell (hash-ref (vat-cells v) id #f))
    (when cell (set-box! cell behavior)))
  (set-box! (time-travel-mirror tt) snap))

;; Run `thunk` with `v` as the current vat. `with-vat` is the macro form.
(define (vat-run v thunk) (parameterize ([current-vat v]) (thunk)))
(define-syntax-rule (with-vat v body ...) (vat-run v (lambda () body ...)))

;; ── methods: a behavior that dispatches on a leading method symbol ────────────
;; `(methods [(verb formal …) body …] …)` expands to a procedure of
;; `(method . args)`. `($ obj 'set 5)` runs the `[(set new) …]` clause with
;; `new` bound to 5. An unknown method raises, settling a far call as a break.
(define-syntax (methods stx)
  (syntax-case stx ()
    [(_ [(verb formal ...) body ...] ...)
     #'(lambda (method . actual)
         (case method
           [(verb) (apply (lambda (formal ...) body ...) actual)] ...
           [else (error '$ "object has no method: ~a" method)]))]))

;; ── spawn: construct a local actor in the current vat ─────────────────────────
;; `(spawn ^name arg …)` calls the constructor once with an injected `bcom` plus
;; `arg …`, stores the behavior it returns, and returns a local `actor-ref`.
(define (spawn constructor . args)
  (define v (the-vat 'spawn))
  (define id (unbox (vat-next v)))
  (set-box! (vat-next v) (add1 id))
  (define cell (box #f))
  (hash-set! (vat-cells v) id cell)
  ;; `bcom` closes over this actor's cell. It only records the swap; the vat
  ;; applies it after the turn returns, so a `bcom` mid-turn cannot tear the
  ;; behavior out from under the call in flight.
  (define (bcom new-behavior [result (void)]) (become new-behavior result))
  (define behavior (apply constructor bcom args))
  (set-box! cell behavior)
  (tt-record! v id behavior)
  (actor-ref v id))

;; ── $ : the synchronous near-call ─────────────────────────────────────────────
;; `($ ref 'method arg …)` runs `ref`'s behavior now and returns its value.
;; Legal only for a local actor in the current vat; a far ref must use `<-`,
;; exactly as Goblins forbids `$` to a far ref. A `bcom` the behavior returns
;; swaps the cell and yields the `bcom` result.
(define ($ ref method . args)
  (cond
    [(actor-ref? ref) (near-resolve (run-turn ref method args))]
    [(ref? ref) (error '$ "cannot synchronously call a Host reference; use <-")]
    [else (error '$ "not an actor reference: ~a" ref)]))

;; Resolve a near-call result: a value returns directly; a `forward` (a
;; caretaker/attenuator) near-calls its local target and chases the chain, so a
;; caretaker over an attenuator composes — bounded by the hop cap, so a proxy
;; cycle raises instead of spinning. A forward to a far target is illegal under
;; `$`, exactly as `$` to a far ref is — the eventual `<-` path defers it
;; instead.
(define (near-resolve value)
  (define result
    (chase-local-actor-forwards value
                                (lambda (target method args)
                                  (run-turn target method args))))
  (cond
    [(forward-cycle? result) (error FORWARD-CYCLE-MESSAGE)]
    [(forward? result)
     (error '$ "cannot near-call a proxy forwarding to a far reference — use <-")]
    [else result]))

;; Run one turn of a local actor: invoke its behavior, and if it returned a
;; `bcom`, install the new behavior and yield the bcom's result. This is the one
;; place a behavior runs — the local `$`/`drive` paths and the hosted-actor
;; trampoline (`private/trampoline.rkt`) all call it, so `bcom` and
;; time-travel behave identically whoever called the actor.
(define (run-turn ref method args)
  (define v (actor-ref-vat ref))
  (define cell (hash-ref (vat-cells v) (actor-ref-id ref)
                         (lambda () (error '$ "no such actor: ~a" (actor-ref-id ref)))))
  (define behavior (unbox cell))
  (define result (parameterize ([current-vat v]) (apply behavior method args)))
  (cond
    [(become? result)
     (set-box! cell (become-behavior result))
     (tt-record! v (actor-ref-id ref) (become-behavior result))
     (become-result result)]
    [else result]))

;; ── <- : the eventual-send (returns a vow) ────────────────────────────────────
;; `(<- ref 'method arg …)` is location-transparent. To a local actor it queues
;; a turn for `drive` and returns a `local-vow`. To a far reference (or a far
;; vow, which pipelines the deliver against the unresolved answer, ADR-0007) it
;; rides the connection's host through the vat's installed far half, returning
;; the connection's vow handle.
(define (<- ref method . args)
  (cond
    [(actor-ref? ref) (queue-local-send ref method args)]
    ;; A far reference and a far vow ride the same installed far half, which
    ;; classifies its own target (a vow pipelines against the answer).
    [else ((far-ops-send (vat-far-ops '<- (the-vat '<-))) ref method args #t)]))

;; `<-np` ("no promise") is the fire-and-forget eventual-send: deliver with no
;; answer requested, return void. To a local actor it queues a promise-less turn;
;; to a far reference it sends a deliver with no answer through the far half.
(define (<-np ref method . args)
  (cond
    [(actor-ref? ref)
     (define vow (queue-local-send ref method args))
     (on vow #:catch
         (lambda (message)
           (record-runtime-failure!
            'application-observer "tell.behavior"
            (exn:fail message (current-continuation-marks)))))
     (void)]
    [else ((far-ops-send (vat-far-ops '<-np (the-vat '<-np))) ref method args #f) (void)]))

;; One queued local eventual-send: the target actor, the turn's method and args,
;; and the `local-vow` id its result settles. `queue-local-send` conses these
;; onto the vat queue and `drive` drains them.
(struct queued-send (ref method args vow-id) #:transparent)

(define (queue-local-send ref method args)
  (define v (actor-ref-vat ref))
  (define id (unbox (vat-next v)))
  (set-box! (vat-next v) (add1 id))
  (set-box! (vat-queue v) (cons (queued-send ref method args id) (unbox (vat-queue v))))
  (local-vow v id))

;; ── on : register a one-shot listener on a vow ────────────────────────────────
;; `(on a-vow on-fulfilled #:catch on-broken #:finally on-finally #:promise? #t)`
;; mirrors Goblins's `on`. The fulfilled handler is optional and positional; with
;; `#:promise? #t` `on` returns a new vow that settles with the handler's result,
;; so you can chain. A local vow fires during `drive`; a far vow fires when the
;; host serves the partner's resolution — or immediately, from the vow's settled
;; state, when the resolution already arrived before the listener.
(define (on a-vow [on-fulfilled #f]
            #:catch [on-broken #f] #:finally [on-finally #f] #:promise? [promise? #f])
  (define v (the-vat 'on))
  (define chained (and promise? (let ([id (unbox (vat-next v))])
                                  (set-box! (vat-next v) (add1 id))
                                  (local-vow v id))))
  ;; A listener is `(value broken?)`: `broken?` is #f on fulfill (value is the
  ;; payload) and #t on break (value is the message). It runs the right handler,
  ;; the finally, and — when chaining — settles the returned vow.
  (define (listener value broken?)
    (define outcome
      (with-handlers ([converts-to-broken? (lambda (e) (cons 'broken (exn->message e)))])
        (cond
          [broken? (if on-broken (cons 'ok (on-broken value)) (cons 'broken value))]
          [else (if on-fulfilled (cons 'ok (on-fulfilled value)) (cons 'ok value))])))
    (when on-finally (on-finally))
    (when chained
      (if (eq? (car outcome) 'ok)
          (settle-local v (local-vow-id chained) (cdr outcome) #f)
          (settle-local v (local-vow-id chained) (cdr outcome) #t))))
  (cond
    [(local-vow? a-vow) (hash-set! (vat-listeners v) (local-vow-id a-vow) listener)]
    [else ((far-ops-on (vat-far-ops 'on v)) a-vow listener)])
  ;; Match Goblins: `on` is a statement unless the caller asked to chain.
  (if promise? chained (void)))

(define (exn->message e) (if (exn? e) (exn-message e) (format "~a" e)))

;; The predicate for the `with-handlers` clauses that turn a raised value into a
;; broken vow. It catches an actor's arbitrary `raise`d value (Goblins semantics)
;; and every `exn:fail`, but lets `exn:break?` propagate: a `break-thread` — the
;; standard Racket cancellation and timeout mechanism — aimed at a thread pumping
;; a blocking `session-send`/`session-await`/`session-fetch` loop must terminate that thread,
;; not be absorbed into a broken vow and swallowed. Every convert-to-broken handler
;; uses this rather than a bare `(lambda (_) #t)` so the loops stay interruptible.
(define (converts-to-broken? e) (not (exn:break? e)))

;; Fire a local vow's listener, if one is registered, and drop it (one-shot).
(define (settle-local v id value broken?)
  (define listener (hash-ref (vat-listeners v) id #f))
  (when listener
    (hash-remove! (vat-listeners v) id)
    (listener value broken?)))

;; ── drive: run queued local turns to quiescence ───────────────────────────────
;; Each queued eventual-send runs its actor's turn; the vow settles with the
;; value (or, on a raised exception, a break carrying the message) and its
;; listener fires. Turns a turn queues run in the same drive (FIFO).
(define (drive v)
  (let loop ()
    (define pending (reverse (unbox (vat-queue v))))
    (unless (null? pending)
      (set-box! (vat-queue v) '())
      (for ([entry (in-list pending)])
        (match-define (queued-send ref method args vow-id) entry)
        (define-values (value broken?)
          (with-handlers ([converts-to-broken? (lambda (e) (values (exn->message e) #t))])
            (values (run-turn ref method args) #f)))
        (if broken?
            (settle-local v vow-id value #t)
            ;; A plain value settles now; a `forward` (a caretaker/attenuator)
            ;; tail-resolves the vow from the forwarded send, deferring it for a
            ;; far target, which the awaiting `session-send` loop pumps to settle
            ;; (ADR-0064).
            (resolve-behavior v value
                              (lambda (reply) (settle-local v vow-id reply #f))
                              (lambda (message) (settle-local v vow-id message #t)))))
      (loop))))

;; Settle an answer from a behavior's result. A plain value fulfills it; a
;; `forward` tail-resolves it from the forwarded send, a local target near-calls
;; (chasing the chain, so caretaker-over-attenuator composes, bounded by the
;; hop cap so a proxy cycle breaks the answer instead of spinning), a far
;; target eventual-sends and defers the settle onto the reply. The local-drive
;; spelling of the one forwarding contract; the hosted-actor trampoline holds
;; the same contract through the host's own turn verbs (ADR-0064's
;; `Turn.forward`).
(define (resolve-behavior v value on-fulfill on-break)
  (define result
    (chase-local-actor-forwards
     value
     (lambda (target method args)
       (with-handlers ([converts-to-broken?
                        (lambda (e) (hop-broke (exn->message e)))])
         (run-turn target method args)))))
  (cond
    [(hop-broke? result) (on-break (hop-broke-message result))]
    [(forward-cycle? result) (on-break FORWARD-CYCLE-MESSAGE)]
    [(forward? result)
     (define target (forward-target result))
     (define method (forward-method result))
     (define args (forward-args result))
     (with-vat v
       (on (apply <- target method args) on-fulfill #:catch on-break))]
    [else (on-fulfill result)]))

;; ── bind-export! : the export → local-actor record ────────────────────────────
;; Binding-internal. `(bind-export! v actor export-id)` records that
;; `export-id` names `actor` in this vat, so a near reference at that position
;; resolves to its own actor in process (`vat-resolve-target`). The wire half —
;; allocating the position and hosting the behavior for partner delivers — is
;; the session's (`session-spawn` / `session-publish` bind through here after
;; registering with the host).
(define (bind-export! v actor export-id)
  (unless (actor-ref? actor) (error 'bind-export! "can only bind a local actor reference"))
  (hash-set! (vat-exports v) export-id (actor-ref-id actor)))

;; Map a Host reference to a vat target, routing an export this vat
;; hosts to its local `actor-ref` so a self-spawned capability resolves
;; in-process rather than going out on the wire to its own export — the same
;; self-routing the sibling bindings perform through their hosted tables
;; (Rust's `SessionShared::hosted_cell` chase, Python's trampoline
;; `resolve_local`). A reference this vat does not host comes back unchanged.
(define (vat-resolve-target v target)
  (define actor-id
    (and (ref? target) (hash-ref (vat-exports v) (ref-id target) #f)))
  (if actor-id (actor-ref v actor-id) target))

;; ── break-far-vows! : settle every outstanding far vow as broken ──────────────
;; A far vow settles only when the partner's resolve arrives over the wire, so
;; once the connection is gone those resolves can never come. A serve loop calls
;; this on disconnect (the connection's own pump already does), so an `on`
;; form's `#:catch` handler runs instead of a vow waiting forever. Local vows
;; are untouched: they settle in `drive` and never wait on the wire. A
;; pure-local vat has no far vows, so this is a no-op there.
(define (break-far-vows! v message)
  (define ops (unbox (vat-far v)))
  (when ops ((far-ops-break ops) message)))
