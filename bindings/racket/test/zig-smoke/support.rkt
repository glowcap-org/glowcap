#lang racket/base
;; Shared ownership for the Racket dogfood scenario modules: assertion
;; reporting, fresh Runtime/session construction, aggregate Runtime teardown,
;; and the one counter actor several independent scenarios exercise.

(require "../../pancake.rkt"
         "../../pancake-tcp.rkt"
         (only-in "../../private/session.rkt" build-session)
         (only-in "../../private/host/state.rkt" call-with-host host-ptr)
         (only-in "../../private/locator.rkt" call-with-locator-view)
         (only-in "../../private/errors.rkt" check/host)
         (only-in "../../private/ffi-shared.rkt" pin-immobile)
         (only-in "../../private/ffi-host.rkt"
                  pancake_host_session_open_dialed_locator
                  pancake_host_session_open_accepted)
         racket/tcp)

(provide expect
         fail
         open-test-session
         open-dialed-over
         open-accepted-over
         close-test-runtimes!
         start-sniffing-relay
         ^counter)

;; A failure must not swallow the successful boundaries that preceded it.
(file-stream-buffer-mode (current-output-port) 'line)

;; Each call models a distinct peer unless it explicitly supplies a Host.
;; Accordingly each helper call opens one test-owned Runtime; sharing one here
;; would silently reuse peer identity and reject a second session to the same
;; partner as a duplicate pair. The aggregate retires every Runtime at teardown.
(define tcp-provider-for-smoke (tcp-provider))
(define extra-runtimes (box '()))

(define (open-test-session loc #:provider [provider tcp-provider-for-smoke]
                           #:connector [connector #f] #:adopt-host [adopted-host #f]
                           #:codec [codec #f] #:captp-version [captp-version #f]
                           #:features [features #f]
                           #:handshake-timeout-ms
                           [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (define runtime
    (open-runtime
     #:providers (and (not connector) (list provider))
     #:connectors (and connector (list connector))
     #:adopt-host adopted-host #:codec codec
     #:captp-version captp-version #:features features
     #:handshake-timeout-ms handshake-timeout-ms))
  (set-box! extra-runtimes (cons runtime (unbox extra-runtimes)))
  (runtime-connect runtime loc))

;; Mint either half of a byte-fed Host session over an arbitrary transport.
;; These helpers stop before establishment so each scenario can drive the
;; precise hello or hostile-frame boundary it owns.
(define (open-dialed-over m transport-name designator tr)
  (call-with-locator-view (locator transport-name designator (hash) 'boolean-false)
    (lambda (view)
      (call-with-host m
        (lambda ()
          (define-values (rc ptr)
            (pancake_host_session_open_dialed_locator (host-ptr m) view))
          (check/host rc)
          (build-session m ptr tr #f))))))

(define (open-accepted-over m transport-name designator tr
                            #:designator-scheme designator-scheme)
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  ;; These scenarios know the accepted endpoint they model. An empty address
  ;; deliberately retains the binding's unreachable-client posture.
  (define hb db)
  (call-with-host m
    (lambda ()
      (define tpin (pin-immobile tb))
      (define dbpin (pin-immobile db))
      (define hbpin (pin-immobile hb))
      (define-values (rc ptr)
        (pancake_host_session_open_accepted (host-ptr m)
                                             tpin (bytes-length tb)
                                             designator-scheme
                                             dbpin (bytes-length db)
                                             hbpin (bytes-length hb)))
      (check/host rc)
      (build-session m ptr tr #f))))

(define (close-test-runtimes!)
  (for ([runtime (in-list (unbox extra-runtimes))])
    (runtime-close! runtime))
  (set-box! extra-runtimes '()))

(define (fail msg)
  (eprintf "racket zig-smoke FAILED: ~a\n" msg)
  (exit 1))

(define (expect cond msg)
  (unless cond (fail msg)))

;; A relay between a dialing client and `target-port` that lets a scenario
;; observe or sever either wire direction without replacing either high-level
;; endpoint.
(define (start-sniffing-relay target-port on-chunk
                              #:before-connect [before-connect void]
                              #:on-return-chunk [on-return-chunk #f])
  (define lst (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses lst #t))
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define-values (cin cout) (tcp-accept lst))
       (before-connect)
       (define-values (sin sout) (tcp-connect "127.0.0.1" target-port))
       (define (close-all!)
         (for-each (lambda (p) (with-handlers ([(lambda (_) #t) void])
                                 (if (input-port? p) (close-input-port p) (close-output-port p))))
                   (list cout sout cin sin)))
       (define (pump-side in out watch)
         (thread
          (lambda ()
            (with-handlers ([(lambda (_) #t) void])
              (let loop ()
                (define buf (make-bytes 65536))
                (define n (read-bytes-avail! buf in))
                (cond
                  [(eof-object? n) (close-all!)]
                  [else
                   (define chunk (subbytes buf 0 n))
                   (cond
                     [(and watch (eq? 'close (watch chunk))) (close-all!)]
                     [else (write-bytes chunk out) (flush-output out) (loop)])]))))))
       (pump-side cin sout on-chunk)
       (pump-side sin cout on-return-chunk))))
  (values lst port))

;; A Goblins-faithful actor used by the local-vat, time-travel, and transport
;; scenarios. `add` becomes a fresh behavior through `bcom`; `get` reports the
;; current total.
(define (^counter bcom n)
  (methods
   [(add x) (bcom (^counter bcom (+ n x)) (+ n x))]
   [(get) n]))
