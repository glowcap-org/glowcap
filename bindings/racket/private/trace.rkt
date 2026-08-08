#lang racket/base
;; The live timeline producer: a veneer over the native tap. The core is the
;; one owner of the facts — `pancake_host_set_trace` reports every session's
;; open (with the partner's designator, the wire name both peers of the
;; session derive, whether a durable identity verified the name, and the codec
;; the handshake actually negotiated), every
;; message's verb in both directions, and every close. This veneer only
;; stamps time and forwards one flat record per fact in the versioned
;; timeline schema; even endpoint labeling belongs to the consumer (ocapnviz
;; resolves src/dst from the session-opened it already saw), so nothing here
;; keeps per-session state.
;;
;; Off by default and zero-cost when off: with no sink installed nothing is
;; registered with the core, so its emit sites are one null check.
;;
;; Times are `sim_t_ns` per the schema, measured from the sink's install
;; moment, so a viewer's timeline starts near zero.

(require ffi/unsafe
         net/base64
         "constants.rkt"
         "ffi-host.rkt"
         "ffi-shared.rkt")

(provide enable-trace!
         trace-annotate-session!
         trace-attach-host!
         trace-detach-host!)

(define sink (box #f))
;; The display label the application chose for its own endpoint, or #f. The `a`
;; endpoint itself is always the host's own key designator — what a partner
;; names it by, so one peer stays one node in a feed several producers share.
(define self-label (box #f))
;; What this producer answers when a record asks what it runs. A constant and
;; not an option: the host behind this binding is a pancake host, and an
;; application naming itself something else would put a claim on the wire that
;; nothing here could stand behind. It is stated rather than left implicit
;; because this schema is not pancake's alone — the Goblins conformance peer
;; publishes the same records — so a consumer cannot read an implementation off
;; the fact that a record arrived, and a host that says nothing is honestly
;; unknown to it. Each of the four bindings states the word itself, because it
;; is a claim about the binding tier rather than a fact the core or the C ABI
;; carries, so there is no declaration to generate it from. `zig build
;; meta-check` (`checkTraceViewerVocabulary`) holds all four against each other,
;; against the viewer that reads them, and against the Goblins publisher, which
;; states a different word and must keep stating it.
(define self-profile "pancake")
(define t0 (box 0))
;; Every live host's raw pointer paired with its cookie and its own key
;; designator. The cookie is the small integer passed as the callback ctx so a
;; record can carry which host it came from: a core session id is host-scoped
;; (the Names rule: a bare id needs its namespace named), so two hosts in one
;; process would otherwise collide on the same session row.
(define hosts (box '())) ; list of (ptr cookie . designator)
(define next-cookie (box 1))
;; The one native callback closure, boxed for the process's life so the
;; collector never reclaims a pointer the core still holds.
(define native-cb (box #f))
;; Payload bytes forwarded per message (whole frame under the cap, head +
;; true length above it). The TypeScript veneer exposes this as an
;; `enableTrace` option; make it configurable here when a consumer asks.
(define PAYLOAD-CAP 4096)

(define (now-ns)
  (inexact->exact
   (round (* 1000000 (- (current-inexact-monotonic-milliseconds) (unbox t0))))))

(define (codec<-abi codec)
  (cond
    [(= codec CODEC-CAPNP) "capnp"]
    [(= codec CODEC-SYRUP) "syrup"]
    [else "unknown"]))

(define (captp-version<-abi version)
  (cond
    [(= version CAPTP-NEXT) "pancake-next"]
    [(= version CAPTP-V1-0) "1.0"]
    [else "unknown"]))

(define (emit! ev)
  (define s (unbox sink))
  (when s (s ev)))

(define (view->string ptr len)
  (if (and ptr (> len 0))
      (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)
      #f))

(define (on-native-event ctx ev)
  (when (unbox sink)
    (define cookie (if ctx (cast ctx _pointer _intptr) 0))
    (define session-id
      (format "live-h~a-s~a" cookie (PancakeTraceEvent-session ev)))
    (define kind (PancakeTraceEvent-kind ev))
    (define (endpoint-a)
      (let ([row (findf (lambda (r) (= (cadr r) cookie)) (unbox hosts))])
        (if row (cddr row) "")))
    (cond
      [(= kind TRACE-SESSION-OPEN)
       ;; The OCapN Session ID, the one name both ends of this session
       ;; derive. Absent when the partner sent no session key.
       (define session-id-value (view->string (PancakeTraceEvent-session-id ev)
                                              (PancakeTraceEvent-session-id-len ev)))
       ;; The partner locator's OCapN Transport. Left out when the open
       ;; carried none, the way `session_id` and `op` are: a record says what
       ;; it knows, and an empty string is a third spelling of "nothing" that
       ;; every consumer would then have to know about.
       (define transport (view->string (PancakeTraceEvent-transport ev)
                                       (PancakeTraceEvent-transport-len ev)))
       (define open-record
         (hasheq 'v 1 'sim_t_ns (now-ns) 'kind "ocapn.session-opened"
                 'session session-id
                 'a (endpoint-a)
                 'a_profile self-profile
                 'b (or (view->string (PancakeTraceEvent-designator ev)
                                      (PancakeTraceEvent-designator-len ev))
                        "peer")
                 'codec (codec<-abi (PancakeTraceEvent-codec ev))
                 'captp_version (captp-version<-abi
                                  (PancakeTraceEvent-captp-version ev))
                 'provenance (symbol->string
                              (provenance<-abi (PancakeTraceEvent-provenance ev)))))
       (define carried
         (if transport (hash-set open-record 'transport transport) open-record))
       (define labelled
         (if (unbox self-label)
             (hash-set carried 'a_label (unbox self-label))
             carried))
       (emit! (if session-id-value
                  (hash-set labelled 'session_id session-id-value)
                  labelled))]
      [(= kind TRACE-MESSAGE)
       (define op (view->string (PancakeTraceEvent-verb ev)
                                (PancakeTraceEvent-verb-len ev)))
       ;; The frame is borrowed for this call, so the payload copy happens
       ;; here or never: whole frame under the cap, head + true length
       ;; above it.
       (define frame-ptr (PancakeTraceEvent-frame ev))
       (define frame-len (PancakeTraceEvent-frame-len ev))
       (define frame-total-len
         (let ([n (PancakeTraceEvent-frame-total-len ev)])
           (if (zero? n) frame-len n)))
       (define (b64 n)
         (bytes->string/latin-1
          (base64-encode (bytes<-c frame-ptr n) #"")))
       ;; A tag over the frame's bytes, naming this one message across the two
       ;; peers that carried it: both ends hold the same bytes, so both derive
       ;; the same tag and a consumer watching from both ends draws one message
       ;; rather than two.
       (define digest
         (apply string-append
                (for/list ([i (in-range TRACE-DIGEST-BYTES)])
                  (define h (number->string (array-ref (PancakeTraceEvent-digest ev) i) 16))
                  (if (= 1 (string-length h)) (string-append "0" h) h))))
       (emit! (let* ([base (hasheq 'v 1 'sim_t_ns (now-ns)
                                   'kind "ocapn.message-decoded"
                                   'session session-id
                                   'digest digest
                                   'outbound (not (zero? (PancakeTraceEvent-outbound ev))))]
                     [base (if op (hash-set base 'op op) base)])
                (cond
                  [(zero? frame-total-len) base]
                  [(or (not frame-ptr) (zero? frame-len))
                   (hash-set base 'len frame-total-len)]
                  [(and (<= frame-total-len PAYLOAD-CAP)
                        (>= frame-len frame-total-len))
                   (hash-set (hash-set base 'len frame-total-len)
                             'bytes_b64 (b64 frame-total-len))]
                  [else
                   (hash-set (hash-set base 'len frame-total-len)
                             'summary
                             (hasheq 'len frame-total-len
                                     'head_b64 (b64 (min frame-len PAYLOAD-CAP))))])))]
      [(= kind TRACE-SESSION-CLOSE)
       (emit! (hasheq 'v 1 'sim_t_ns (now-ns) 'kind "ocapn.session-closed"
                      'session session-id))])))

;; The SET half of the annotation channel: an application states which
;; partner a session carries, named for the same session row the tap
;; names. A claim, never identity. Raw pointers because this module
;; sits below the session structs (host.rkt requires it); the
;; session-level verb wraps the accessors. No sink, or a host the
;; trace never attached: silently nothing, like every trace emit.
(define (trace-annotate-session! hptr conn-ptr label)
  (when (unbox sink)
    (define row (assq hptr (unbox hosts)))
    (when row
      (define-values (rc id) (pancake_host_session_trace_id conn-ptr))
      (when (zero? rc)
        (emit! (hasheq 'v 1 'sim_t_ns (now-ns)
                       'kind "ocapn.session-meta"
                       'session (format "live-h~a-s~a" (cadr row) id)
                       'meta (hasheq 'label label)))))))

(define (callback!)
  (unless (unbox native-cb) (set-box! native-cb on-native-event))
  (unbox native-cb))

(define (cookie->ctx cookie) (cast cookie _intptr _pointer))

;; Install `next` (replacing any prior sink), start the clock, and register
;; the native tap on every live host (a host minted later registers itself).
;; Returns an uninstall thunk that also clears the native tap.
(define (enable-trace! next #:self-label [label #f])
  (set-box! sink next)
  (set-box! self-label label)
  (set-box! t0 (current-inexact-monotonic-milliseconds))
  (for ([row (in-list (unbox hosts))])
    (pancake_host_set_trace (car row) (callback!) (cookie->ctx (cadr row))))
  (lambda ()
    (when (eq? (unbox sink) next)
      (set-box! sink #f)
      (for ([row (in-list (unbox hosts))])
        (pancake_host_set_trace (car row) #f #f)))))

;; Binding-internal: a host reports its raw pointer and its own key designator
;; at mint so an installed trace covers it, and a trace installed later finds
;; it.
(define (trace-attach-host! ptr [designator ""])
  (define cookie (unbox next-cookie))
  (set-box! next-cookie (add1 cookie))
  (set-box! hosts (cons (list* ptr cookie designator) (unbox hosts)))
  (when (unbox sink)
    (pancake_host_set_trace ptr (callback!) (cookie->ctx cookie))))

;; Binding-internal: a released host leaves the registry. The core dropped
;; its own sink row with the host, so no native call is needed.
(define (trace-detach-host! ptr)
  (set-box! hosts (filter (lambda (row) (not (eq? (car row) ptr)))
                          (unbox hosts))))
