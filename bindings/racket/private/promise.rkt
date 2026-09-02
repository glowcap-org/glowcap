#lang racket/base
;; Internal: far-vow handle + pipelined projection (ADR-0007 / ADR-0050 /
;; ADR-0052). Also the shared await/fetch classify path (`await-vow` /
;; `blocking-fetch`), the far-send/tell mint (`session-far-send`), and the
;; listen mint (`listen-far`). Session owns CapTP verb wrappers and
;; `session-await`; this module owns the `session-vow` type, the host vow table register/settle/listen path,
;; `session-index`/`session-untag`/`session-get`, far-send mint, and the
;; post-mint wait/classify.

(require ffi/unsafe
         racket/lazy-require
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "host/state.rkt"
         "finalizer-diagnostics.rkt"
         "value.rkt"
         "abi-value.rkt"
         "session/state.rkt")

;; Session state owns `session-host` / guard; pump owns the read path. The lazy
;; imports break the session ↔ promise and promise ↔ pump cycles (session
;; eagerly requires this module; pump lazy-requires session).
(lazy-require
 ["session.rkt" (session-flush!)]
 ["pump.rkt" (pump-until with-host-drain)]
["gc.rkt" (session-gc-enabled? track-argument! track-vow! park-vow-release!)]
 ["action.rkt" (drain-host-actions!)])

(provide (struct-out session-vow)
         listen-far
         adopt-minted-vow!
         settle-vow!
         session-vow-listen!
         session-index
         session-untag
         session-get
         project-vow
         await-vow
         release-vow!
         release-vow-from-host!
         blocking-fetch
         session-far-send)

;; A far vow is the binding's handle on one host vow: the home
;; session, the settled state, and the Racket listeners waiting on it. The
;; vow is registered weakly in the host's vow table the instant it is minted,
;; under the same host lock as the minting FFI call. A listener promotes that
;; row to strong ownership; otherwise dropping the public handle can release a
;; still-pending native answer. The action drain's SETTLE/FAIL arms record the
;; outcome here, and no settle callback crosses the C boundary.
(struct session-vow (session id [state #:mutable] [listeners #:mutable] track-gc? pipeline-target?
                             [release-armed #:mutable]) #:transparent)

;; Register a freshly minted vow so the drain can route its completion.
;; Caller holds the host lock, so no drain can pop the completion first.
(define (register-vow! m v)
  (hash-set! (host-vows m) (session-vow-id v) (make-weak-box v))
  (track-vow! m v (session-vow-id v) (session-vow-release-armed v)))

;; Run the binding-side adoption that follows one successful native mint. A
;; refusal cannot leave the native row ownerless: the cleanup arm removes any
;; partial observation row and parks release on the Host owner thread.
(define (with-minted-vow-guard adopt abandon)
  (with-handlers ([(lambda (_) #t)
                   (lambda (failure)
                     (with-handlers ([(lambda (_) #t)
                                      (lambda (cleanup)
                                        (record-runtime-failure!
                                         'binding "vow.adoption.release" cleanup))])
                       (abandon))
                     (raise failure))])
    (adopt)))

(define (adopt-minted-vow! m c id track-gc? pipeline-target?)
  (define armed (box #t))
  (define v (session-vow c id 'pending '() track-gc? pipeline-target? armed))
  (with-minted-vow-guard
   (lambda ()
     (register-vow! m v)
     v)
   (lambda ()
     (hash-remove! (host-vows m) id)
     (park-vow-release! m id armed))))

(define (release-vow! v)
  (define c (session-vow-session v))
  (when c
    (release-vow-from-host! (session-host c) v)))

(define (release-vow-from-host! m v)
  (define armed (session-vow-release-armed v))
  (when (and armed (box-cas! armed #t #f))
    (with-handlers ([(lambda (_) #t)
                     (lambda (failure)
                       (set-box! armed #t)
                       (raise failure))])
      (with-host-drain
       m
       (lambda ()
         (check/host (glowcap_host_vow_release
                      (host-ptr m) (session-vow-id v)))
         (hash-remove! (host-vows m) (session-vow-id v))
         (drain-host-actions! m))))))

(define (vow-entry-value entry)
  (cond
    [(session-vow? entry) entry]
    [(weak-box? entry) (weak-box-value entry)]
    [else #f]))

;; The drain's settle arm: record the outcome, drop the table row (a vow
;; settles once), and hand back the parked listeners as fire thunks — a
;; listener is arbitrary application code (the vat's `on`), so it must run
;; after the host lock releases, never under it, or a listener that pumps
;; could park the whole node. State mutation stays under the lock, so a
;; blocking `session-await`'s state poll never races the fire. An unregistered
;; id yields nothing — an outcome nobody awaits.
(define (settle-vow! m id outcome)
  (define boxed (hash-ref (host-vows m) id #f))
  (define v (vow-entry-value boxed))
  (cond
    [v
     (hash-remove! (host-vows m) id)
     (define tracked
       (if (and (eq? (car outcome) 'ok)
                (session-vow-track-gc? v)
                (session-vow-session v))
           (cons 'ok (track-argument! (session-vow-session v) (cdr outcome)))
           outcome))
     (set-session-vow-state! v tracked)
     (define ls (session-vow-listeners v))
     (set-session-vow-listeners! v '())
     (for/list ([l (in-list (reverse ls))])
       (lambda () (l (cdr tracked) (not (eq? (car tracked) 'ok)))))]
    [else
     (hash-remove! (host-vows m) id)
     '()]))

;; Register `(listener value broken?)` on a far vow: fire now from the recorded
;; state when it already settled, else park it for the drain's settle arm. The
;; vat's `on` reaches far vows through this (via the installed far half).
(define (session-vow-listen! a-vow listener)
  (unless (session-vow? a-vow) (error 'on "not a vow: ~a" a-vow))
  (define m (session-host (session-vow-session a-vow)))
  (define settled
    (call-with-host m
      (lambda ()
        (define s (session-vow-state a-vow))
        (cond
          [(eq? s 'pending)
           ;; The registered listener is itself live interest in the outcome.
           ;; Keep the vow strongly reachable until settlement even if its
           ;; caller drops the original handle.
           (hash-set! (host-vows m) (session-vow-id a-vow) a-vow)
           (set-session-vow-listeners!
            a-vow
            (cons listener (session-vow-listeners a-vow)))
           #f]
          [else s]))))
  ;; Application code never runs under the Host lock.
  (when settled
    (listener (cdr settled) (not (eq? (car settled) 'ok)))))

;; ── Pipelined projections (ADR-0050) ─────────────────────────────────────────
;; Project an element, unwrapped tag, or Struct field out of a far vow WITHOUT
;; waiting for it to settle, returning a new vow for the projected value. The
;; projection rides the wire as `op:index` / `op:untag` / `op:get` against the
;; receiver's answer (ADR-0050/ADR-0052), so it pipelines exactly like a dependent call:
;; `(session-untag c vow "row")` then `(session-index c that 0)` reaches the first
;; element of an unwrapped tagged record in one batch, before the source resolves.
;; The returned vow is itself a projection or `session-send` target, and settles via
;; `session-await`. Each mint flushes before returning; awaiting observes the
;; result and does not decide whether the operation leaves the process.
(define (session-index c a-vow i)
  (project-vow (session-host c) a-vow
               (lambda (m id) (glowcap_host_vow_index (host-ptr m) id i))))

(define (session-untag c a-vow tag)
  (define tb (string->bytes/utf-8 tag))
  (project-vow (session-host c) a-vow
               (lambda (m id)
                 (glowcap_host_vow_untag (host-ptr m) id (pin-immobile tb) (bytes-length tb)))))

(define (session-get c a-vow field)
  (define fb (string->bytes/utf-8 field))
  (project-vow (session-host c) a-vow
               (lambda (m id)
                 (glowcap_host_vow_get (host-ptr m) id (pin-immobile fb) (bytes-length fb)))))

(define (project-vow m a-vow mint)
  (unless (session-vow? a-vow)
    (raise-glowcap 'session-project ERR-INVALID-ARGUMENT
                   "projection target is not a far vow: ~a" a-vow))
  (unless (session-vow-pipeline-target? a-vow)
    (raise-glowcap 'session-project ERR-INVALID-ARGUMENT
                   "this vow is await-only and cannot be projected"))
  (define home (session-vow-session a-vow))
  (unless (and home (eq? (session-host home) m))
    (raise-glowcap 'session-project ERR-INVALID-ARGUMENT
                   "this vow belongs to another Host"))
  (define projected
    (call-with-host m
      (lambda ()
        (define-values (rc id) (mint m (session-vow-id a-vow)))
        (check/host rc)
        (adopt-minted-vow! m home id (session-gc-enabled? home) #t))))
  (session-flush! home)
  projected)

;; Publish every registered far operation through the same post-mint progress
;; transition. Inside a behavior turn the Session parks the flush for unwind;
;; outside a turn this puts the operation on its byte channel now.
(define (flush-minted-operation! c result)
  (session-flush! c)
  result)

;; Pump until the far vow settles and classify: the fulfilled value, a typed
;; ERR-BROKEN carrying the partner's break, or a typed ERR-CLOSED when the
;; settle was the disconnect's own break. Flush before parking so a deliver
;; minted on another thread (or ahead of this await) cannot sit unsent while
;; both peers wait on the socket.
(define (await-vow c v who label)
  (session-flush! c)
  (pump-until c
              (lambda () (and (not (eq? (session-vow-state v) 'pending)) (session-vow-state v)))
              who
              #:closed-message (format "connection closed before ~a settled" label))
  (define r (session-vow-state v))
  (case (car r)
    [(ok) (cdr r)]
    [(failed) (raise (cdr r))]
    [(closed) (raise-glowcap who ERR-CLOSED "connection closed before ~a settled" label)]
    [else (raise-glowcap who ERR-BROKEN "~a broke: ~a" label (cdr r))]))

;; The one blocking fetch shape `session-fetch` and `session-enliven` share:
;; `mint!` runs the registering FFI verb (the one thing that differs) and
;; returns the minted vow id, the vow joins the host's table before the lock
;; drops, and the pump drains its SETTLE/FAIL completion off the action queue.
;; Classify: only a live Host reference fulfills; a partner break raises
;; typed ERR-BROKEN; the disconnect's own break raises typed ERR-CLOSED.
(define (blocking-fetch c who what label mint! #:track-gc? [track-gc? #f])
  (define m (session-host c))
  (define v
    (call-with-host m
      (lambda ()
        (define-values (rc id) (mint!))
        (check/host rc)
        (adopt-minted-vow!
         m c id (and track-gc? (session-gc-enabled? c)) #f))))
  (dynamic-wind
    void
    (lambda ()
      ;; Fetch/enliven mint outside `session-far-send`; flush before the await.
      (session-flush! c)
      (pump-until c
                  (lambda () (and (not (eq? (session-vow-state v) 'pending)) (session-vow-state v)))
                  who
                  #:closed-message (format "connection closed before \"~a\" settled" label))
      (define r (session-vow-state v))
      (case (car r)
        [(ok)
         (define val (cdr r))
         (unless (ref? val)
           (raise-glowcap who ERR-UNSUPPORTED-VALUE
                          "~a \"~a\" did not resolve to a capability: ~a" what label val))
         val]
        [(failed) (raise (cdr r))]
        [(closed)
         (raise-glowcap who ERR-CLOSED "connection closed before \"~a\" settled" label)]
        [else
         (raise-glowcap who ERR-BROKEN "~a \"~a\" broke: ~a" what label (cdr r))]))
    (lambda () (release-vow! v))))

;; Far-send / far-tell mint: encode args, call `glowcap_host_session_send` /
;; `glowcap_host_vow_send` / `glowcap_host_session_tell`, and register any answer
;; vow. Local-hosted targets stay in Session
;; (`session-send-local`). Outside a turn, flush after every mint so an
;; unobserved eventual-send still makes progress; the native Host keeps the
;; answer target addressable through fast settlement until the public vow is
;; released. Inside a turn `session-flush!` defers to the host unwind.
;; An empty verb symbol is a methodless positional deliver (verb length zero on
;; the wire). `answer?` #t returns the minted `session-vow`; #f is tell
;; (Goblins `<-np`). Promise-pipelined targets ride `vow_send`.
;; `session-listen`'s wire half: mint the listen vow over a held far reference
;; (CapTP op:listen) and hand back the vow. The session API owns
;; profile-specific target legality. The vow is plain — a listen may settle to
;; any value, not only a capability.
(define (listen-far c target)
  (define m (session-host c))
  (define result
    (call-with-host m
      (lambda ()
        (define-values (rc id)
          (glowcap_host_session_listen (session-ptr c) (ref->c target)))
        (check/host rc)
        (adopt-minted-vow! m c id (session-gc-enabled? c) #f))))
  (flush-minted-operation! c result))

(define (session-far-send c target verb args answer?)
  (guard-open 'session-send c)
  (define m (session-host c))
  (define vb (string->bytes/utf-8 (symbol->string verb)))
  (define vbuf (pin-immobile vb))
  (define vlen (bytes-length vb))
  (define result
    (call-with-host m
      (lambda ()
        (define keep (box '()))
        (define-values (aptr acnt) (args->c args keep))
        ;; The FFI retains its own arguments for the call, but the string and
        ;; item buffers inside `aptr` are reachable only through `keep`, whose
        ;; raw addresses the collector cannot see. The sink below keeps them
        ;; live past every mint in this dispatch.
        (define minted
          (cond
          [(session-vow? target)
           (unless (session-vow-pipeline-target? target)
             (raise-glowcap 'session-send ERR-INVALID-ARGUMENT
                            "this vow is await-only and has no remote pipeline target"))
           (define home (session-vow-session target))
           (unless (and home (eq? (session-host home) m))
             (raise-glowcap 'session-send ERR-INVALID-ARGUMENT
                            "this vow belongs to another Host"))
           (if answer?
               (let-values ([(rc id)
                             (glowcap_host_vow_send
                              (host-ptr m) (session-vow-id target) vbuf vlen aptr acnt)])
                 (check/host rc)
                 (adopt-minted-vow! m home id (session-gc-enabled? home) #t))
               (begin
                 (check/host
                  (glowcap_host_vow_tell
                   (host-ptr m) (session-vow-id target) vbuf vlen aptr acnt))
                 (void)))]
          [(ref? target)
           (cond
             [answer?
              (define-values (rc id)
                (glowcap_host_session_send (session-ptr c) (ref->c target) vbuf vlen aptr acnt))
              (check/host rc)
              (adopt-minted-vow! m c id (session-gc-enabled? c) #t)]
             [else
              (check/host (glowcap_host_session_tell (session-ptr c) (ref->c target) vbuf vlen aptr acnt))
              (void)])]
          [else
           (raise-glowcap 'session-send ERR-INVALID-ARGUMENT "not a sendable reference: ~a" target)]))
        (void/reference-sink keep)
        minted)))
  (flush-minted-operation! c result))

(module+ test
  (require rackunit)
  (define failure (exn:fail "adoption failed" (current-continuation-marks)))
  (define abandoned 0)
  (check-exn
   (lambda (raised) (eq? raised failure))
   (lambda ()
     (with-minted-vow-guard
      (lambda () (raise failure))
      (lambda () (set! abandoned (add1 abandoned))))))
  (check-equal? abandoned 1))
