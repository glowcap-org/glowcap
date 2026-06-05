#lang racket/base

;; racket-socket-netlayer.rkt — a captp-side netlayer for the
;; pancake-backed `captp.rkt` whose TRANSPORT is Racket's own
;; `racket/tcp` (tcp-listen / tcp-accept / tcp-connect), NOT pancake's
;; TCP-endpoint FFI.
;;
;; THE CLAIM THIS MODULE EXISTS TO PROVE (interop-matrix "Stack 2"):
;; a modified Spritely Goblins app can run on pancake for its
;; OCapN/CapTP wire protocol while the bytes still flow over
;; Spritely's own Racket TCP sockets. pancake supplies ONLY the
;; OCapN/CapTP (the proven `captp.rkt` drop-in for
;; `goblins/ocapn/captp`); the transport is Racket's `racket/tcp`.
;;
;; This is the mirror-image of `pancake-tcp-netlayer.rkt`. Both feed
;; the SAME `captp.rkt` pump the same `transport-ops` contract; the
;; only difference is what backs the four per-connection frame ops:
;;
;;   pancake-tcp-netlayer.rkt → pancake's net-tcp FFI endpoint (Rust
;;                              owns the socket + Syrup framing)
;;   racket-socket-netlayer.rkt (this) → raw Racket ports; the framing
;;                              is bridged on the Racket side via the
;;                              `pancake-syrup-frame-probe` FFI.
;;
;; HOW captp.rkt CONSUMES THIS (already proven):
;;
;;   ($ nl 'install-pancake-connection-handler
;;      (lambda (endpoint remote-location ops designator) ...))
;;       Captp's hook; called for each accepted connection. The
;;       handler takes ownership of the endpoint; releases it via
;;       the transport-ops conn-close when its per-connection pump
;;       finishes.
;;
;;   ($ nl 'our-location)
;;       Returns the bind address ("host:port").
;;
;; The `endpoint` is OPAQUE to captp — for pancake netlayers it's an
;; FFI pointer, but it can be ANY Racket value. Here it's a
;; `racket-socket-endpoint` struct carrying the (input-port,
;; output-port) pair plus a read buffer + the captp-set read timeout.
;;
;; The `transport-name` is "tcp-testing-only" — byte-compatible with
;; stock Spritely's TCP netlayer, so a stock-Goblins client speaking
;; OCapN over Spritely's TCP netlayer interoperates with a host
;; running captp.rkt + this netlayer.

(provide ^racket-socket-netlayer
         (rename-out [^racket-socket-netlayer ^tcp-netlayer])
         racket-socket-transport-ops)

(require ffi/unsafe
         goblins
         goblins/actor-lib/methods
         racket/tcp
         "pancake-ffi.rkt")

;; ─── Endpoint: a Racket-port pair + read buffer ────────────────────
;;
;; The captp pump treats this as opaque. We carry:
;;   in / out   — the Racket ports from tcp-accept / tcp-connect
;;   buffer     — accumulated, not-yet-framed inbound bytes (mutable)
;;   timeout-ms — the read timeout captp sets via set-read-timeout
;;                (>0 → read-frame returns 'would-block when no
;;                 complete frame is ready within the window, so the
;;                 pump cooperatively yields; 0 → block).
(struct racket-socket-endpoint
  (in out [buffer #:mutable] [timeout-ms #:mutable])
  #:transparent)

(define (make-racket-socket-endpoint in out)
  (racket-socket-endpoint in out #"" 0))

;; Generous self-protection cap for a single Syrup frame. The probe
;; reports MALFORMED if a length prefix exceeds this; keeps a hostile
;; / corrupt peer from forcing unbounded buffering. 64 MiB is far
;; above any legitimate OCapN message.
(define MAX-FRAME-BYTES (* 64 1024 1024))

;; Read-chunk size for each socket pull.
(define READ-CHUNK-BYTES 4096)

;; Probe `buf` for ONE complete Syrup frame via the pancake FFI.
;; Returns:
;;   'incomplete — no complete frame yet (need more bytes)
;;   'malformed  — Syrup grammar violation; caller must abort
;;   <integer>   — byte offset where the first complete frame ends
;;                 (exclusive)
(define (probe-frame buf)
  (define len (bytes-length buf))
  (cond
    [(zero? len) 'incomplete]
    [else
     (define out-end (malloc _size 'atomic-interior))
     (ptr-set! out-end _size 0)
     (define rc (pancake-syrup-frame-probe buf len out-end MAX-FRAME-BYTES))
     (cond
       [(= rc PANCAKE_FRAME_COMPLETE) (ptr-ref out-end _size 0)]
       [(= rc PANCAKE_FRAME_INCOMPLETE) 'incomplete]
       [else 'malformed])]))

;; ─── transport-ops: the four per-connection frame ops ──────────────

;; read-frame: return ONE complete Syrup frame's bytes, keeping any
;; trailing bytes buffered for the next call. Uses the captp-set read
;; timeout to bound how long we wait for the socket so the pump can
;; yield. Returns one of:
;;   bytes        — a complete Syrup frame
;;   'would-block — no complete frame ready within the timeout window
;;   'closed      — EOF (clean teardown or remote disconnect)
;;   'malformed   — probe reported a Syrup grammar violation
(define (rsock-read-frame ep)
  (define in (racket-socket-endpoint-in ep))
  (let loop ()
    (define buf (racket-socket-endpoint-buffer ep))
    (define probe (probe-frame buf))
    (cond
      [(eq? probe 'malformed) 'malformed]
      [(exact-integer? probe)
       ;; Complete frame in [0, probe); slice it out + keep remainder.
       (define frame (subbytes buf 0 probe))
       (set-racket-socket-endpoint-buffer! ep (subbytes buf probe))
       frame]
      [else
       ;; 'incomplete — pull more bytes (bounded by the read timeout).
       (define timeout-ms (racket-socket-endpoint-timeout-ms ep))
       (define ready
         (if (and (number? timeout-ms) (> timeout-ms 0))
             (sync/timeout (/ timeout-ms 1000.0) in)
             (sync in)))
       (cond
         [(not ready)
          ;; Timed out with no readable bytes; yield to the pump.
          'would-block]
         [else
          (define chunk (make-bytes READ-CHUNK-BYTES))
          (define n (read-bytes-avail! chunk in))
          (cond
            [(eof-object? n) 'closed]
            [(zero? n) 'would-block]
            [else
             (set-racket-socket-endpoint-buffer!
              ep (bytes-append buf (subbytes chunk 0 n)))
             (loop)])])])))

;; write-frame: pancake frames are already complete, self-delimiting
;; Syrup values — write them verbatim + flush. The partner re-frames
;; via the same probe.
(define (rsock-write-frame ep frame-bytes)
  (define out (racket-socket-endpoint-out ep))
  (write-bytes frame-bytes out)
  (flush-output out)
  (void))

;; conn-close: tear down both ports.
(define (rsock-conn-close ep)
  (define in (racket-socket-endpoint-in ep))
  (define out (racket-socket-endpoint-out ep))
  (with-handlers ([exn? void]) (close-input-port in))
  (with-handlers ([exn? void]) (close-output-port out))
  (void))

;; set-read-timeout: record the captp-chosen poll window (ms).
(define (rsock-set-read-timeout ep ms)
  (set-racket-socket-endpoint-timeout-ms! ep ms)
  (void))

;; The transport-ops bundle captp hands to its per-connection pump.
;; transport-name "tcp-testing-only" keeps the advertised
;; `acceptable_location` byte-compatible with stock Spritely's TCP
;; netlayer.
(define racket-socket-transport-ops
  (transport-ops rsock-read-frame
                 rsock-write-frame
                 rsock-conn-close
                 rsock-set-read-timeout
                 "tcp-testing-only"))

;; ─── The netlayer actor ────────────────────────────────────────────
;;
;; Same actor-shape as `pancake-tcp-netlayer.rkt`: an `install-
;; pancake-connection-handler` hook + an `our-location` accessor, with
;; an accept loop running in a PLAIN background thread (NOT the vat —
;; the accept thread runs outside any syscaller context, so `$` would
;; error with "Sorry, this syscaller is closed for business!").
;;
;; The transport is Racket's `racket/tcp`. Unlike the FFI accept
;; (which holds an OS thread inside Rust and needs a polling timeout),
;; Racket's `tcp-accept` is green-thread cooperative: a blocking
;; accept here suspends only this green thread, so per-connection pump
;; threads still get scheduled. No accept timeout needed.
(define (^racket-socket-netlayer _bcom listen-host listen-port)
  (define our-loc (format "~a:~a" listen-host listen-port))
  ;; Plain Racket box (not a Goblins ^cell) because the accept thread
  ;; runs OUTSIDE any syscaller context.
  (define handler-box (box #f))

  (define listener (tcp-listen listen-port 5 #t listen-host))
  (define accept-thread
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn?
                          (lambda (e)
                            (eprintf "[racket-socket-netlayer] accept failed: ~a~n"
                                     (exn-message e)))])
           (define-values (in out) (tcp-accept listener))
           (define handler (unbox handler-box))
           (cond
             [handler
              (define ep (make-racket-socket-endpoint in out))
              (handler ep our-loc racket-socket-transport-ops our-loc)]
             [else
              (eprintf "[racket-socket-netlayer] connection accepted but no handler installed; closing~n")
              (with-handlers ([exn? void]) (close-input-port in))
              (with-handlers ([exn? void]) (close-output-port out))]))
         (loop)))))

  (methods
   [(install-pancake-connection-handler h)
    (set-box! handler-box h)]
   [(our-location) our-loc]))
