#lang racket/base
;; Internal: the bridge between the vat's local actors and the byte-fed host's
;; wire hosting — one actor, two doors. An actor spawned through a connection
;; lives in the Racket vat as a closure cell; this module builds the
;; `PancakeHostBehavior` trampoline the host invokes on each wire deliver. The
;; trampoline reads the actor's CURRENT closure out of its cell per call (via
;; `run-turn`), never capturing it, so `bcom` and `vat-restore!` retarget wire
;; delivers with zero host verbs — the time-travel contract.
;;
;; Reply discipline: the host copies `out_reply`'s payload the instant the
;; trampoline returns, so the marshalled reply's buffers are retained in
;; `last-reply-keep` across the return (overwritten by the next reply — the
;; previous one has long been copied). A raised error crosses the boundary
;; through `pancake_host_turn_break`, which settles the answer broken with the
;; actor's own words — a bare non-OK return would flatten "Revoked" into a
;; generic reason. A `forward` return maps onto `pancake_host_turn_forward`
;; (the caretaker/attenuator primitive): a local target composes in Racket, a
;; far target defers the answer onto the forwarded send's vow.

(require ffi/unsafe
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "value.rkt"
         "codec.rkt"
         "vat.rkt")

(provide (all-defined-out))

;; The turn context while a hosted actor's trampoline runs: a pair of the
;; opaque `PancakeHostTurn*` and the connection the turn arrived on, or #f
;; outside any turn. `conn-spawn`/`conn-caretaker` read it to pick the
;; turn-time spawn (`pancake_host_turn_spawn`) over the top-level one, which
;; the host refuses inside a callback; the pump reads it to defer action
;; drains to the enclosing verb's unwind.
(define current-turn (make-parameter #f))

;; The current turn pointer when it belongs to connection `c`, else #f.
(define (current-turn-for c)
  (define t (current-turn))
  (and t (eq? (cdr t) c) (car t)))

;; Whether ANY hosted turn is running on this thread — the pump defers action
;; drains while one is (the host refuses the driving verbs inside a callback;
;; everything enqueued flushes when the enclosing call unwinds).
(define (inside-turn?) (and (current-turn) #t))

;; The most recent reply's marshalled argument and its pinned buffers, retained
;; across the trampoline's return so the host's immediate copy reads live
;; memory. One slot suffices: the host copies before any other Racket code can
;; run, so by the time this is overwritten the previous reply is long copied.
(define last-reply-keep (box #f))

;; Marshal `value` into the host's out-reply slot and return PANCAKE_OK.
(define (write-reply! value out-reply)
  (define keep (box '()))
  (define c-arg (arg->c value keep))
  (set-box! last-reply-keep (cons c-arg keep))
  (memcpy out-reply c-arg (ctype-sizeof _PancakeArgument))
  OK)

;; Break this turn's answer with the actor's own diagnostic and return the code
;; the trampoline should hand back (OK: the break already settled the answer).
(define (turn-break! turn msg)
  (define bs (string->bytes/utf-8 msg))
  (define rc (pancake_host_turn_break turn (pin-immobile bs) (bytes-length bs)))
  (if (= rc OK) OK rc))

;; An inbound deliver's wire verb as the Racket method symbol: a leading OCapN
;; symbol became the verb host-side, and a methodless positional deliver (a
;; bare `(cap args…)` call, verb length zero) dispatches as 'call — a Racket
;; symbol where the other bindings hand their handlers an empty verb string,
;; because a Racket behavior matches on symbols and '|| would be unwritable.
(define (decode-verb verb-ptr verb-len)
  (if (zero? verb-len)
      'call
      (string->symbol (bytes->string/utf-8 (bytes<-c verb-ptr verb-len) #\uFFFD))))

;; Resolve a trampoline result into the turn's answer: a plain value marshals
;; into the reply; a `forward` composes locally or defers through the host's
;; turn-forward; a raise (handled by the caller) breaks with the message. The
;; local chase is bounded by the vat's hop cap — a caretaker forwarding to
;; itself would spin this loop forever — so hop 257 breaks the answer with the
;; cycle message instead.
(define (settle-turn-reply c v turn result out-reply)
  (let chase ([result result] [hops 0])
    (cond
      [(forward? result)
       (define target (if v (vat-resolve-target v (forward-target result)) (forward-target result)))
       (cond
         [(actor-ref? target)
          ;; A local target near-calls now and the chase continues, so a
          ;; caretaker over an attenuator composes exactly as it does under `$`.
          (if (>= hops MAX-LOCAL-FORWARD-HOPS)
              (turn-break! turn FORWARD-CYCLE-MESSAGE)
              (chase (run-turn target (forward-method result) (forward-args result))
                     (add1 hops)))]
         [(or (far-ref? target) (near-ref? target))
          (define mb (string->bytes/utf-8 (symbol->string (forward-method result))))
          (define keep (box '()))
          (define-values (aptr acnt) (args->c (forward-args result) keep))
          ;; The host writes a placeholder reply and lets the real answer ride
          ;; the forwarded send's vow; buffers stay pinned until it returns.
          (define rc (pancake_host_turn_forward turn (ref->c target)
                                                (pin-immobile mb) (bytes-length mb)
                                                aptr acnt out-reply))
          (if (= rc OK) OK (turn-break! turn (or (host-last-error) "forward refused")))]
         [else (turn-break! turn "forward target is not callable")])]
      [else (write-reply! result out-reply)])))

;; The shared trampoline body: decode the deliver, run the actor under the turn
;; context, and settle the reply. Every raise (an attenuator's "Attenuated", a
;; revoked caretaker's "Revoked", an unknown-method error) crosses the boundary
;; as a break carrying the message.
(define (serve-foreign-call c v turn verb-ptr verb-len args-ptr args-len out-reply run)
  (with-handlers ([converts-to-broken? (lambda (e) (turn-break! turn (exn->message e)))])
    (define method (decode-verb verb-ptr verb-len))
    (define args (args<-c args-ptr args-len))
    (define result (parameterize ([current-turn (cons turn c)]) (run method args)))
    (settle-turn-reply c v turn result out-reply)))

;; The PancakeHostBehavior for a vat actor hosted on connection `c`: each wire
;; deliver runs the actor's current cell through `run-turn` (so `bcom` and
;; time-travel apply) with the vat current, exactly as a local `$` would.
(define (make-actor-trampoline c v actor-id)
  (lambda (_ctx turn verb-ptr verb-len args-ptr args-len out-reply)
    (serve-foreign-call c v turn verb-ptr verb-len args-ptr args-len out-reply
                        (lambda (method args)
                          (run-turn (actor-ref v actor-id) method args)))))

;; The PancakeHostBehavior for a node-wide giftable (`node-publish-giftable`):
;; one behavior closure published under one swissnum on every connection, so it
;; is bound to no single vat. The behavior lives in a cell here so a `bcom`
;; return still swaps it; a `forward` return reaches only far targets (there is
;; no vat to resolve a local one against).
(define (make-giftable-trampoline behavior)
  (define cell (box behavior))
  (lambda (_ctx turn verb-ptr verb-len args-ptr args-len out-reply)
    (serve-foreign-call #f #f turn verb-ptr verb-len args-ptr args-len out-reply
                        (lambda (method args)
                          (define result (apply (unbox cell) method args))
                          (cond
                            [(become? result)
                             (set-box! cell (become-behavior result))
                             (become-result result)]
                            [else result])))))

;; Spawn a hosted object at a fresh export position from INSIDE a turn — the
;; turn-time form the host allows where the top-level spawn is latched. Returns
;; the export position.
(define (turn-spawn-position! turn trampoline)
  (define-values (rc pos) (pancake_host_turn_spawn turn trampoline #f #f))
  (check/host rc)
  pos)
