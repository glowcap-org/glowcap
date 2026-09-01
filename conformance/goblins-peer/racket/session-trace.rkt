#lang racket/base
;; session-trace.rkt — the CapTP facts a netlayer can see at the wire, reported
;; to a session-trace sink.
;;
;; Goblins hands a netlayer the pair of procedures one connection's CapTP reads
;; and writes messages with, and the netlayer may wrap them. Wrapping is the only
;; place a netlayer can watch the two `op:start-session` records that open a
;; session and the end of the stream that closes it, so it is the only place a
;; session can be named the way both of its ends name it: each end's session key
;; travels in its own record, and the two keys are the whole of the Session ID.
;;
;; Every netlayer in this directory reports the same facts, so the wrapper lives
;; here rather than once per transport. What differs between transports is what
;; the netlayer itself knows about the connection — its transport symbol, the
;; designator it is reached by, and what the far end proved — and those arrive as
;; arguments.

(require goblins/ocapn/structs-urls
         "ocapn-names.rkt")

(provide traced-message-procs
         provenance-unauthenticated
         provenance-authenticated-transport)

;; The two verdicts a netlayer in this directory can honestly reach about the
;; partner's durable name. They are the timeline schema's own words (pancake's
;; hosts publish the same ones from `partnerDurableProvenance`), so a viewer
;; folds a session watched from both ends into one edge with one verdict.
;;
;; `unauthenticated` is the answer when nothing proved a durable name: an address
;; designator names a route rather than a key, and a key nobody checked is a
;; claim. `authenticated-transport` is the answer when the layer that realized
;; the byte channel verified the far end holds the very key the partner's hello
;; claims, exactly what a QUIC connection to a dialed endpoint id proves.
(define provenance-unauthenticated "unauthenticated")
(define provenance-authenticated-transport "authenticated-transport")

;; The version, session key and claimed location an `op:start-session` carries,
;; or #f for any other record.
;;
;; `op:start-session` is private to Goblins's CapTP, so there is no accessor to
;; import; its struct is transparent and its fields are read positionally, in
;; the order the record declares them: the CapTP version, the session key as the
;; gcrypt s-expression the wire carried, the location the far end claims, and
;; the signature over that location. A record of any other shape answers #f, so
;; a peer whose CapTP declares something else here is traced as a session that
;; never opened rather than misread.
(define (start-session-parts msg)
  (define fields (struct->vector msg))
  (and (eq? (vector-ref fields 0) 'struct:op:start-session)
       (= (vector-length fields) 5)
       (list (vector-ref fields 1)
             (vector-ref fields 2)
             (vector-ref fields 3))))

;; Wrap one connection's message procs so `sink` hears the session open and
;; close. Answers the wrapped `(values read-message write-message)`.
;;
;;   `transport`       — the locator transport symbol this connection rides.
;;   `our-designator`  — what a partner reaching this end names it by.
;;   `provenance`      — what the netlayer proved about the far end, asked with
;;                       the designator the partner's hello claims. A netlayer
;;                       that dialed an endpoint id can answer
;;                       `authenticated-transport` when the claim names the
;;                       endpoint the channel is encrypted to; one that proved
;;                       nothing answers `unauthenticated`.
;;
;; CapTP reads and writes on two separate threads, so the two halves below run
;; concurrently and the semaphore is what makes "both keys are in, report once"
;; one decision. A sink that raises is swallowed: telemetry does not get to break
;; the session it is watching.
(define (traced-message-procs read-message write-message sink
                              #:transport transport
                              #:our-designator our-designator
                              #:provenance provenance)
  (define handle (gensym 'captp-session))
  (define lock (make-semaphore 1))
  (define our-key #f)
  (define their-key #f)
  (define partner-designator #f)
  (define captp-version #f)
  (define reported #f)
  (define finished #f)

  (define (tell event info)
    (with-handlers ([exn:fail? void]) (sink event handle info)))

  (define (report-open!)
    (when (and our-key their-key (not reported))
      (set! reported #t)
      (define claimed (or partner-designator ""))
      (tell 'open
            (hasheq 'transport transport
                    'our-designator our-designator
                    'partner-designator claimed
                    'session-id (session-id-hex our-key their-key)
                    'captp-version (or captp-version "")
                    ;; A Goblins vat's CapTP messages are Syrup, and the vat
                    ;; speaks the OCapN v1.0 baseline.
                    'codec "syrup"
                    'durable-provenance (provenance claimed)))))

  (define (report-close!)
    (when (and reported (not finished))
      (set! finished #t)
      (tell 'close #f)))

  (values
   (lambda (unmarshallers)
     (define msg
       (with-handlers ([exn? (lambda (e)
                              (call-with-semaphore lock report-close!)
                              (raise e))])
         (read-message unmarshallers)))
     (cond
       [(eof-object? msg)
        (call-with-semaphore lock report-close!)
        msg]
       [else
        (define parts (start-session-parts msg))
        (when parts
          (call-with-semaphore
           lock
           (lambda ()
             (set! captp-version (car parts))
             (set! their-key (cadr parts))
             (define claimed (caddr parts))
             (when (ocapn-node? claimed)
               (set! partner-designator (ocapn-node-designator claimed)))
             (report-open!))))
        msg]))
   (lambda (msg marshallers)
     (define parts (start-session-parts msg))
     (when parts
       (call-with-semaphore
        lock
        (lambda ()
          (set! our-key (cadr parts))
          (report-open!))))
     (write-message msg marshallers))))

(module+ test
  (require rackunit
           racket/match)

  ;; `op:start-session` is private to Goblins. The trace reads its transparent
  ;; wire shape, so this local struct gives the test that same shape without
  ;; reaching through Goblins's private module boundary.
  (struct op:start-session (version key location signature) #:transparent)

  (define ours '(public-key ours))
  (define theirs '(public-key theirs))
  (define location (ocapn-node 'iroh "partner" #f))
  (define incoming
    (box (list (op:start-session "1.0" theirs location 'signature))))
  (define events '())
  (define-values (read-traced write-traced)
    (traced-message-procs
     (lambda (_unmarshallers)
       (match (unbox incoming)
         ['() (error 'read-message "stream ended")]
         [(cons msg rest) (set-box! incoming rest) msg]))
     (lambda (_msg _marshallers) (void))
     (lambda (event _handle _info) (set! events (append events (list event))))
     #:transport "iroh"
     #:our-designator "ours"
     #:provenance (lambda (_claimed) provenance-authenticated-transport)))

  (write-traced (op:start-session "1.0" ours location 'signature) #f)
  (check-true (op:start-session? (read-traced #f)))
  (check-equal? events '(open))
  (check-exn #rx"stream ended" (lambda () (read-traced #f)))
  (check-equal? events '(open close))
  ;; A second observation of the same terminal stream is still one close.
  (check-exn #rx"stream ended" (lambda () (read-traced #f)))
  (check-equal? events '(open close)))
