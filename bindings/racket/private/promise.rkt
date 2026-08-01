#lang racket/base
;; Internal: far-vow handle + pipelined projection (ADR-0007 / ADR-0050 /
;; ADR-0052). Also the shared await/fetch classify path (`await-vow` /
;; `blocking-fetch`), and the far-send/tell mint (`session-far-send`). Session
;; owns CapTP verb wrappers and `session-await`; this module owns the
;; `session-vow` type, the host vow table register/settle/listen path,
;; `session-index`/`session-untag`/`session-get`, far-send mint, and the
;; post-mint wait/classify.

(require ffi/unsafe
         racket/lazy-require
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "host.rkt"
         "value.rkt"
         "codec.rkt")

;; `session-host` / pump / guard live in session/pump. Lazy-require breaks the
;; session ↔ promise and promise ↔ pump cycles (session eagerly requires this
;; module; pump lazy-requires session).
(lazy-require
 ["session.rkt" (session-host session-ptr guard-open session-flush!)]
 ["pump.rkt" (pump-until)])

(provide (struct-out session-vow)
         register-vow!
         settle-vow!
         session-vow-listen!
         session-index
         session-untag
         session-get
         project-vow
         await-vow
         blocking-fetch
         session-far-send)

;; A far vow is the binding's handle on one host vow: the home
;; connection, the settled state, and the Racket listeners waiting on it. The
;; vow is registered in the host's vow table the instant it is minted, under
;; the same host lock as the minting FFI call, and the action drain's
;; SETTLE/FAIL arms record the outcome here — so a late `on`/`session-await`
;; still settles from the recorded state (the binding's spelling of the
;; resolution stash the other bindings keep), and no settle callback ever
;; crosses the C boundary.
(struct session-vow (conn id [state #:mutable] [listeners #:mutable]) #:transparent)

;; Register a freshly minted vow so the drain can route its completion.
;; Caller holds the host lock, so no drain can pop the completion first.
(define (register-vow! m v)
  (hash-set! (host-vows m) (session-vow-id v) v))

;; The drain's settle arm: record the outcome, drop the table row (a vow
;; settles once), and hand back the parked listeners as fire thunks — a
;; listener is arbitrary application code (the vat's `on`), so it must run
;; after the host lock releases, never under it, or a listener that pumps
;; could park the whole node. State mutation stays under the lock, so a
;; blocking `session-await`'s state poll never races the fire. An unregistered
;; id yields nothing — an outcome nobody awaits.
(define (settle-vow! m id outcome)
  (define v (hash-ref (host-vows m) id #f))
  (cond
    [v
     (hash-remove! (host-vows m) id)
     (set-session-vow-state! v outcome)
     (define ls (session-vow-listeners v))
     (set-session-vow-listeners! v '())
     (for/list ([l (in-list (reverse ls))])
       (lambda () (l (cdr outcome) (not (eq? (car outcome) 'ok)))))]
    [else '()]))

;; Register `(listener value broken?)` on a far vow: fire now from the recorded
;; state when it already settled, else park it for the drain's settle arm. The
;; vat's `on` reaches far vows through this (via the installed far half).
(define (session-vow-listen! a-vow listener)
  (unless (session-vow? a-vow) (error 'on "not a vow: ~a" a-vow))
  (define s (session-vow-state a-vow))
  (cond
    [(eq? s 'pending)
     (set-session-vow-listeners! a-vow (cons listener (session-vow-listeners a-vow)))]
    [(eq? (car s) 'ok) (listener (cdr s) #f)]
    [else (listener (cdr s) #t)]))

;; ── Pipelined projections (ADR-0050) ─────────────────────────────────────────
;; Project an element, unwrapped tag, or Struct field out of a far vow WITHOUT
;; waiting for it to settle, returning a new vow for the projected value. The
;; projection rides the wire as `op:index` / `op:untag` / `op:get` against the
;; receiver's answer (ADR-0050/ADR-0052), so it pipelines exactly like a dependent call:
;; `(session-untag c vow "row")` then `(session-index c that 0)` reaches the first
;; element of an unwrapped tagged record in one batch, before the source resolves.
;; The returned vow is itself a projection or `session-send` target, and settles via
;; `session-await`. Bytes leave on the next pump (a `session-await`/`session-send` drain),
;; matching `session-send-promise`.
(define (session-index c a-vow i)
  (project-vow (session-host c) a-vow
               (lambda (m id) (pancake_host_vow_index (host-ptr m) id i))))

(define (session-untag c a-vow tag)
  (define tb (string->bytes/utf-8 tag))
  (project-vow (session-host c) a-vow
               (lambda (m id)
                 (pancake_host_vow_untag (host-ptr m) id (pin-immobile tb) (bytes-length tb)))))

(define (session-get c a-vow field)
  (define fb (string->bytes/utf-8 field))
  (project-vow (session-host c) a-vow
               (lambda (m id)
                 (pancake_host_vow_get (host-ptr m) id (pin-immobile fb) (bytes-length fb)))))

(define (project-vow m a-vow mint)
  (unless (session-vow? a-vow)
    (raise-pancake 'conn-project ERR-INVALID-ARGUMENT
                   "projection target is not a far vow: ~a" a-vow))
  (call-with-host m
    (lambda ()
      (define-values (rc id) (mint m (session-vow-id a-vow)))
      (check/host rc)
      (define home (session-vow-conn a-vow))
      (define v (session-vow home id 'pending '()))
      (register-vow! m v)
      v)))

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
    [(closed) (raise-pancake who ERR-CLOSED "connection closed before ~a settled" label)]
    [else (raise-pancake who ERR-BROKEN "~a broke: ~a" label (cdr r))]))

;; The one blocking fetch shape `session-fetch` and `session-enliven` share:
;; `mint!` runs the registering FFI verb (the one thing that differs) and
;; returns the minted vow id, the vow joins the host's table before the lock
;; drops, and the pump drains its SETTLE/FAIL completion off the action queue.
;; Classify: only a live Host reference fulfills; a partner break raises
;; typed ERR-BROKEN; the disconnect's own break raises typed ERR-CLOSED.
(define (blocking-fetch c who what label mint!)
  (define m (session-host c))
  (define v
    (call-with-host m
      (lambda ()
        (define-values (rc id) (mint!))
        (check/host rc)
        (define fresh (session-vow c id 'pending '()))
        (register-vow! m fresh)
        fresh)))
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
       (raise-pancake who ERR-UNSUPPORTED-VALUE
                      "~a \"~a\" did not resolve to a capability: ~a" what label val))
     val]
    [(closed)
     (raise-pancake who ERR-CLOSED "connection closed before \"~a\" settled" label)]
    [else
     (raise-pancake who ERR-BROKEN "~a \"~a\" broke: ~a" what label (cdr r))]))

;; Far-send / far-tell mint: encode args, enqueue `conn_send` / `vow_send` /
;; `conn_tell`, register any answer vow. Local-hosted targets stay in Session
;; (`session-send-local`). Outside a turn, flush this connection after the mint
;; so the deliver cannot sit unsent while a partner waits; inside a turn the
;; flush is deferred (`session-flush!` no-ops) and the host encodes at unwind,
;; so a pipelined chain still travels as one batch on the settling send's pump.
;; An empty verb symbol is a methodless positional deliver (verb length zero on
;; the wire). `answer?` #t returns the minted `session-vow`; #f is tell
;; (Goblins `<-np`). Promise-pipelined targets ride `vow_send`.
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
        (cond
          [(session-vow? target)
           (define-values (rc id)
             (pancake_host_vow_send (host-ptr m) (session-vow-id target) vbuf vlen aptr acnt))
           (check/host rc)
           (define home (session-vow-conn target))
           (define v (session-vow home id 'pending '()))
           (register-vow! m v)
           (if answer? v (void))]
          [(ref? target)
           (cond
             [answer?
              (define-values (rc id)
                (pancake_host_session_send (session-ptr c) (ref->c target) vbuf vlen aptr acnt))
              (check/host rc)
              (define v (session-vow c id 'pending '()))
              (register-vow! m v)
              v]
             [else
              (check/host (pancake_host_session_tell (session-ptr c) (ref->c target) vbuf vlen aptr acnt))
              (void)])]
          [else
           (raise-pancake 'session-send ERR-INVALID-ARGUMENT "not a sendable reference: ~a" target)]))))
  (session-flush! c)
  result)
