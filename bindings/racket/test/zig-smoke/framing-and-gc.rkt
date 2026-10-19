#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
         racket/random
         racket/runtime-path
         "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         "../../glowcap-inproc.rkt"
         "../../glowcap-onion.rkt"
         "../../glowcap-iroh.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/establish.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         (only-in "../../private/iroh.rkt" iroh-endpoint-record-failure!)
         "../../private/locator.rkt"
         "../../private/async.rkt"
         "../../private/byte-channel.rkt"
         (only-in "../../private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-ffi-finalizer!)
         (only-in "../../private/ws-transport.rkt" ws-transport)
         (only-in "../../relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "../../private/pump.rkt"
         "../../private/action.rkt"
         (only-in "../../private/dial.rkt" retain-host-cleanup-failure!)
         "../../private/promise.rkt"
         "../../private/gc.rkt"
         "../../private/vat.rkt"
         "../../private/ffi-host.rkt"
         "../../private/ffi-ocapn.rkt"
         "../../private/ffi-shared.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/abi-value.rkt"
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "../../private/ffi-parent.rkt"
         (only-in "../../private/value.rkt" make-ref/internal)
         "support.rkt"
         racket/tcp)

;; ── Distributed GC (ADR-0025): every projected application occurrence ────────
;; Fetch results, nested send replies, and nested delivered arguments are each
;; released explicitly. The relay observes both real wire directions before
;; teardown, so collector timing and a session-close sweep cannot satisfy the
;; proof accidentally.
(define gc-server (listen "127.0.0.1" 0))
(define gc-ready (make-semaphore 0))
(define gc-inbound (make-channel))
(define gc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (session-with-gc! (accept gc-server)))
       (define delegated
         (session-spawn hsession (lambda (bcom) (methods [(ping) (sym "alive")]))))
       (session-publish
        hsession "factory"
        (lambda (bcom)
          (methods
           [(reply) (struct-arg (list (cons "nested" (list delegated))))]
           [(accept payload)
            (expect (and (struct-arg? payload)
                         (equal? "nested" (caar (struct-arg-entries payload)))
                         (list? (cdar (struct-arg-entries payload)))
                         (ref? (car (cdar (struct-arg-entries payload)))))
                    "gc: server received a nested capability argument")
            (channel-put gc-inbound (car (cdar (struct-arg-entries payload))))
            (void)])))
       (semaphore-post gc-ready)
       (define serving
         (thread (lambda () (session-serve hsession))))
       (session-release! hsession (channel-get gc-inbound))
       (thread-wait serving)))))
(define gc-to-server (box 0))
(define gc-to-client (box 0))
(define gc-to-server-seen (make-semaphore 0))
(define gc-to-client-seen (make-semaphore 0))
(define gc-needle #"op:gc-export")
(define (make-gc-scanner count seen)
  (define tail #"")
  (lambda (chunk)
    (define combined (bytes-append tail chunk))
    (define found (length (regexp-match-positions* #rx#"op:gc-export" combined)))
    (set-box! count (+ (unbox count) found))
    (for ([_ (in-range found)]) (semaphore-post seen))
    (define keep (min (bytes-length combined) (sub1 (bytes-length gc-needle))))
    (set! tail (subbytes combined (- (bytes-length combined) keep)))
    #f))
(define-values (gc-relay gc-relay-port)
  (start-sniffing-relay (server-port gc-server)
                        (make-gc-scanner gc-to-server gc-to-server-seen)
                        #:on-return-chunk (make-gc-scanner gc-to-client gc-to-client-seen)))
(define gc-session (session-with-gc! (open-test-session (tcp-locator "127.0.0.1" gc-relay-port))))
(semaphore-wait gc-ready)
(define (wait-for-gc! count seen expected label)
  (unless (>= (unbox count) expected)
    (sync/timeout 10 seen))
  (expect (>= (unbox count) expected) label))
(define gc-factory (box (session-fetch gc-session "factory")))
(define (gc-reply-and-drop!)
  (define reply (session-send gc-session (unbox gc-factory) 'reply))
  (expect (and (struct-arg? reply)
               (equal? "nested" (caar (struct-arg-entries reply)))
               (list? (cdar (struct-arg-entries reply)))
               (ref? (car (cdar (struct-arg-entries reply)))))
          "gc: send reply carried a nested capability")
  (session-release! gc-session (car (cdar (struct-arg-entries reply))))
  (void))
(gc-reply-and-drop!)
(wait-for-gc! gc-to-server gc-to-server-seen 1 "gc: nested send reply released")
(define gc-callback
  (session-spawn gc-session (lambda (bcom) (methods [(ping) (sym "client")]))))
(session-send gc-session (unbox gc-factory) 'accept
              (struct-arg (list (cons "nested" (list gc-callback)))))
(wait-for-gc! gc-to-client gc-to-client-seen 1 "gc: nested delivered argument released")
(session-release! gc-session (unbox gc-factory))
(set-box! gc-factory #f)
(wait-for-gc! gc-to-server gc-to-server-seen 2 "gc: fetched capability released")
(session-close! gc-session)
(void (sync/timeout 2 (thread-dead-evt gc-host)))
(tcp-close gc-relay)
(server-close! gc-server)

(printf "racket zig-smoke OK: distributed release reaches fetched, replied, and delivered capability homes\n")

;; A transport read exception is not EOF. The byte pump retains the exact
;; object, reports physical loss to the core, retires the FFI Session, and
;; makes a later close re-observe that same cause.
(define rf-host (make-fresh-host))
(define rf-first-failure
  (exn:fail "injected exact read failure" (current-continuation-marks)))
(define rf-close-count (box 0))
(define rf-session
  (open-dialed-over
   rf-host
   "tcp"
   (tcp-address-designator "127.0.0.1" 9)
   (async-transport
    (lambda (_frame) (void))
    void
    (lambda (_wake) (raise rf-first-failure))
    (lambda () (set-box! rf-close-count (add1 (unbox rf-close-count)))))))
(drain-host! rf-host)
(define rf-read-failure
  (with-handlers ([(lambda (_) #t) values])
    (pump-read-once! rf-session)
    'no-error))
(define rf-close-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-close! rf-session)
    'no-error))
(expect (eq? rf-first-failure rf-read-failure)
        "read failure: the pump converted an exact transport exception to EOF")
(expect (eq? rf-first-failure rf-close-failure)
        "read failure: close lost the exact transport exception")
(expect (and (session-released? rf-session) (= 1 (unbox rf-close-count)))
        "read failure: the Session was not physically retired exactly once")
(host-close! rf-host)

(printf "racket zig-smoke OK: a transport read exception stays exact through retirement\n")

;; ── Bounded tail: an over-cap frame is a typed refusal, not "read more" ──────
;; The core's stream delimiter (`glowcap_host_session_feed_bytes`) buffers a
;; partial frame in the session only while the frame stays admissible; a frame
;; declaring more than the frame cap must surface as the typed FRAME_TOO_LARGE
;; error, or an untrusted peer could grow the session's tail without
;; bound. This feeds the untrusted prefix through the exact byte path the
;; connection pump uses, into a byte-fed connection whose transport discards
;; the projected outbound abort.
(define oc-host (make-fresh-host))
(define oc-session (open-accepted-over oc-host "tcp" (tcp-address-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)
                                    #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
(drain-host! oc-host) ; the signed op:start-session leaves into the discard transport
(define oc-failure
  (with-handlers ([exn:fail:glowcap? values])
    (feed-bytes! oc-session #"2000000:")
    'no-error))
(expect (and (exn:fail:glowcap? oc-failure)
             (= ERR-FRAME-TOO-LARGE (exn:fail:glowcap-code oc-failure)))
        "over-cap frame: typed FRAME_TOO_LARGE refusal")
(define oc-close-failure
  (with-handlers ([exn:fail:glowcap? values])
    (session-close! oc-session)
    'no-error))
(expect (eq? oc-failure oc-close-failure)
        "over-cap frame: close retained the exact refusal")

(printf "racket zig-smoke OK: an over-cap frame refuses typed instead of buffering\n")

;; ── last-abort: a refused frame carries its typed cause ───────────────────────
;; The flat return code names the failure family; the `abort` field on the exn
;; a feeding connection raises names the member: domain, projected op:abort
;; kind, and the originating error. The untrusted bytes are fed straight into a
;; byte-fed connection through the core's stream delimiter, whose transport
;; discards the projected outbound abort.
(define la-host (make-fresh-host))
(define la-session (open-accepted-over la-host "tcp" (tcp-address-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)
                                    #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
(drain-host! la-host) ; the signed op:start-session leaves into the discard transport
(expect (not (session-last-abort la-session)) "last-abort: nothing recorded before a failure")
(define la-exn
  (with-handlers ([exn:fail:glowcap? values])
    (feed-bytes! la-session #"this is not a frame")
    'no-error))
(expect (exn:fail:glowcap? la-exn) "last-abort: a refused frame raised exn:fail:glowcap")
(define la-info (exn:fail:glowcap-abort la-exn))
(expect (abort-info? la-info) "last-abort: the exn carries the typed abort detail")
(expect (eq? 'codec (abort-info-domain la-info)) "last-abort: domain is codec")
(expect (equal? "MalformedFrame" (abort-info-kind la-info)) "last-abort: kind is MalformedFrame")
(expect (equal? "MalformedFrame" (abort-info-error-name la-info)) "last-abort: error-name is MalformedFrame")
(expect (not (abort-info-abort-delivery-error-name la-info))
        "last-abort: successful abort delivery has no consequence error")
(expect (not (abort-info-secondary-error-name la-info))
        "last-abort: successful cleanup has no secondary error")
(expect (zero? (abort-info-secondary-error-count la-info))
        "last-abort: successful cleanup has no secondary failures")
(expect (abort-info? (session-last-abort la-session)) "last-abort: the reader reads the same recorded cause")
(define la-close-exn
  (with-handlers ([exn:fail:glowcap? values])
    (session-close! la-session)
    'no-error))
(expect (eq? la-exn la-close-exn) "last-abort: close retained the exact refused-frame failure")

(printf "racket zig-smoke OK: a refused frame carries its typed last-abort cause\n")
