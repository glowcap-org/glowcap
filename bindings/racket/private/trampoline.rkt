#lang racket/base
;; Internal: the bridge between the vat's local actors and the byte-fed host's
;; wire hosting — one actor, two doors. An actor spawned through a session
;; lives in the Racket vat as a closure cell; this module builds the
;; `PancakeHostBehavior` trampoline the host invokes on each wire deliver, hosts
;; spawn/publish mint (`register-hosted-actor!`), and owns the ADR-0064 proxy
;; behavior constructors. The trampoline reads the actor's CURRENT closure out
;; of its cell per call (via `run-turn`), never capturing it, so `bcom` and
;; `vat-restore!` retarget wire delivers with zero host verbs — the time-travel
;; contract.
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
         racket/lazy-require
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "value.rkt"
         "abi-value.rkt"
         "vat.rkt")

;; Session + pump for the local-send await path (session eagerly requires this
;; module; lazy-require breaks the cycle).
(lazy-require
 ["session/state.rkt" (session-vat session-host session-ptr)]
 ["host/state.rkt" (host-record-callerless-failure!)]
 ["pump.rkt" (pump-until current-deliver-session)]
 ["host/state.rkt" (host-retain! host-retire! call-with-host host-session-for-ptr)]
 ["promise.rkt" (await-vow session-far-send)]
 ["gc.rkt" (track-arguments!)])

(provide (all-defined-out))

;; The turn context while a hosted actor's trampoline runs: a pair of the
;; opaque `PancakeHostTurn*` and the session the turn arrived on, or #f
;; outside any turn. `session-spawn`/`session-caretaker` read it to pick the
;; turn-time spawn (`pancake_host_turn_spawn`) over the top-level one, which
;; the host refuses inside a callback; the pump reads it to defer action
;; drains to the enclosing verb's unwind.
(define current-turn (make-parameter #f))

;; The current turn pointer when it belongs to a Port on `c`'s Host, else #f.
;; A hosted actor may outlive the Port it was first projected through, and a
;; turn-time spawn needs only the Host-owned turn, not that old Port handle.
(define (current-turn-for c)
  (define t (current-turn))
  (and t
       (cdr t)
       c
       (eq? (session-host (cdr t)) (session-host c))
       (car t)))

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
;; local chase is bounded by the hop cap — a caretaker forwarding to itself
;; would spin this loop forever — so hop 257 breaks the answer with the cycle
;; message instead.
(define (settle-turn-reply c v turn result out-reply)
  (define chased
    (chase-local-actor-forwards
     result
     (lambda (target method args) (run-turn target method args))
     ;; Wire path: map near-export positions to local actor-refs before the
     ;; actor-ref? hop test. Giftable trampolines have no vat — identity.
     #:resolve-target (lambda (t) (if v (vat-resolve-target v t) t))))
  (cond
    [(forward-cycle? chased) (turn-break! turn FORWARD-CYCLE-MESSAGE)]
    [(forward? chased)
     (define target (forward-target chased))
     (cond
       [(ref? target)
        (define mb (string->bytes/utf-8 (symbol->string (forward-method chased))))
        (define keep (box '()))
        (define-values (aptr acnt) (args->c (forward-args chased) keep))
        ;; The host writes a placeholder reply and lets the real answer ride
        ;; the forwarded send's vow; buffers stay pinned until it returns.
        (define rc (pancake_host_turn_forward turn (ref->c target)
                                              (pin-immobile mb) (bytes-length mb)
                                              aptr acnt out-reply))
        (if (= rc OK) OK (turn-break! turn (or (host-last-error) "forward refused")))]
       [else (turn-break! turn "forward target is not callable")])]
    [else (write-reply! chased out-reply)]))

;; The shared trampoline body: decode the deliver, run the actor under the turn
;; context, and settle the reply. Only the behavior call is application policy:
;; its raises (an attenuator's "Attenuated", a revoked caretaker's "Revoked",
;; an unknown-method error) cross the boundary as a broken answer. Decode,
;; routing, reply encoding, and native settlement failures remain binding/wire
;; failures and unwind into the Session owner instead of being mislabeled as a
;; partner-visible behavior result.
(define (serve-foreign-call v turn verb-ptr verb-len args-ptr args-len out-reply run)
  (define method (decode-verb verb-ptr verb-len))
  (define args (args<-c args-ptr args-len))
  ;; A native callback can only run synchronously inside the pump's feed
  ;; bracket. The arriving Session supplies routing; never retain the Port
  ;; that happened to create this Host-owned actor.
  (define carrier (current-deliver-session))
  (unless carrier (error "hosted callback ran outside a session feed"))
  ;; A native loop brackets the step with a synthetic Host carrier because a
  ;; callback can arrive on an internal redeemed session that has no public
  ;; wrapper. When a wrapper does exist, the turn itself is the authoritative
  ;; route to it; per-session policy (GC opt-in, current-session) must never be
  ;; inferred from the carrier.
  (define-values (session-rc session-ptr*) (pancake_host_turn_session turn))
  (check/host session-rc)
  (define arriving
    (or (host-session-for-ptr (session-host carrier) session-ptr*) carrier))
  (track-arguments! arriving args)
  (define outcome
    (with-handlers ([converts-to-broken? (lambda (error) (cons 'broken error))])
      (cons 'ok
            (parameterize ([current-turn (cons turn arriving)])
              (run method args)))))
  (case (car outcome)
    [(broken) (turn-break! turn (exn->message (cdr outcome)))]
    [else (settle-turn-reply arriving v turn (cdr outcome) out-reply)]))

;; The PancakeHostBehavior for a vat actor: each wire
;; deliver runs the actor's current cell through `run-turn` (so `bcom` and
;; time-travel apply) with the vat current, exactly as a local `$` would.
(define (make-actor-trampoline v actor-id)
  (lambda (_ctx turn verb-ptr verb-len args-ptr args-len out-reply)
    (serve-foreign-call v turn verb-ptr verb-len args-ptr args-len out-reply
                        (lambda (method args)
                          (run-turn (actor-ref v actor-id) method args)))))

;; The PancakeHostBehavior for a host-wide giftable (`host-publish-giftable`):
;; one behavior closure hosted once under a Host-wide alias. It is bound to no
;; Racket vat; the core Host Vat projects it onto sessions as needed. The
;; behavior lives in a cell here so a `bcom` return still swaps it; a `forward`
;; return reaches only far targets (there is no Racket vat to resolve a local
;; one against).
(define (make-giftable-trampoline behavior)
  (define cell (box behavior))
  (lambda (_ctx turn verb-ptr verb-len args-ptr args-len out-reply)
    (serve-foreign-call #f turn verb-ptr verb-len args-ptr args-len out-reply
                        (lambda (method args)
                          (define result (apply (unbox cell) method args))
                          (cond
                            [(become? result)
                             (set-box! cell (become-behavior result))
                             (become-result result)]
                            [else result])))))

;; Spawn a hosted object at a fresh Host identity from INSIDE a turn — the
;; turn-time form the host allows where the top-level spawn is latched. Returns
;; opaque capability.
(define (turn-spawn-ref! turn trampoline)
  (define-values (rc capability) (pancake_host_turn_spawn turn trampoline #f #f))
  (check/host rc)
  capability)

;; Observe a local vow to settlement and classify: register the listener, run
;; the turn in `drive`, and — when a proxy forwarding to a far target deferred
;; the settle onto a wire reply — pump until it lands. Returns the fulfilled
;; value; a broken vow raises the typed ERR-BROKEN. The one awaiting loop under
;; `session-send`'s local arm and `session-await`'s.
(define (await-local-vow c vow who label)
  (define v (session-vat c))
  (define result (box 'pending))
  (with-vat v
    (on vow
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (drive v)
  (unless (pair? (unbox result))
    (pump-until c (lambda () (pair? (unbox result))) who
                #:closed-message (format "connection closed before ~a settled" label)))
  (define r (unbox result))
  (if (eq? (car r) 'broken)
      (raise-pancake who ERR-BROKEN "~a broke: ~a" label (cdr r))
      (cdr r)))

;; The awaiting loop for a send whose target resolved to a local actor: the
;; turn runs in `drive`; a proxy forwarding to a far target defers the settle
;; onto the reply, which the pump reads off the wire.
(define (session-send-local c resolved verb args)
  (define vow (with-vat (session-vat c) (apply <- resolved verb args)))
  (await-local-vow c vow 'session-send verb))

;; Near-hosted vs far send dispatch (blocking): resolve the target, then local
;; `session-send-local` or far mint + `await-vow`. Session keeps guard/drain.
;; Far mint flushes inside `session-far-send`; `await-vow` flushes again before
;; parking so a cross-thread deliver cannot sit unsent.
(define (dispatch-send c target verb args)
  (define resolved (vat-resolve-target (session-vat c) target))
  (cond
    [(actor-ref? resolved) (session-send-local c resolved verb args)]
    [else (await-vow c (session-far-send c resolved verb args #t) 'session-send verb)]))

;; Near-hosted vs far send-promise dispatch: local runs `<-` + `drive` and
;; returns the vow; far mints through `session-far-send` (which flushes).
(define (dispatch-send-promise c target verb args)
  (define v (session-vat c))
  (define resolved (vat-resolve-target v target))
  (cond
    [(actor-ref? resolved)
     (define vow (with-vat v (apply <- resolved verb args)))
     ;; A local target runs its turn now; a far/pipelined target leaves on the
     ;; settling `session-send`'s pump, so the whole chain travels as one batch.
     (drive v)
     vow]
    [else (session-far-send c resolved verb args #t)]))

;; Near-hosted vs far tell dispatch: local `<-np` + `drive`; far mint (flushes).
(define (dispatch-tell c target verb args)
  (define v (session-vat c))
  (define resolved (vat-resolve-target v target))
  (cond
    [(actor-ref? resolved)
     (with-vat
      v
      (define vow (apply <- resolved verb args))
      (on vow #:catch
          (lambda (message)
            (host-record-callerless-failure!
             (session-host c) "tell.behavior"
             (exn:fail message (current-continuation-marks))))))
     (drive v)]
    [else (session-far-send c resolved verb args #f)]))

;; ADR-0064 caretaker actor constructor: forwards to `target` while `live` is
;; true, else breaks with "Revoked". Session registers the spawn and tracks
;; the live box for `session-revoke!`.
(define (caretaker-behavior live target)
  (lambda (bcom)
    (lambda (method . args)
      (if (unbox live)
          (forward target method args)
          (error "Revoked")))))

;; ADR-0064 attenuator actor constructor: forwards only allow-listed verbs
;; (strings), else breaks with "Attenuated".
(define (attenuate-behavior allow target)
  (lambda (bcom)
    (lambda (method . args)
      (if (member (symbol->string method) allow)
          (forward target method args)
          (error "Attenuated")))))

;; Host `actor` on session `c`: build the trampoline that runs the actor's
;; current cell on each wire deliver, bind it at a fresh Host identity —
;; through the turn-time spawn when called from inside a hosted turn (a served
;; factory minting the capability it replies with), through the top-level
;; publish/spawn otherwise — and record the identity in the vat so the opaque
;; reference resolves in process. Returns the capability. Session's
;; `session-spawn` / `session-publish` / proxy factories wrap this.
(define (register-hosted-actor! c actor #:name [name #f])
  (define v (session-vat c))
  (define m (session-host c))
  (define tramp (make-actor-trampoline v (actor-ref-id actor)))
  (host-retain! m tramp)
  (define turn (and (not name) (current-turn-for c)))
  ;; The host never owns the row (the free callback is #f), so a refused mint
  ;; must retire the retained closure or it leaks for the host's life.
  (define capability
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (host-retire! m tramp) (raise e))])
      (cond
        [turn (turn-spawn-ref! turn tramp)]
        [else
         (call-with-host m
           (lambda ()
             (cond
               [name
                (define nb (string->bytes/utf-8 name))
                (define-values (rc p)
                  (pancake_host_session_publish (session-ptr c) (pin-immobile nb) (bytes-length nb)
                                             tramp #f #f))
                (check/host rc)
                p]
               [else
                (define-values (rc p) (pancake_host_session_spawn (session-ptr c) tramp #f #f))
                (check/host rc)
                p])))])))
  (define id (PancakeReference-id capability))
  (bind-export! v actor id)
  (make-ref/internal id))

;; ADR-0064 caretaker factory: resolve `target`, spawn a forwarding actor, host
;; it, and record the live box for `revoke-caretaker!`. Session's
;; `session-caretaker` is the thin public wrapper.
(define (caretaker-proxy c target)
  (define v (session-vat c))
  (define resolved (vat-resolve-target v target))
  (define live (box #t))
  ;; An ordinary spawned actor whose behavior tail-forwards to the target — so
  ;; the proxy answers a local call exactly as a partner's delivery does.
  (define actor
    (with-vat v
      (spawn (caretaker-behavior live resolved))))
  (define proxy (register-hosted-actor! c actor))
  (hash-set! (vat-revocables v) (ref-id proxy) live)
  proxy)

;; ADR-0064 attenuator factory: resolve `target`, spawn a verb-filtered
;; forwarding actor, and host it. Session's `session-attenuate` wraps this.
(define (attenuate-proxy c target verbs)
  (define v (session-vat c))
  (define resolved (vat-resolve-target v target))
  (define allow (map (lambda (verb) (if (symbol? verb) (symbol->string verb) verb)) verbs))
  (define actor
    (with-vat v
      (spawn (attenuate-behavior allow resolved))))
  (register-hosted-actor! c actor))

;; Sever a caretaker `proxy` from `caretaker-proxy` / `session-caretaker`:
;; clear the live flag and drop the revocables row. Idempotent.
(define (revoke-caretaker! c proxy)
  (unless (ref? proxy)
    (raise-pancake 'session-revoke! ERR-INVALID-ARGUMENT
                   "revoke target is not a caretaker proxy: ~a" proxy))
  (define revocables (vat-revocables (session-vat c)))
  (define live (hash-ref revocables (ref-id proxy) #f))
  (when live
    (set-box! live #f)
    (hash-remove! revocables (ref-id proxy))))
