#lang racket/base
;; The dial executor: one path that turns an OCapN locator into an open,
;; handshaken `session`, shared by Runtime dialing and handoff redemption.
;;
;; Locator semantics belong to OCapN and transport realization belongs to the
;; selected product package. This module only chooses between two explicit
;; seams: a driver-provider for a native loop or a byte-connector for a
;; byte-fed Host. It never classifies a locator into a transport-specific sum.
;;
;; Lazy-require breaks the session ↔ dial cycle: dial lazy-requires session
;; for serve / drain choreography and session/close for terminal close; the
;; public barrel (`pancake.rkt`) requires dial directly.

(require ffi/unsafe
         racket/lazy-require
         "constants.rkt"
         "ffi-host.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         "host/state.rkt"
         "transport.rkt"
         (only-in "abi-value.rkt"
                  DEFAULT-CAPTP-VERSION-SYMBOL
                  DEFAULT-CODEC-SYMBOL
                  DEFAULT-FEATURES-SYMBOL
                  feature-mask)
         "action.rkt"
         "session/state.rkt"
         ;; The handshake bound lives with the deadline machinery it feeds, so
         ;; the dial and the accept rule spell their default with one constant.
         (only-in "pump.rkt" HANDSHAKE-TIMEOUT-MS with-host-drain))

(lazy-require
 ["loop.rkt"
 (open-driver-loop
   driver-loop?
   driver-loop-start!
   driver-loop-abort!
   loop-connect-session)]
 ["session.rkt"
  (session-serve)]
 ["session/close.rkt"
  (session-close!)])

(provide dial-exporter
         run-dial!
         retain-host-cleanup-failure!
         runtime?
         runtime-host
         open-runtime
         runtime-connect
         runtime-close!)

(struct runtime (host mode handshake-timeout-ms) #:transparent)

;; A provider owns its archive and policy. The generic loop confirms the
;; runtime registration through the driver's package authority.
(define (install-provider! lp provider m)
  (unless (driver-provider? provider)
    (raise-argument-error 'open-runtime "driver-provider?" provider))
  ((driver-provider-install! provider) lp m))

(define (dial-byte-fed connector m loc handshake-timeout-ms)
  (unless (byte-connector? connector)
    (raise-argument-error 'connect "byte-connector?" connector))
  (define transport (locator-transport loc))
  (unless (byte-connector-supports? connector transport)
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "the supplied connector does not advertise transport \"~a\""
                   transport))
  ((byte-connector-realize connector) m loc handshake-timeout-ms))

(define (check-runtime-host-options adopted-host seed codec captp-version features)
  (when (and adopted-host seed)
    (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                   "#:adopt-host and #:seed are mutually exclusive"))
  (when (and adopted-host codec (not (eq? codec (host-codec adopted-host))))
    (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                   "#:codec ~a conflicts with the Host's ~a"
                   codec (host-codec adopted-host)))
  (when (and adopted-host captp-version
             (not (eq? captp-version (host-captp-version adopted-host))))
    (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                   "#:captp-version ~a conflicts with the Host's ~a"
                   captp-version (host-captp-version adopted-host)))
  (when (and adopted-host features
             (not (= (feature-mask features)
                     (feature-mask (host-features adopted-host)))))
    (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                   "#:features ~a conflicts with the Host's ~a"
                   features (host-features adopted-host))))

(define (runtime-host-for adopted-host seed codec captp-version features)
  (or adopted-host
      (if seed
          (make-host seed
                     #:codec (or codec DEFAULT-CODEC-SYMBOL)
                     #:captp-version (or captp-version DEFAULT-CAPTP-VERSION-SYMBOL)
                     #:features (or features DEFAULT-FEATURES-SYMBOL))
          (make-fresh-host
           #:codec (or codec DEFAULT-CODEC-SYMBOL)
           #:captp-version (or captp-version DEFAULT-CAPTP-VERSION-SYMBOL)
           #:features (or features DEFAULT-FEATURES-SYMBOL)))))

(define (check-composition who values predicate transports-of label)
  (unless (and (list? values) (pair? values) (andmap predicate values))
    (raise-argument-error who (format "non-empty (listof ~a?)" label) values))
  (define seen (make-hash))
  (for* ([value (in-list values)]
         [transport (in-list (transports-of value))])
    (when (hash-ref seen transport #f)
      (raise-pancake who ERR-INVALID-ARGUMENT
                     "Runtime composition repeats transport \"~a\""
                     transport))
    (hash-set! seen transport #t)))

;; Construct one long-lived Host plus exactly one transport execution model.
;; Provider and connector values retain their own archive/configuration policy;
;; connectors advertise the symbols this binding routes, while the native
;; driver registry alone owns provider symbols.
(define (open-runtime #:providers [providers #f]
                      #:connectors [connectors #f]
                      #:adopt-host [adopted-host #f]
                      #:seed [seed #f]
                      #:codec [codec #f]
                      #:captp-version [captp-version #f]
                      #:features [features #f]
                      #:handshake-timeout-ms
                      [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (when (eq? (and providers #t) (and connectors #t))
    (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                   "supply exactly one of #:providers or #:connectors"))
  (check-runtime-host-options adopted-host seed codec captp-version features)
  (define m (runtime-host-for adopted-host seed codec captp-version features))
  (cond
    [providers
     (unless (and (list? providers) (pair? providers)
                  (andmap driver-provider? providers))
       (raise-argument-error 'open-runtime
                             "non-empty (listof driver-provider?)"
                             providers))
     (define existing-loop (host-loop-of m))
     (define lp (or existing-loop
                    (open-driver-loop #:host m
                                      #:handshake-ms (or handshake-timeout-ms 0))))
     (with-handlers ([(lambda (_) #t)
                      (lambda (e)
                        (when (and (not existing-loop) (not adopted-host))
                          (driver-loop-abort! lp))
                        (raise e))])
       (for ([provider (in-list providers)])
         (install-provider! lp provider m))
       (driver-loop-start! lp)
       (runtime m lp handshake-timeout-ms))]
    [else
     (check-composition 'open-runtime connectors byte-connector?
                        byte-connector-transports 'byte-connector)
     (when (host-loop-of m)
       (unless adopted-host (host-close! m))
       (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                      "a native-loop Host cannot be transferred to a connector Runtime"))
     ;; Validate the complete registry before mutating the Host, so installation
     ;; is transactional even when the caller supplied it.
     (for* ([connector (in-list connectors)]
            [transport (in-list (byte-connector-transports connector))])
       (when (host-connector-for m transport)
         (unless adopted-host (host-close! m))
         (raise-pancake 'open-runtime ERR-INVALID-ARGUMENT
                        "Host already has a connector for transport \"~a\""
                        transport)))
     (for ([connector (in-list connectors)])
       (host-register-connector! m connector))
     (runtime m 'byte-fed handshake-timeout-ms)]))

(define (runtime-connect rt loc #:options [options #f])
  (unless (runtime? rt) (raise-argument-error 'runtime-connect "runtime?" rt))
  (unless (locator? loc) (raise-argument-error 'runtime-connect "locator?" loc))
  (define transport (locator-transport loc))
  (define mode (runtime-mode rt))
  (cond
    [(driver-loop? mode)
     (loop-connect-session mode loc options)]
    [else
     (when options
       (raise-pancake 'runtime-connect ERR-INVALID-ARGUMENT
                      "operation options are not supported by this connector Runtime"))
     (define connector (host-connector-for (runtime-host rt) transport))
     (unless connector
       (raise-pancake 'runtime-connect ERR-INVALID-ARGUMENT
                      "Runtime has no connector for transport \"~a\""
                      transport))
     (dial-byte-fed connector (runtime-host rt) loc
                    (runtime-handshake-timeout-ms rt))]))

(define (runtime-close! rt
                        #:pending [pending 'cancel]
                        #:grace-ms [grace-ms grace-unspecified])
  (unless (runtime? rt) (raise-argument-error 'runtime-close! "runtime?" rt))
  ;; Every explicit request reaches the shared native barrier. In particular,
  ;; a later cancel must be able to escalate an in-progress finish.
  (host-close! (runtime-host rt) #:pending pending #:grace-ms grace-ms))

(define (dial-exporter m loc
                       #:handshake-timeout-ms
                       [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (define transport (locator-transport loc))
  (define lp (host-loop-of m))
  (cond
    [lp
     (loop-connect-session lp loc)]
    [(host-connector-for m transport)
     (dial-byte-fed (host-connector-for m transport) m loc handshake-timeout-ms)]
    [else
     (raise-pancake 'connect ERR-INVALID-ARGUMENT
                    "Host has no explicit connector for transport \"~a\""
                    transport)]))

;; Cleanup is a second outcome, not the dial's outcome. Keep its exact first
;; failure on the owning Host so the close barrier can return it, while letting
;; the dial executor finish reporting the original refusal to its waiting vow.
(define (retain-host-cleanup-failure! m cleanup)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (record-host-runtime-failure! m error)
                     (void))])
    (cleanup)))

;; Execute one DIAL action, post-lock — the drain parks it among the fires,
;; because the dial is a connect syscall plus a whole keyed handshake and
;; would otherwise hold the host lock across both, parking every thread that
;; shares the host behind one slow exporter. The executor takes the lock only
;; inside the brief host verbs it contains, and each completion report opens
;; its own locked drain window, so the withdraw legs the report queues
;; (deposits, settles, flushes) drain as that report's own effects. A failed
;; dial breaks every waiting redeem with the reason. The exporter connection
;; is kept pumped by a background serve so the withdraw's resolution — and
;; any later routed traffic — is read.
(define (run-dial! m ticket route-index [cancelled? (lambda () #f)])
  ;; Clone the concrete attempt's parsed locator, then dial. The
  ;; dynamic-wind after-thunk is the terminal guard: a break aimed at the
  ;; executing green thread cannot strand the already-popped ticket.
  (define c #f)
  (define reported? #f)
  (define adopted? #f)
  (define failure "dial interrupted")
  (dynamic-wind
   void
   (lambda ()
     (with-handlers ([converts-to-broken?
                      (lambda (e)
                        (set! failure (exn->message e)))])
       (define-values (rc locator-handle)
         (pancake_host_pending_dial (host-ptr m) ticket route-index))
       (check/host rc)
       (define loc (call-with-owned-locator-handle locator-handle owned-locator->locator))
       (set! c (dial-exporter m loc))
       (with-host-drain m
         (lambda ()
           ;; The report and local commit bit are one unbreakable transition:
           ;; after host-dialed succeeds this ticket no longer admits a failure
           ;; report, even if a later drain effect is interrupted.
           (parameterize-break
            #f
            (set! adopted? (host-dialed! m ticket route-index (session-ptr c)))
            (set! reported? #t))
           (drain-host-actions! m)))
       (void)))
   (lambda ()
     ;; Cleanup and post-commit serve ownership must both survive a pending
     ;; break. The after-thunk runs exactly once, so a reported session gets
     ;; exactly one reader thread even when interruption lands after commit.
     (parameterize-break
      #f
      (if reported?
          (if adopted?
              (thread
               (lambda ()
                 (with-handlers ([converts-to-broken?
                                  (lambda (error)
                                    (record-host-runtime-failure! m error))])
                   (session-serve c))))
              (retain-host-cleanup-failure! m (lambda () (session-close! c))))
          (begin
            ;; Roll back the opened session before failure is reported, matching
            ;; the transactional C Host contract.
            (when c
              (retain-host-cleanup-failure! m (lambda () (session-close! c))))
            (unless (or (cancelled?) (unbox (host-released? m)))
              (retain-host-cleanup-failure!
               m
               (lambda ()
                (with-host-drain m
                  (lambda ()
                    (host-dial-failed! m ticket route-index failure)
                    (drain-host-actions! m))))))))))))
