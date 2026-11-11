#lang racket/base
;; Internal: Host actors with no session. `host-spawn` hosts a behavior at a
;; fresh Host identity, and `host-send-promise` / `host-tell` queue a call or a
;; notification at the target's actual home. Each verb inside a behavior of
;; the same Host joins that turn (`glowcap_host_turn_spawn`,
;; `glowcap_host_turn_send`, `glowcap_host_turn_tell`), which commits its
;; effects when the behavior returns. Outside a turn, the verb drains the
;; Host's queue so the delivered turns run before it returns.
;;
;; Each verb takes a `target` that is a reference this Host holds, local or
;; far. A session vow is not a target here: pipeline through `session-send`.
;; A refused verb raises `exn:fail:glowcap` and queues nothing.

(require ffi/unsafe
         ffi/unsafe/atomic
         "../constants.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../abi-value.rkt"
         "../trampoline.rkt"
         "../promise.rkt"
         "../gc.rkt"
         "../pump.rkt"
         "../action.rkt"
         "state.rkt")

(provide host-spawn host-send host-send-promise host-tell host-await)

;; ── Host-spawned behavior ownership ──────────────────────────────────────────
;; A Host-spawned actor passes its ctx id and the shared free callback, so the
;; library hands the trampoline back when the actor is collected, when an
;; admitted spawn fails, or at Host release. The callback runs synchronously on
;; the thread inside the FFI call and calls no glowcap_host_* function.
(define hosted-owners (make-hasheqv))
(define next-hosted-id 1)

(define (release-hosted-ctx! ctx)
  (define id (cast ctx _pointer _intptr))
  (define entry (hash-ref hosted-owners id #f))
  (when entry
    (hash-remove! hosted-owners id)
    (define m (weak-box-value (car entry)))
    (when m (host-retire! m (cdr entry)))))

;; Module lifetime: the library may call it for as long as any Host holds a
;; Host-spawned actor.
(define hosted-free (function-ptr release-hosted-ctx! (_fun _pointer -> _void)))

;; Retain `tramp` for Host `m` until the library frees `id`. Every Host's
;; spawning threads share the counter, so taking an id and claiming its row is
;; one atomic section: a shared id would let one actor's free retire another's
;; live trampoline.
(define (register-hosted! m tramp)
  (start-atomic)
  (define id next-hosted-id)
  (set! next-hosted-id (add1 id))
  (host-retain! m tramp)
  (hash-set! hosted-owners id (cons (make-weak-box m) tramp))
  (end-atomic)
  id)

;; Idempotent with the library's free, so a refused spawn may run it whether
;; or not the free ran.
(define (unregister-hosted! m id tramp)
  (hash-remove! hosted-owners id)
  (host-retire! m tramp))

;; The target of each Host vow, so `host-await` can pump the session that
;; homes a far target. Keyed weakly, so a dropped vow drops its row.
(define vow-targets (make-weak-hasheq))

;; The turn pointer when the current behavior belongs to Host `m`, else #f.
(define (host-turn m)
  (define t (current-turn))
  (and t (eq? (turn-context-host t) m) (turn-context-turn t)))

(define (verb-bytes verb)
  (if verb (string->bytes/utf-8 (symbol->string verb)) #""))

;; Host `behavior`, an ordinary `(lambda (method . args) ...)`, and return an
;; owned reference the collector releases when unreachable. The actor has no
;; alias and no wire export, and sending it over any session exports it there.
;; Once the reference and every exported copy are gone, the actor is collected
;; and the Host drops its behavior. A refused spawn raises and hosts nothing.
(define (host-spawn m behavior)
  (define tramp (make-publication-trampoline behavior))
  (define id (register-hosted! m tramp))
  (define ctx (cast id _intptr _pointer))
  (define turn (host-turn m))
  ;; The library frees an admitted registration on failure and leaves a null
  ;; or reentry refusal with us, so unregister on every refusal.
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (unregister-hosted! m id tramp) (raise e))])
    (call-with-host m
      (lambda ()
        (parameterize-break #f
          (define-values (rc capability)
            (if turn
                (glowcap_host_turn_spawn turn tramp ctx hosted-free)
                (glowcap_host_spawn (host-ptr m) tramp ctx hosted-free)))
          (check/host rc)
          (adopt-host-reference m (GlowcapReference-id capability)))))))

;; Run `mint` under the Host lock with the far arguments lowered. Outside a
;; turn the same lock scope drains the queue the mint fed.
(define (call-with-host-mint m args mint)
  (define (lowered)
    (define keep (box '()))
    (define result (call-with-far-args m args keep mint))
    ;; Buffers inside the argument block are reachable only through `keep`.
    (void/reference-sink keep)
    result)
  (if (host-turn m)
      (call-with-host m lowered)
      (with-host-drain m
        (lambda ()
          (define result (lowered))
          (values (drain-host-actions! m) result)))))

;; Queue `verb(args)` to `target` and return its vow without waiting. The
;; vow's capabilities are owned like a retain. `host-await` waits for it
;; outside a turn, `on` in a session's vat listens to it through this Host,
;; and a behavior that needs the answer awaits the vow after its turn returns
;; or defers its own turn. `host-await` releases the vow once it settles. A
;; vow that is never awaited is released by the collector when it becomes
;; unreachable, inside a turn or out, and dropping it does not cancel the send.
(define (host-send-promise m target verb . args)
  (define turn (host-turn m))
  (define vb (verb-bytes verb))
  (call-with-host-mint m args
    (lambda (aptr acnt)
      (define vbuf (and verb (pin-immobile vb)))
      (define-values (rc id)
        (if turn
            (glowcap_host_turn_send turn (ref->c target) vbuf (bytes-length vb) aptr acnt)
            (glowcap_host_send (host-ptr m) (ref->c target) vbuf (bytes-length vb) aptr acnt)))
      (check/host rc)
      (define v (adopt-minted-vow! m #f id 'owned #f))
      (hash-set! vow-targets v target)
      v)))

;; Queue `verb(args)` to `target` with no reply. Outside a turn the Host drain
;; runs a local target's turn before this returns. A far notification returns
;; once it is queued for its session's writer, where `session-tell` waits for
;; the frame to be written.
(define (host-tell m target verb . args)
  (define turn (host-turn m))
  (define vb (verb-bytes verb))
  (call-with-host-mint m args
    (lambda (aptr acnt)
      (define vbuf (and verb (pin-immobile vb)))
      (check/host
       (if turn
           (glowcap_host_turn_tell turn (ref->c target) vbuf (bytes-length vb) aptr acnt)
           (glowcap_host_tell (host-ptr m) (ref->c target) vbuf (bytes-length vb) aptr acnt)))
      (void))))

;; A behavior's turn holds the Host, so a wait inside it could never end.
(define (refuse-wait-in-turn m who)
  (when (host-turn m)
    (raise-glowcap who ERR-INVALID-ARGUMENT
                   "a behavior cannot wait inside its turn; defer the turn instead")))

;; Wait outside a turn for a vow from `host-send-promise`, returning its value.
;; A broken vow raises a typed ERR-BROKEN. A far target's answer arrives on the
;; session that homes it, so that session is pumped like any blocking session
;; verb, which also starts a loop-owned session's inbound. A local target's
;; answer settles in a Host drain. `current-pump-deadline` bounds both waits.
;; The vow is released afterwards.
(define (host-await m v)
  (refuse-wait-in-turn m 'host-await)
  (define label "the Host send")
  (define (settled)
    (define state (session-vow-state v))
    (and (not (eq? state 'pending)) state))
  (dynamic-wind
    void
    (lambda ()
      (define target (hash-ref vow-targets v #f))
      (define home (and target (not (settled)) (host-exporter-for m target)))
      (if home
          (await-vow home v 'host-await label)
          (settled-vow-value (host-wait-until m settled 'host-await) 'host-await label)))
    (lambda () (release-vow-from-host! m v))))

;; Send `verb(args)` to `target` and wait for the answer outside a turn. The
;; refusal inside a turn comes before the send is queued.
(define (host-send m target verb . args)
  (refuse-wait-in-turn m 'host-send)
  (host-await m (apply host-send-promise m target verb args)))
