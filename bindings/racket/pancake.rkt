#lang racket/base
;; Idiomatic Racket API for pancake — an OCapN/CapTP peer you drive.
;;
;; The raw `ffi/unsafe` layer lives in the internal `private/ffi-core.rkt` module; this
;; module is just the public surface over it. What you use is a `peer`
;; you create and release, native Racket values as arguments (exact integers,
;; flonums, booleans, bytes, strings, symbols, references, lists), and event
;; structs out of `peer-poll`. The default peer negotiates an authenticated
;; session; raw direct-frame fixtures use `make-peer/raw-open`.
;;
;;   (define p (make-peer/raw-open))
;;   (peer-register-import! p 5)
;;   (peer-send-deliver! p (far 5) (list 42 #"hi") #:answer 9)
;;   (peer-step! p)
;;   (peer-take-outbound p)

(require ffi/unsafe
         racket/runtime-path
         racket/tcp
         racket/async-channel
         racket/random
         "private/constants.rkt"
         "private/ffi-core.rkt"
         (for-syntax racket/base))

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out deliver-event) (struct-out resolve-event) (struct-out other-event)
         (struct-out fulfill) (struct-out brk) (struct-out handoff)
         abi-version last-error clear-last-error
         make-context make-context/allocator context-release!
         make-peer make-peer/in make-peer/raw-open make-peer/raw-open/in peer-release!
         peer-register-export! peer-next-export! peer-register-import!
         peer-next-answer! peer-codec peer-send-bootstrap-fetch! peer-send-withdraw-gift!
         peer-send-gc-export! peer-send-gc-answer!
         peer-start-session! peer-session-open?
         peer-feed! peer-feed-owned! peer-step! peer-step-to-idle! peer-send-deliver! peer-send-resolve!
         peer-send-get! peer-send-index! peer-send-untag!
         peer-take-outbound peer-poll peer-recv-stream!
         peer-last-abort (struct-out abort-info)
         exn:fail:pancake? exn:fail:pancake-code exn:fail:pancake-abort
         (struct-out async-connection)
         async-connect async-connection/ports
         async-send-deliver! async-send-resolve! async-next-event async-flush!
         in-async-events)

;; ── iroh transport ───────────────────────────────────────────────────────────
;; iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
;; out of the pure-Zig archives; it ships as its own optional companion library
;; (libpancake_net_transport_iroh, `zig build iroh-abi`, needs cargo). Mirroring that artifact
;; split, the iroh binding lives in the `pancake-iroh.rkt` companion, which builds
;; an `async-transport` over the iroh ABI through the netlayer seam below. `connect`
;; loads it lazily on the first iroh locator, so a Racket program (and the TCP
;; dogfood) that never touches iroh needs neither the companion nor the library.
(define-runtime-path iroh-companion-path "pancake-iroh.rkt")

;; ── Library identity and per-thread last error ───────────────────────────────
;; (abi-version) -> (values major minor patch) of the linked library.
(define (abi-version) (pancake_abi_version))

;; (last-error) -> the calling thread's last error message as a string, or #f
;; when there is none. Query the length first (NULL buffer), then read.
(define (last-error)
  (define len (pancake_last_error #f 0))
  (cond
    [(zero? len) #f]
    [else
     ;; The C side reserves one byte for a NUL and copies at most cap-1 message
     ;; bytes, so allocate len + 1 to receive all `len` of them.
     (define buf (make-bytes (+ len 1)))
     (define written (pancake_last_error buf (+ len 1)))
     (bytes->string/utf-8 (subbytes buf 0 (min written len)) #\uFFFD)]))

(define (clear-last-error) (pancake_clear_last_error))

;; ── Public value vocabulary ──────────────────────────────────────────────────
;; A pancake failure carries the flat PANCAKE_ERR_* `code` that names the
;; failure family, plus — when the failure was a refused inbound frame — an
;; `abort-info` naming the member (see `peer-last-abort`); `abort` is #f
;; everywhere else.
(struct exn:fail:pancake exn:fail (code abort))

;; Raise a typed pancake failure for a non-OK `code`, reading the human-readable
;; cause through `read-error` (a thunk that returns the message string or #f).
;; Each transport archive keeps its own thread-local last-error slot, so a
;; transport module passes its own reader here; `check` is the ocapn-family
;; spelling that reads `pancake_last_error`. The seam below provides `check-with`
;; so `pancake-tcp.rkt` / `pancake-inproc.rkt` raise the same typed exn from
;; their own diagnostics.
(define (check-with code read-error)
  (unless (= code OK)
    (define msg (read-error))   ; capture immediately, before any later call clobbers it
    (raise (exn:fail:pancake
            (if msg
                (format "pancake error ~a: ~a" code msg)
                (format "pancake error ~a" code))
            (current-continuation-marks) code #f))))

(define (check code) (check-with code last-error))

;; Like `check`, but for the calls that feed inbound wire bytes to a peer: on
;; failure, read the peer's typed last-abort detail and attach it to the raised
;; exn, so a refused frame is diagnosable without reading Zig.
(define (check/abort p code)
  (unless (= code OK)
    (define msg (last-error))   ; capture before peer-last-abort can clobber it
    (define abort (peer-last-abort p))
    (define base
      (if msg
          (format "pancake error ~a: ~a" code msg)
          (format "pancake error ~a" code)))
    (raise (exn:fail:pancake
            (if abort
                (format "~a [~a~a: ~a]" base (abort-info-domain abort)
                        (if (abort-info-kind abort) (format " ~a" (abort-info-kind abort)) "")
                        (abort-info-message abort))
                base)
            (current-continuation-marks) code abort))))

;; A typed application-level failure (a partner break, a fetch that did not
;; yield a capability): same exn family, no abort detail.
(define (raise-pancake who code fmt . args)
  (raise (exn:fail:pancake (format "~a: ~a" who (apply format fmt args))
                           (current-continuation-marks) code #f)))

(struct near-ref (id promise) #:transparent)   ; a local export this peer hosts
(struct far-ref (id promise) #:transparent)    ; a partner-hosted import this peer holds
(struct promise-ref (answer) #:transparent)
(struct sturdy () #:transparent)
(struct broken () #:transparent)
(struct sym (value) #:transparent)             ; tag a string as an OCapN symbol
(struct kw (value) #:transparent)              ; an OCapN keyword
(struct pset (items) #:transparent)             ; an OCapN set
(struct tagged-arg (tag value) #:transparent)   ; an OCapN tagged record

(struct deliver-event (target args answer) #:transparent)
(struct resolve-event (answer resolution) #:transparent)
(struct other-event (kind frame) #:transparent)
(struct fulfill (value) #:transparent)
(struct brk (message) #:transparent)
;; A poll-only resolution: the answer settled to a three-party handoff give the
;; recipient must redeem against the named exporter (ADR-0009/ADR-0056). `give`
;; is the verbatim signed `desc:handoff-give` bytes, `exporter-locator` the
;; exporter's dialable `ocapn://` URI (or "" when the give names no flat
;; locator), `recipient-key` the 32-byte key the give is addressed to. The
;; high-level connection redeems this transparently in its pump loop, so an
;; application driving the connection never sees it.
(struct handoff (give exporter-locator recipient-key) #:transparent)

;; The typed cause of a peer's most recent refused frame, read back through
;; `peer-last-abort`. `domain` is 'codec, 'session, or 'foreign; `kind` is the
;; wire name of the projected op:abort kind, or #f when none was projected;
;; `message` is the static diagnostic and `error-name` the originating error.
(struct abort-info (domain kind message error-name) #:transparent)

;; near/far take an optional promise? flag.
(define (near id [promise #f]) (near-ref id promise))
(define (far id [promise #f]) (far-ref id promise))

;; ── Marshalling (encode) ─────────────────────────────────────────────────────
(define (ref->c ref)
  (cond
    [(near-ref? ref) (make-PancakeReference REF-NEAR (if (near-ref-promise ref) REF-PROMISE-KIND REF-OBJECT) (near-ref-id ref))]
    [(far-ref? ref) (make-PancakeReference REF-FAR (if (far-ref-promise ref) REF-PROMISE-KIND REF-OBJECT) (far-ref-id ref))]
    [(promise-ref? ref) (make-PancakeReference REF-PROMISE 0 (promise-ref-answer ref))]
    [else (check ERR-UNSUPPORTED-VALUE) (error "unreachable")]))

;; Returns (values cpointer count), keeping backing buffers alive via `keep`.
(define (args->c args keep)
  (define n (length args))
  (cond
    [(zero? n) (values #f 0)]
    [else
     (define arr (malloc (* n (ctype-sizeof _PancakeArgument)) 'atomic-interior))
     (set-box! keep (cons arr (unbox keep)))
     (for ([a (in-list args)] [i (in-naturals)])
       (ptr-set! arr _PancakeArgument i (arg->c a keep)))
     (values arr n)]))

(define (bytes->c-ptr bs keep)
  (define n (bytes-length bs))
  (define buf (malloc (max n 1) 'atomic-interior))
  (set-box! keep (cons buf (unbox keep)))
  (memcpy buf bs n)
  (values buf n))

(define (arg->c a keep)
  (define c (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0))
  (cond
    [(boolean? a) (set-PancakeArgument-kind! c ARG-BOOLEAN) (set-PancakeArgument-boolean! c (if a 1 0))]
    ;; The C integer field is i64; a Racket bignum outside that range rides
    ;; ARG-BIG-INTEGER as canonical decimal digits plus a sign flag (ADR-0049).
    [(exact-integer? a)
     (if (and (>= a (- (expt 2 63))) (< a (expt 2 63)))
         (begin (set-PancakeArgument-kind! c ARG-INTEGER) (set-PancakeArgument-integer! c a))
         (begin (set-bytes-field! c ARG-BIG-INTEGER (string->bytes/utf-8 (number->string (abs a))) keep)
                (set-PancakeArgument-boolean! c (if (negative? a) 1 0))))]
    ;; Only an *inexact* real marshals as float64; an exact rational (e.g. 1/3)
    ;; would be silently lossy, so it falls through to the unsupported-value
    ;; refusal below instead.
    [(and (real? a) (inexact? a)) (set-PancakeArgument-kind! c ARG-FLOAT64) (set-PancakeArgument-float64! c a)]
    [(sym? a) (set-bytes-field! c ARG-SYMBOL (string->bytes/utf-8 (sym-value a)) keep)]
    [(symbol? a) (set-bytes-field! c ARG-SYMBOL (string->bytes/utf-8 (symbol->string a)) keep)]
    [(string? a) (set-bytes-field! c ARG-STRING (string->bytes/utf-8 a) keep)]
    [(bytes? a) (set-bytes-field! c ARG-BYTES a keep)]
    [(void? a) (set-PancakeArgument-kind! c ARG-VOID)]
    [(or (near-ref? a) (far-ref? a) (promise-ref? a)) (set-PancakeArgument-kind! c ARG-REFERENCE) (set-PancakeArgument-reference! c (ref->c a))]
    [(kw? a) (set-bytes-field! c ARG-KEYWORD (string->bytes/utf-8 (kw-value a)) keep)]
    [(tagged-arg? a) (set-bytes-field! c ARG-TAGGED (string->bytes/utf-8 (tagged-arg-tag a)) keep)
                     (define-values (ptr cnt) (args->c (tagged-arg-value a) keep))
                     (set-PancakeArgument-items! c ptr) (set-PancakeArgument-items-len! c cnt)]
    [(pset? a) (set-PancakeArgument-kind! c ARG-SET)
               (define-values (ptr cnt) (args->c (pset-items a) keep))
               (set-PancakeArgument-items! c ptr) (set-PancakeArgument-items-len! c cnt)]
    [(list? a) (set-PancakeArgument-kind! c ARG-LIST)
               (define-values (ptr cnt) (args->c a keep))
               (set-PancakeArgument-items! c ptr) (set-PancakeArgument-items-len! c cnt)]
    [else (check ERR-UNSUPPORTED-VALUE)])
  c)

(define (set-bytes-field! c kind bs keep)
  (define-values (buf n) (bytes->c-ptr bs keep))
  (set-PancakeArgument-kind! c kind)
  (set-PancakeArgument-bytes! c buf)
  (set-PancakeArgument-bytes-len! c n))

;; ── Marshalling (decode) ─────────────────────────────────────────────────────
(define (ref<-c r)
  (define promise? (= (PancakeReference-sub-kind r) REF-PROMISE-KIND))
  (define k (PancakeReference-kind r))
  (cond
    [(= k REF-NEAR) (near (PancakeReference-id r) promise?)]
    [(= k REF-FAR) (far (PancakeReference-id r) promise?)]
    [(= k REF-PROMISE) (promise-ref (PancakeReference-id r))]
    [(= k REF-STURDY) (sturdy)]
    [else (broken)]))

(define (bytes<-c ptr len)
  (if (or (not ptr) (zero? len)) #""
      (let ([bs (make-bytes len)]) (memcpy bs ptr len) bs)))

(define (arg<-c c)
  (define k (PancakeArgument-kind c))
  (cond
    [(= k ARG-INTEGER) (PancakeArgument-integer c)]
    [(= k ARG-FLOAT64) (PancakeArgument-float64 c)]
    [(= k ARG-BOOLEAN) (not (zero? (PancakeArgument-boolean c)))]
    [(= k ARG-BYTES) (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))]
    [(= k ARG-STRING) (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) #\uFFFD)]
    [(= k ARG-SYMBOL) (sym (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) #\uFFFD))]
    [(= k ARG-REFERENCE) (ref<-c (PancakeArgument-reference c))]
    [(= k ARG-LIST) (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c))]
    [(= k ARG-SET) (pset (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-TAGGED) (tagged-arg (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) #\uFFFD)
                                  (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-KEYWORD) (kw (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) #\uFFFD))]
    [(= k ARG-VOID) (void)]
    ;; Canonical decimal digits + sign flag back to a native bignum (ADR-0049).
    [(= k ARG-BIG-INTEGER)
     (let ([magnitude (string->number (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))))])
       (if (not (zero? (PancakeArgument-boolean c))) (- magnitude) magnitude))]
    [else (error 'arg<-c "unrecognized argument kind: ~a" k)]))

(define (args<-c ptr len)
  (if (or (not ptr) (zero? len)) '()
      (for/list ([i (in-range len)]) (arg<-c (ptr-ref ptr _PancakeArgument i)))))

;; ── The allocation context ───────────────────────────────────────────────────
;; A context owns allocation policy for the handles created in it. Peers and
;; netlayers made with `make-peer/in` / `make-netlayer/in` route every
;; allocation through it, so the context must outlive them. `keep` retains the
;; callback closures for the custom-allocator path — the cstruct alone holds
;; only raw C function pointers, which keep nothing reachable on the Racket
;; side, so without this the trampolines are collectable the moment the
;; constructor returns and the library's next allocation calls freed code. It
;; is #f for the default path.
(struct context (handle keep) #:mutable)

(define (make-context)
  (define-values (rc h) (pancake_context_new))
  (check rc)
  (define ctx (context h #f))
  (register-finalizer ctx (lambda (q) (context-release! q)))
  ctx)

;; alloc-proc : (-> size alignment pointer)  free-proc : (-> pointer size alignment void)
(define (make-context/allocator alloc-proc free-proc)
  ;; Wrap the host procedures as C-callable trampolines that ignore user-data.
  (define alloc-cb (lambda (ud size alignment) (alloc-proc size alignment)))
  (define free-cb  (lambda (ud ptr size alignment) (free-proc ptr size alignment)))
  (define allocator (make-PancakeAllocator alloc-cb free-cb #f))
  (define-values (rc h) (pancake_context_new_with_allocator allocator))
  (check rc)
  ;; Retain the closures themselves, not just the cstruct: the struct fields
  ;; are raw C pointers, and a trampoline stays alive only while its Racket
  ;; procedure does.
  (define ctx (context h (vector allocator alloc-cb free-cb)))
  (register-finalizer ctx (lambda (q) (context-release! q)))
  ctx)

(define (context-release! ctx)
  (when (context-handle ctx)
    ;; Release order matters: the context frees its tables through the
    ;; allocator first, then we drop the retained callbacks.
    (pancake_context_release (context-handle ctx))
    (set-context-handle! ctx #f)
    (set-context-keep! ctx #f)))

;; ── The peer ─────────────────────────────────────────────────────────────────
(struct peer (handle) #:mutable)

(define (profile-id version)
  (case version
    [(v1.0) CAPTP-VERSION-V1-0]
    [(pre-spec) CAPTP-VERSION-PRE-SPEC]
    [else (error 'profile-id "unknown OCapN profile: ~a" version)]))

(define (codec-id codec)
  (case codec
    [(syrup) CODEC-SYRUP]
    [(capnp) CODEC-CAPNP]
    [else (error 'codec-id "unknown OCapN codec: ~a" codec)]))

;; A default peer starts in the authenticated v1.0 negotiating state over
;; Syrup. Pass #:version 'pre-spec for the upstream OCapN prerelease profile,
;; or #:codec 'capnp for a Cap'n Proto session (both ends must agree, and the
;; connection's endpoint must frame with the same codec). Pair it with
;; `peer-start-session!`, pump frames, then wait for `peer-session-open?` before
;; application traffic.
(define (make-peer #:version [version 'v1.0] #:codec [codec 'syrup])
  (define-values (rc h)
    (if (and (eq? version 'v1.0) (eq? codec 'syrup))
        (pancake_peer_new)
        (pancake_peer_new_negotiated (profile-id version) (codec-id codec))))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

(define (make-peer/in ctx #:version [version 'v1.0] #:codec [codec 'syrup])
  (define-values (rc h)
    (if (and (eq? version 'v1.0) (eq? codec 'syrup))
        (pancake_peer_new_in (context-handle ctx))
        (pancake_peer_new_negotiated_in (context-handle ctx) (profile-id version) (codec-id codec))))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

;; Already-open peer for tests and low-level direct-frame fixtures.
(define (make-peer/raw-open)
  (define-values (rc h) (pancake_peer_new_raw_open))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

(define (make-peer/raw-open/in ctx)
  (define-values (rc h) (pancake_peer_new_raw_open_in (context-handle ctx)))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

(define (peer-release! p)
  (when (peer-handle p)
    (pancake_peer_release (peer-handle p))
    (set-peer-handle! p #f)))

(define (peer-register-export! p id) (check (pancake_peer_register_export (peer-handle p) id)))
;; Allocate and register the next free export position from the session's one
;; export allocator — the counter that also mints bootstrap and resolver
;; exports, so a spawned position can never alias one.
(define (peer-next-export! p)
  (define-values (rc id) (pancake_peer_next_export (peer-handle p)))
  (check rc)
  id)
(define (peer-register-import! p id) (check (pancake_peer_register_import (peer-handle p) id)))
;; Allocate the next outbound answer position from the session's one answer
;; allocator — the counter that backs every outbound question, so a
;; privately-counted answer can never alias a live one.
(define (peer-next-answer! p)
  (define-values (rc answer) (pancake_peer_next_answer (peer-handle p)))
  (check rc)
  answer)

;; The codec the peer's session speaks (a CODEC-* value), so an opaque
;; other-event frame drained after a typed-poll refusal can be interpreted.
(define (peer-codec p)
  (define-values (rc codec) (pancake_peer_codec (peer-handle p)))
  (check rc)
  codec)

;; Queue the canonical bootstrap `fetch` for the capability published behind
;; `name` (a bytestring), returning the answer position the partner's
;; resolution arrives on (as a resolve-event). Registers the bootstrap import
;; and allocates the answer from the session's own counters.
(define (peer-send-bootstrap-fetch! p name)
  (define buf (malloc (max (bytes-length name) 1) 'atomic-interior))
  (memcpy buf name (bytes-length name))
  (define-values (rc answer)
    (pancake_peer_send_bootstrap_fetch (peer-handle p) buf (bytes-length name)))
  (check rc)
  answer)

;; Begin enlivening the sturdyref published behind `swissnum` (a bytestring;
;; ADR-0012): the requester half over bootstrap-fetch with the dedup cache.
;; Returns the `_PancakeEnlivenStart` struct — a status (ENLIVEN-FRESH /
;; ENLIVEN-CACHED / ENLIVEN-IN-FLIGHT) plus the answer to drive or the cached far
;; reference's import position and kind. Requires an open sturdyref-capable session.
(define (peer-prepare-enliven! p swissnum)
  (define buf (malloc (max (bytes-length swissnum) 1) 'atomic-interior))
  (memcpy buf swissnum (bytes-length swissnum))
  (define out (make-PancakeEnlivenStart 0 0 0 0))
  (check (pancake_peer_prepare_enliven (peer-handle p) buf (bytes-length swissnum) out))
  out)

;; Settle a fresh enliven once its bootstrap-fetch resolution arrives (ADR-0012):
;; cache the fulfilled far reference (`import-position`/`kind`, an ENLIVEN-OUTCOME-*
;; outcome) under `swissnum` so a repeat short-circuits, or clear the in-flight
;; marker on a break.
(define (peer-record-enlivenment! p swissnum outcome import-position kind)
  (define buf (malloc (max (bytes-length swissnum) 1) 'atomic-interior))
  (memcpy buf swissnum (bytes-length swissnum))
  (check (pancake_peer_record_enlivenment
          (peer-handle p) buf (bytes-length swissnum) outcome import-position kind)))

;; Recipient half of a three-party handoff (ADR-0009/ADR-0056): sign a
;; `desc:handoff-receive` over the verbatim `give` bytes (keyed by the 32-byte
;; `seed`) and queue a `withdraw-gift` deliver to the exporter's bootstrap under
;; `answer`. Requires an open keyed session to the exporter opened with this same
;; `seed` — that session key is what the exporter verifies the receive against.
;; `count` is the number of prior withdrawals from this exporter session (0 for
;; the first, rising monotonically), which the exporter requires to increase.
(define (peer-send-withdraw-gift! p give seed count answer)
  (unless (= (bytes-length seed) 32) (error 'peer-send-withdraw-gift! "seed must be 32 bytes"))
  (define gbuf (malloc (max (bytes-length give) 1) 'atomic-interior))
  (memcpy gbuf give (bytes-length give))
  (define sbuf (malloc 32 'atomic-interior))
  (memcpy sbuf seed 32)
  (check (pancake_peer_send_withdraw_gift (peer-handle p) gbuf (bytes-length give) sbuf 32 count answer)))

;; ── Gifter (introducer) half of a three-party handoff (ADR-0009/ADR-0056) ─────
;; The partner's session public key from its op:start-session (#"" before the
;; handshake half arrives). A gifter reads it on the to-recipient session for the
;; give's recipient key, and on the to-exporter session for the gifter↔exporter
;; session name. Copied out of the borrowed view immediately.
(define (peer-partner-session-key p)
  (define-values (rc ptr len) (pancake_peer_partner_session_key (peer-handle p)))
  (check rc)
  (bytes<-c ptr len))

;; The partner's verbatim `<ocapn-peer …>` location-record bytes from its
;; op:start-session (#"" when none were captured). A gifter embeds these as the
;; give's exporter location so a peer comparing locations matches byte-for-byte.
;; Copied out of the borrowed view immediately.
(define (peer-partner-locator-raw p)
  (define-values (rc ptr len) (pancake_peer_partner_locator_raw (peer-handle p)))
  (check rc)
  (bytes<-c ptr len))

;; Deposit `gifted` with this (exporter) session: queue a fire-and-forget
;; `deposit-gift` deliver to the exporter's bootstrap carrying `gift-id` and the
;; gifted reference. `gifted` must be a reference the exporter exported to us, so
;; it re-encodes to that exporter's own export — exactly how `peer-send-deliver!`
;; encodes a target reference.
(define (peer-send-deposit-gift! p gift-id gifted)
  (define gbuf (malloc (max (bytes-length gift-id) 1) 'atomic-interior))
  (memcpy gbuf gift-id (bytes-length gift-id))
  (check (pancake_peer_send_deposit_gift (peer-handle p) gbuf (bytes-length gift-id) (ref->c gifted))))

;; Resolve `answer` (a question the recipient asked this gifter) with a signed
;; `desc:handoff-give`: queue an op:resolve whose fulfill carries `give` verbatim,
;; so the recipient redeems it transparently and reaches the exporter directly.
(define (peer-send-resolve-handoff-give! p answer give)
  (define gbuf (malloc (max (bytes-length give) 1) 'atomic-interior))
  (memcpy gbuf give (bytes-length give))
  (check (pancake_peer_send_resolve_handoff_give (peer-handle p) answer gbuf (bytes-length give))))

;; Bind `registry-ptr` (a raw gift-registry handle) as this peer's shared gift
;; registry before its handshake, so inbound deposit/withdraw resolve against the
;; node-wide table. The registry must outlive the peer. Binding-internal.
(define (peer-set-gift-registry! p registry-ptr)
  (check (pancake_peer_set_gift_registry (peer-handle p) registry-ptr)))

;; Author the signed `desc:handoff-give` a gifter returns to a recipient. `seed`
;; is the gifter's 32-byte identity (the key it presents on its session to the
;; exporter, which signs the give); `recipient-key` is the recipient's session
;; public key; `exporter-locator-raw` the exporter's verbatim location bytes
;; (from `peer-partner-locator-raw` on the gifter↔exporter session);
;; `exporter-session-key` the exporter's session public key; `gift-id` the
;; deposited gift's id. Returns owned give bytes (copied out; the library buffer
;; is released here).
(define (build-handoff-give seed recipient-key exporter-locator-raw exporter-session-key gift-id)
  (unless (= (bytes-length seed) 32) (error 'build-handoff-give "a gifter seed must be 32 bytes"))
  (define (pin bs)
    (define buf (malloc (max (bytes-length bs) 1) 'atomic-interior))
    (memcpy buf bs (bytes-length bs))
    buf)
  (define-values (rc ptr len)
    (pancake_build_handoff_give
     (pin seed) 32
     (pin recipient-key) (bytes-length recipient-key)
     (pin exporter-locator-raw) (bytes-length exporter-locator-raw)
     (pin exporter-session-key) (bytes-length exporter-session-key)
     (pin gift-id) (bytes-length gift-id)))
  (check rc)
  (define out (bytes<-c ptr len))
  (pancake_handoff_give_bytes_release ptr len)
  out)

;; A vat-scoped deposited-gift table a node shares across its peers (ADR-0056).
;; An exporter receives a gift's deposit on the gifter session and its withdraw
;; on the recipient's separate session; one registry bound on both peers is what
;; lets the second find what the first deposited. Borrowed by every peer it is
;; set on — free it last.
(struct gift-registry (ptr) #:mutable)

(define (make-gift-registry)
  (define-values (rc ptr) (pancake_gift_registry_new))
  (check rc)
  (gift-registry ptr))

(define (gift-registry-pointer gr) (gift-registry-ptr gr))

(define (gift-registry-free! gr)
  (when (gift-registry-ptr gr)
    (pancake_gift_registry_free (gift-registry-ptr gr))
    (set-gift-registry-ptr! gr #f)))

;; Queue an op:gc-export releasing wire-delta counts on imports this peer
;; holds: the i-th position is released by the i-th delta. The lists are
;; parallel and must be non-empty and the same length.
(define (peer-send-gc-export! p positions deltas)
  (unless (= (length positions) (length deltas))
    (error 'peer-send-gc-export! "positions and deltas must be the same length"))
  (define n (length positions))
  (define pos-buf (malloc (max (* 8 n) 1) 'atomic-interior))
  (define delta-buf (malloc (max (* 8 n) 1) 'atomic-interior))
  (for ([v (in-list positions)] [i (in-naturals)])
    (ptr-set! pos-buf _uint64 i v))
  (for ([v (in-list deltas)] [i (in-naturals)])
    (ptr-set! delta-buf _uint64 i v))
  (check (pancake_peer_send_gc_export (peer-handle p) pos-buf delta-buf n)))

;; Queue an op:gc-answer releasing an answer this peer no longer needs.
(define (peer-send-gc-answer! p answer)
  (check (pancake_peer_send_gc_answer (peer-handle p) answer)))

;; The typed cause of the peer's most recent local dispatch failure — the
;; counterpart of the Zig `Peer.lastAbort` — as an `abort-info`, or #f when no
;; failure has been recorded. The C views are process-static; we copy them into
;; Racket strings, so the result outlives any later peer call.
(define (peer-last-abort p)
  (define out (make-PancakeLastAbort 0 0 #f 0 #f 0 #f 0))
  (define rc (pancake_peer_last_abort (peer-handle p) out))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else
     (check rc)
     (define (str ptr len)
       (and ptr (positive? len) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))
     (abort-info
      (let ([domain (PancakeLastAbort-domain out)])
        (cond [(= domain ABORT-DOMAIN-CODEC) 'codec]
              [(= domain ABORT-DOMAIN-SESSION) 'session]
              [else 'foreign]))
      (and (not (zero? (PancakeLastAbort-has-kind out)))
           (str (PancakeLastAbort-kind-name out) (PancakeLastAbort-kind-name-len out)))
      (or (str (PancakeLastAbort-message out) (PancakeLastAbort-message-len out)) "")
      (or (str (PancakeLastAbort-error-name out) (PancakeLastAbort-error-name-len out)) ""))]))

;; Sign and queue op:start-session from a negotiating peer. The handshake
;; speaks the profile the peer was constructed with (`(make-peer #:version
;; 'pre-spec)` for upstream OCapN). `seed` is a 32-byte bytestring (the session
;; key); `transport`/`designator` form the locator the partner verifies — for a
;; Goblins partner, "tcp" with `hints-empty-false?` #t (Goblins emits the empty
;; hints as the boolean `#f`). Flush it, then pump until `peer-session-open?`.
(define (peer-start-session! p seed
                                   #:designator designator
                                   #:transport [transport "tcp"]
                                   #:hints-empty-false? [hints-empty-false? #t])
  (unless (= (bytes-length seed) 32)
    (error 'peer-start-session! "a session seed must be 32 bytes; got ~a" (bytes-length seed)))
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define tbuf (malloc (max (bytes-length tb) 1) 'atomic-interior)) (memcpy tbuf tb (bytes-length tb))
  (define dbuf (malloc (max (bytes-length db) 1) 'atomic-interior)) (memcpy dbuf db (bytes-length db))
  (define sbuf (malloc 32 'atomic-interior)) (memcpy sbuf seed 32)
  (check (pancake_peer_start_session
          (peer-handle p)
          tbuf (bytes-length tb)
          dbuf (bytes-length db)
          (if hints-empty-false? HINTS-EMPTY-FALSE HINTS-EMPTY-MAP)
          sbuf 32)))

;; Whether the authenticated handshake has completed and the session is open for traffic.
(define (peer-session-open? p)
  (define rc (pancake_peer_session_is_open (peer-handle p)))
  (when (< rc 0) (check rc))
  (= rc 1))

(define (peer-feed! p frame)
  (define buf (malloc (max (bytes-length frame) 1) 'atomic-interior))
  (memcpy buf frame (bytes-length frame))
  (check/abort p (pancake_peer_feed_borrowed (peer-handle p) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

;; Retain owned-frame release trampolines until the library invokes them (it
;; calls back exactly once). Keyed by the callback so we can drop it on release.
(define owned-frame-releases (make-hasheq))

;; The release function pointer type: void(*)(PancakeManagedFrame *frame).
(define _PancakeReleaseFn (_fun _PancakeManagedFrame-pointer -> _void))

;; Transfer a frame to the peer's inbound queue with owned bytes. We malloc a
;; raw C buffer, copy `bytes` in, and attach a release callback that frees the
;; buffer. On success the library owns the descriptor; on failure ownership
;; stays with us, so we free the buffer and drop the retained callback.
(define (peer-feed-owned! p bytes)
  (define len (bytes-length bytes))
  (define buf (malloc 'raw (max len 1)))
  (memcpy buf bytes len)
  (define release-cb
    (function-ptr
     (lambda (frame)
       (define b (PancakeManagedFrame-bytes frame))
       (when b (free b))
       ;; Drop the retained trampoline by the same object we stored it under.
       ;; Reading `(PancakeManagedFrame-release frame)` back yields a fresh
       ;; cpointer that is `ptr-equal?` but not `eq?` to `release-cb`, so an
       ;; eq?-keyed `hash-remove!` on it would silently miss and leak the entry.
       (hash-remove! owned-frame-releases release-cb))
     _PancakeReleaseFn))
  (hash-set! owned-frame-releases release-cb #t)
  (define mf (make-PancakeManagedFrame buf len FRAME-SHAPE-BYTE release-cb #f))
  (define rc (pancake_peer_feed_owned (peer-handle p) mf))
  (cond
    [(= rc OK) (void)]            ; library now owns buf; it will invoke release-cb
    [else
     (free buf)
     (hash-remove! owned-frame-releases release-cb)
     (check/abort p rc)]))

(define (peer-step! p) (check (pancake_peer_step (peer-handle p))))

;; Step until quiescent: drains every cascaded outbound (a projection resolving,
;; a listener firing, a queued deliver) in one sweep, so the pump never strands
;; queued frames behind a blocking inbox read. The native loop is bounded by the
;; work the session already admitted (ADR-0050 / ADR-0007).
(define (peer-step-to-idle! p) (check (pancake_peer_step_to_idle (peer-handle p))))

;; Pipelined projections (ADR-0050): send `op:get` / `op:index` / `op:untag`
;; against `receiver` (a `promise-ref` vow, or any held reference), allocating
;; `answer` for the projected value. The engine trails the matching `op:listen`
;; so the projected answer's resolution rides back. `field` / `tag` are strings.
(define (peer-send-get! p receiver field answer)
  (define fb (string->bytes/utf-8 field))
  (define buf (malloc (max (bytes-length fb) 1) 'atomic-interior))
  (memcpy buf fb (bytes-length fb))
  (check (pancake_peer_send_get (peer-handle p) (ref->c receiver) buf (bytes-length fb) answer)))

(define (peer-send-index! p receiver index answer)
  (check (pancake_peer_send_index (peer-handle p) (ref->c receiver) index answer)))

(define (peer-send-untag! p receiver tag answer)
  (define tb (string->bytes/utf-8 tag))
  (define buf (malloc (max (bytes-length tb) 1) 'atomic-interior))
  (memcpy buf tb (bytes-length tb))
  (check (pancake_peer_send_untag (peer-handle p) (ref->c receiver) buf (bytes-length tb) answer)))

;; Feed buffered wire bytes; the peer frames and dispatches one whole frame if
;; present. Returns the consumed byte count on OK, #f on WOULD-BLOCK (the buffer
;; holds only a partial frame), and raises on any other code, attaching the
;; peer's typed last-abort detail to the exn.
(define (peer-recv-stream! p bs)
  (define len (bytes-length bs))
  (define buf (malloc (max len 1) 'atomic-interior))
  (memcpy buf bs len)
  (define-values (r consumed) (pancake_peer_recv_stream (peer-handle p) buf len))
  (cond
    [(= r OK) consumed]
    [(= r WOULD-BLOCK) #f]
    [else (check/abort p r) (error "unreachable")]))

(define (peer-send-deliver! p target args #:answer [answer #f])
  (define keep (box '()))
  (define-values (ptr cnt) (args->c args keep))
  (check (pancake_peer_send_deliver (peer-handle p) (ref->c target) ptr cnt (if answer 1 0) (or answer 0))))

(define (peer-send-resolve! p answer resolution)
  (define keep (box '()))
  (cond
    [(fulfill? resolution)
     (check (pancake_peer_send_resolve (peer-handle p) answer RESOLUTION-FULFILL (arg->c (fulfill-value resolution) keep) #f 0))]
    [else
     (define msg (string->bytes/utf-8 (brk-message resolution)))
     (define buf (malloc (max (bytes-length msg) 1) 'atomic-interior))
     (memcpy buf msg (bytes-length msg))
     (check (pancake_peer_send_resolve (peer-handle p) answer RESOLUTION-BREAK #f buf (bytes-length msg)))]))

(define (peer-take-outbound p)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (define rc (pancake_peer_take_outbound (peer-handle p) mf))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else
     ;; Any other non-OK code (e.g. an OOM after the frame was already dequeued
     ;; and freed) is a real failure: raise instead of silently dropping an
     ;; outbound frame and ending the drain as if the queue were empty.
     (check rc)
     (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
     (pancake_managed_frame_release mf)
     out]))

(define (peer-poll p)
  (define kind (pancake_peer_peek_event (peer-handle p)))
  (cond
    [(= kind EVENT-DELIVER) (poll-deliver p)]
    [(= kind EVENT-RESOLVE) (poll-resolve p)]
    [(= kind WOULD-BLOCK) #f]
    ;; A negative peek (released peer, internal failure) fails closed: reading
    ;; the zeroed event struct would fabricate events forever instead of
    ;; raising once.
    [(negative? kind) (check kind) #f]
    [else (poll-other p)]))

(define (poll-deliver p)
  (define d (make-PancakeDeliver (make-PancakeReference 0 0 0) #f 0 0 0 #f))
  (define rc (pancake_peer_poll_event_deliver (peer-handle p) d))
  (cond
    ;; The typed projection cannot carry some delivers (e.g. a handoff
    ;; argument). The event stays queued, so drain it as an opaque
    ;; other-event — raising here would peek the same event forever.
    [(= rc ERR-UNSUPPORTED-VALUE) (poll-other p)]
    [else
     (check rc)
     (define ev (deliver-event (ref<-c (PancakeDeliver-target d))
                               (args<-c (PancakeDeliver-args d) (PancakeDeliver-args-len d))
                               (if (zero? (PancakeDeliver-has-answer d)) #f (PancakeDeliver-answer d))))
     (pancake_deliver_release d)
     ev]))

(define (poll-resolve p)
  (define r (make-PancakeResolve 0 0 (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0) #f 0 (make-PancakeHandoffGive #f 0 #f 0 #f 0) #f))
  (define rc (pancake_peer_poll_event_resolve (peer-handle p) r))
  (cond
    ;; Same leave-queued contract as poll-deliver: drain the refused resolve
    ;; as an opaque other-event so the loop survives.
    [(= rc ERR-UNSUPPORTED-VALUE) (poll-other p)]
    [else
     (check rc)
     (define kind (PancakeResolve-resolution-kind r))
     (define res
       (cond
         [(= kind RESOLUTION-FULFILL) (fulfill (arg<-c (PancakeResolve-fulfill r)))]
         ;; A three-party handoff give: project its three (pointer, length) views
         ;; into a `handoff` the connection's pump loop redeems transparently.
         [(= kind RESOLUTION-HANDOFF)
          (define h (PancakeResolve-handoff r))
          (define loc-ptr (PancakeHandoffGive-exporter-locator h))
          (define loc-len (PancakeHandoffGive-exporter-locator-len h))
          (handoff (bytes<-c (PancakeHandoffGive-give h) (PancakeHandoffGive-give-len h))
                   (if (or (not loc-ptr) (= loc-len 0))
                       ""
                       (bytes->string/utf-8 (bytes<-c loc-ptr loc-len) #\uFFFD))
                   (bytes<-c (PancakeHandoffGive-recipient-key h) (PancakeHandoffGive-recipient-key-len h)))]
         [else (brk (bytes->string/utf-8 (bytes<-c (PancakeResolve-break-message r) (PancakeResolve-break-message-len r)) #\uFFFD))]))
     (define ev (resolve-event (PancakeResolve-answer r) res))
     (pancake_resolve_release r)
     ev]))

(define (poll-other p)
  (define e (make-PancakeEvent 0 (make-PancakeManagedFrame #f 0 0 #f #f)))
  (check (pancake_peer_poll_event (peer-handle p) e))
  (define frame-mf (PancakeEvent-frame e))
  (define ev (other-event (PancakeEvent-kind e)
                          (bytes<-c (PancakeManagedFrame-bytes frame-mf) (PancakeManagedFrame-len frame-mf))))
  (pancake_event_release e)
  ev)

;; ── Actors: Spritely Goblins for Racket, on the OCapN peer ────────────────────
;; This is Goblins, faithful to its feel: you write an actor as a constructor
;; `(define (^name bcom arg …) <behavior>)` that the vat calls once at spawn, and
;; the behavior it returns is a procedure the vat invokes on each call. State
;; lives in the constructor's closure; `bcom` ("become") swaps the behavior for
;; the next turn. `methods` gives you a behavior that dispatches on a leading
;; method symbol. You reach an actor three ways: `$` is the synchronous near-call
;; (local actors only), `<-` is the location-transparent eventual-send that
;; returns a promise (a "vow"), and `on` registers a one-shot listener on a vow.
;;
;; A vat is the turn loop. `spawn` makes a local actor; `<-` to a local actor
;; queues a turn that `drive` runs, while `<-` to a `far-ref` becomes an
;; `op:deliver` over the bound peer with a fresh answer, and the returned vow
;; settles when the partner's resolution arrives. `publish!` exports a local
;; actor so an inbound deliver runs it, and `vat-serve!` dispatches one polled
;; peer event into the vat. A leading Racket method symbol marshals to an OCapN
;; symbol on the wire, matching Goblins's `($ obj 'method …)`.
(provide methods bcom?
         (struct-out actor-ref) (struct-out local-vow)
         current-vat make-vat with-vat vat-run
         vat-snapshot vat-restore!
         spawn $ <- <-np on
         publish! vat-serve! drive break-far-vows!)

;; A local actor reference: the vat that owns it and the actor's id within it.
;; Carries no behavior itself — the behavior is mutable state the vat holds, so a
;; reference stays valid across `bcom`.
(struct actor-ref (vat id) #:transparent)

;; A promise for a local eventual-send's result, settled during `drive`. (A far
;; send's promise is a `promise-ref`, settled by an inbound `resolve-event`.)
(struct local-vow (vat id) #:transparent)

;; `bcom` is a capability the vat injects into a constructor, never a value a
;; user can forge. `(bcom new-behavior)` swaps this actor's behavior for the next
;; turn; `(bcom new-behavior result)` also returns `result` from the current
;; turn. We tag the swap so the vat can recognize it on the way out of a turn.
(struct become (behavior result) #:transparent)
(define (bcom? x) (become? x))

;; The vat that `spawn`/`$`/`<-`/`on` act in. Bound for the extent of a turn (and
;; by `with-vat`/`vat-run`), the way Goblins binds its current syscaller.
(define current-vat (make-parameter #f))

(define (the-vat who)
  (or (current-vat) (error who "no current vat — call inside (with-vat v …) or (vat-run v thunk)")))

;; The turn loop. `cells` maps an actor id to a box holding its current behavior
;; procedure; `next` hands out fresh ids; `queue` holds pending local sends;
;; `listeners` maps a local vow id to its one-shot listener; `far-listeners` maps
;; a far answer to its listener; `exports` maps a peer export id to a local actor
;; id. `peer` is the bound peer (or #f for a pure-local vat); far-send answers
;; come from the peer's one outbound-answer allocator (`peer-next-answer!`).
;; `tt` is #f for the default (fast, in-place) vat, or a `time-travel` record
;; when the vat retains a revisable history of behaviors (see `make-vat
;; #:time-travel?`); it never touches the live near-call path.
;; `far-resolutions` stashes a far answer's resolution that arrived before any
;; listener was registered, so a later `on` / `conn-await` for that answer still
;; settles (a reply that lands before its listener — e.g. a source vow awaited
;; after a sibling projection already pumped the loop). Mirrors the Deno/Python
;; binding stash; cleared on disconnect by `break-far-vows!`.
;; `resolve-interceptor` is a box holding an optional hook the connection installs
;; to originate a three-party handoff: when a published actor's reply is a
;; capability that lives on a *different* connection, the ordinary resolve would
;; mis-send a cross-connection reference, so the interceptor `(answer value) ->
;; boolean` claims such a reply (returns #t) and resolves it itself as a signed
;; give. A #f return falls through to the ordinary resolve. The box stays #f on a
;; pure-local vat, so the hot turn path pays one unbox when the feature is off.
(struct vat (peer cells next queue listeners far-listeners far-resolutions exports tt resolve-interceptor) #:transparent)

;; Time-travel state for a vat opted into snapshotting. `mirror` is an immutable
;; id→behavior map kept in step with the live `cells` — each spawn and each
;; `bcom` writes the new behavior into it in O(log n). `history` is the stack of
;; mirror versions, one per state-changing turn. Because behaviors are immutable
;; and the maps share structure, a snapshot is just the current mirror (O(1)) and
;; retaining every turn costs only the changed path — the same shape Goblins's
;; `snapshot-whactormap` has. This is the standing cost of the feature being on;
;; it captures behaviors only, so it buys revisability only for actors whose
;; state lives in their behavior (functional `bcom`), not in a private box.
(struct time-travel (mirror history) #:transparent)

;; (make-vat #:peer p #:time-travel? #f) — a vat, optionally bound to a peer for
;; far sends and hosting. `#:time-travel? #t` opts every actor in this vat into a
;; retained, revisable behavior history reachable through `vat-snapshot` /
;; `vat-restore!`; the default vat keeps no history and its turn path is the
;; in-place box write below, unchanged.
(define (make-vat #:peer [peer #f] #:time-travel? [time-travel? #f])
  (vat peer (make-hasheqv) (box 1) (box '()) (make-hasheqv) (make-hasheqv) (make-hasheqv) (make-hasheqv)
       (and time-travel? (time-travel (box (hasheqv)) (box '())))
       (box #f)))

;; Record an actor's current behavior into the time-travel mirror and push the
;; new mirror version onto the history — but only when the vat opted in. For the
;; default vat this is a single predicate test, so the hot turn path pays nothing
;; when the feature is off.
(define (tt-record! v id behavior)
  (define tt (vat-tt v))
  (when tt
    (define snapshot (hash-set (unbox (time-travel-mirror tt)) id behavior))
    (set-box! (time-travel-mirror tt) snapshot)
    (set-box! (time-travel-history tt) (cons snapshot (unbox (time-travel-history tt))))))

;; (vat-snapshot v) — the current revisable state of every actor as an immutable
;; id→behavior map, captured in O(1). Errors on a vat that did not opt in.
(define (vat-snapshot v)
  (define tt (vat-tt v))
  (unless tt (error 'vat-snapshot "vat is not in time-travel mode — make it with #:time-travel? #t"))
  (unbox (time-travel-mirror tt)))

;; (vat-restore! v snap) — rewind every actor present in `snap` to the behavior
;; it held there and reset the mirror to it. Actors spawned after `snap` keep
;; their live cell but are absent from the restored mirror, so a later snapshot
;; reflects the rewound set. Errors on a vat that did not opt in.
(define (vat-restore! v snap)
  (define tt (vat-tt v))
  (unless tt (error 'vat-restore! "vat is not in time-travel mode — make it with #:time-travel? #t"))
  (for ([(id behavior) (in-hash snap)])
    (define cell (hash-ref (vat-cells v) id #f))
    (when cell (set-box! cell behavior)))
  (set-box! (time-travel-mirror tt) snap))

;; Run `thunk` with `v` as the current vat. `with-vat` is the macro form.
(define (vat-run v thunk) (parameterize ([current-vat v]) (thunk)))
(define-syntax-rule (with-vat v body ...) (vat-run v (lambda () body ...)))

;; ── methods: a behavior that dispatches on a leading method symbol ────────────
;; `(methods [(verb formal …) body …] …)` expands to a procedure of
;; `(method . args)`. `($ obj 'set 5)` runs the `[(set new) …]` clause with
;; `new` bound to 5. An unknown method raises, settling a far call as a break.
(define-syntax (methods stx)
  (syntax-case stx ()
    [(_ [(verb formal ...) body ...] ...)
     #'(lambda (method . actual)
         (case method
           [(verb) (apply (lambda (formal ...) body ...) actual)] ...
           [else (error '$ "object has no method: ~a" method)]))]))

;; ── spawn: construct a local actor in the current vat ─────────────────────────
;; `(spawn ^name arg …)` calls the constructor once with an injected `bcom` plus
;; `arg …`, stores the behavior it returns, and returns a local `actor-ref`.
(define (spawn constructor . args)
  (define v (the-vat 'spawn))
  (define id (unbox (vat-next v)))
  (set-box! (vat-next v) (add1 id))
  (define cell (box #f))
  (hash-set! (vat-cells v) id cell)
  ;; `bcom` closes over this actor's cell. It only records the swap; the vat
  ;; applies it after the turn returns, so a `bcom` mid-turn cannot tear the
  ;; behavior out from under the call in flight.
  (define (bcom new-behavior [result (void)]) (become new-behavior result))
  (define behavior (apply constructor bcom args))
  (set-box! cell behavior)
  (tt-record! v id behavior)
  (actor-ref v id))

;; ── $ : the synchronous near-call ─────────────────────────────────────────────
;; `($ ref 'method arg …)` runs `ref`'s behavior now and returns its value.
;; Legal only for a local actor in the current vat; a far ref must use `<-`,
;; exactly as Goblins forbids `$` to a far ref. A `bcom` the behavior returns
;; swaps the cell and yields the `bcom` result.
(define ($ ref method . args)
  (cond
    [(actor-ref? ref) (run-turn ref method args)]
    [(far-ref? ref) (error '$ "cannot near-call a far reference — use <-")]
    [else (error '$ "not an actor reference: ~a" ref)]))

;; Run one turn of a local actor: invoke its behavior, and if it returned a
;; `bcom`, install the new behavior and yield the bcom's result.
(define (run-turn ref method args)
  (define v (actor-ref-vat ref))
  (define cell (hash-ref (vat-cells v) (actor-ref-id ref)
                         (lambda () (error '$ "no such actor: ~a" (actor-ref-id ref)))))
  (define behavior (unbox cell))
  (define result (parameterize ([current-vat v]) (apply behavior method args)))
  (cond
    [(become? result)
     (set-box! cell (become-behavior result))
     (tt-record! v (actor-ref-id ref) (become-behavior result))
     (become-result result)]
    [else result]))

;; ── <- : the eventual-send (returns a vow) ────────────────────────────────────
;; `(<- ref 'method arg …)` is location-transparent. To a local actor it queues
;; a turn for `drive` and returns a `local-vow`. To a `far-ref` it sends an
;; `op:deliver` over the bound peer with a fresh answer — marshalling the method
;; symbol to an OCapN `(sym …)` ahead of the args — and returns a `promise-ref`
;; backed by that answer. To a `promise-ref` (the vow an earlier far `<-`
;; returned) it pipelines (ADR-0007): the deliver rides a `desc:answer` target,
;; so the call addresses the object that answer will resolve to and the partner
;; queues it until the answer settles — a dependent call need not wait for the
;; one it depends on.
(define (<- ref method . args)
  (cond
    [(actor-ref? ref) (queue-local-send ref method args)]
    [(or (far-ref? ref) (promise-ref? ref)) (far-send ref method args #:answer? #t)]
    [else (error '<- "not a reference: ~a" ref)]))

;; `<-np` ("no promise") is the fire-and-forget eventual-send: deliver with no
;; answer requested, return void. To a local actor it queues a promise-less turn;
;; to a `far-ref` or a pipelined `promise-ref` it flushes a deliver with no answer.
(define (<-np ref method . args)
  (cond
    [(actor-ref? ref) (queue-local-send ref method args) (void)]
    [(or (far-ref? ref) (promise-ref? ref)) (far-send ref method args #:answer? #f) (void)]
    [else (error '<-np "not a reference: ~a" ref)]))

(define (queue-local-send ref method args)
  (define v (actor-ref-vat ref))
  (define id (unbox (vat-next v)))
  (set-box! (vat-next v) (add1 id))
  (set-box! (vat-queue v) (cons (vector ref method args id) (unbox (vat-queue v))))
  (local-vow v id))

(define (far-send ref method args #:answer? answer?)
  (define v (the-vat '<-))
  (define p (vat-peer v))
  (unless p (error '<- "this vat has no peer — far sends need (make-vat #:peer …)"))
  ;; The answer comes from the peer's one outbound-answer allocator
  ;; (pancake_peer_next_answer), so it can never alias another question.
  (define answer (and answer? (peer-next-answer! p)))
  ;; A non-empty method marshals to a leading OCapN `(sym …)`; the empty symbol
  ;; means a positional (methodless) invocation — a bare `(your-name)` deliver, no
  ;; stray empty symbol on the wire — matching `Vat::send` and the Deno/Python/Rust
  ;; bindings, and what a methodless Goblins lambda (e.g. a handoff greeter) expects.
  (define method-name (symbol->string method))
  (define payload (if (= 0 (string-length method-name)) args (cons (sym method-name) args)))
  (peer-send-deliver! p ref payload #:answer answer)
  (and answer (promise-ref answer)))

;; ── on : register a one-shot listener on a vow ────────────────────────────────
;; `(on a-vow on-fulfilled #:catch on-broken #:finally on-finally #:promise? #t)`
;; mirrors Goblins's `on`. The fulfilled handler is optional and positional; with
;; `#:promise? #t` `on` returns a new vow that settles with the handler's result,
;; so you can chain. A local vow fires during `drive`; a far vow (a `promise-ref`)
;; fires when `vat-serve!` dispatches the matching `resolve-event`.
(define (on a-vow [on-fulfilled #f]
            #:catch [on-broken #f] #:finally [on-finally #f] #:promise? [promise? #f])
  (define v (the-vat 'on))
  (define chained (and promise? (let ([id (unbox (vat-next v))])
                                  (set-box! (vat-next v) (add1 id))
                                  (local-vow v id))))
  ;; A listener is `(value broken?)`: `broken?` is #f on fulfill (value is the
  ;; payload) and #t on break (value is the message). It runs the right handler,
  ;; the finally, and — when chaining — settles the returned vow.
  (define (listener value broken?)
    (define outcome
      (with-handlers ([(lambda (_) #t) (lambda (e) (cons 'broken (exn->message e)))])
        (cond
          [broken? (if on-broken (cons 'ok (on-broken value)) (cons 'broken value))]
          [else (if on-fulfilled (cons 'ok (on-fulfilled value)) (cons 'ok value))])))
    (when on-finally (on-finally))
    (when chained
      (if (eq? (car outcome) 'ok)
          (settle-local v (local-vow-id chained) (cdr outcome) #f)
          (settle-local v (local-vow-id chained) (cdr outcome) #t))))
  (cond
    [(local-vow? a-vow) (hash-set! (vat-listeners v) (local-vow-id a-vow) listener)]
    [(promise-ref? a-vow)
     (define answer (promise-ref-answer a-vow))
     ;; A resolution that already arrived (before this listener) is waiting in the
     ;; stash — fire now from it; otherwise wait for the inbound resolve-event.
     (define stashed (hash-ref (vat-far-resolutions v) answer #f))
     (cond
       [stashed
        (hash-remove! (vat-far-resolutions v) answer)
        (if (fulfill? stashed) (listener (fulfill-value stashed) #f) (listener (brk-message stashed) #t))]
       [else (hash-set! (vat-far-listeners v) answer listener)])]
    [else (error 'on "not a vow: ~a" a-vow)])
  ;; Match Goblins: `on` is a statement unless the caller asked to chain.
  (if promise? chained (void)))

(define (exn->message e) (if (exn? e) (exn-message e) (format "~a" e)))

;; Fire a local vow's listener, if one is registered, and drop it (one-shot).
(define (settle-local v id value broken?)
  (define listener (hash-ref (vat-listeners v) id #f))
  (when listener
    (hash-remove! (vat-listeners v) id)
    (listener value broken?)))

;; ── drive: run queued local turns to quiescence ───────────────────────────────
;; Each queued eventual-send runs its actor's turn; the vow settles with the
;; value (or, on a raised exception, a break carrying the message) and its
;; listener fires. Turns a turn queues run in the same drive (FIFO).
(define (drive v)
  (let loop ()
    (define pending (reverse (unbox (vat-queue v))))
    (unless (null? pending)
      (set-box! (vat-queue v) '())
      (for ([entry (in-list pending)])
        (define ref (vector-ref entry 0))
        (define method (vector-ref entry 1))
        (define args (vector-ref entry 2))
        (define vow-id (vector-ref entry 3))
        (define-values (value broken?)
          (with-handlers ([(lambda (_) #t) (lambda (e) (values (exn->message e) #t))])
            (values (run-turn ref method args) #f)))
        (settle-local v vow-id value broken?))
      (loop))))

;; ── publish! / vat-serve! : host a local actor on the peer ────────────────────
;; `(publish! v actor export-id)` exports a local actor on the bound peer and
;; binds the export to it, so an inbound deliver to that export runs the actor.
(define (publish! v actor export-id)
  (define p (or (vat-peer v) (error 'publish! "this vat has no peer")))
  (unless (actor-ref? actor) (error 'publish! "can only publish a local actor reference"))
  (peer-register-export! p export-id)
  (hash-set! (vat-exports v) export-id (actor-ref-id actor)))

;; Dispatch one polled peer event into the vat. A deliver to a published export
;; unmarshals the leading OCapN symbol to a Racket method symbol, near-calls the
;; actor, and settles the answer with `(fulfill reply)` (or `(brk message)` if
;; the actor raised). A resolve whose answer matches a pending far vow fires that
;; vow's listener. Returns #t when the event belonged to this vat, #f otherwise
;; so the caller can handle it.
(define (vat-serve! v event)
  (cond
    [(deliver-event? event) (serve-deliver v event)]
    [(resolve-event? event) (serve-resolve v event)]
    [else #f]))

(define (serve-deliver v event)
  (define target (deliver-event-target event))
  (cond
    [(not (near-ref? target)) #f]
    [else
     (define actor-id (hash-ref (vat-exports v) (near-ref-id target) #f))
     (cond
       [(not actor-id) #f]
       [else
        (define args (deliver-event-args event))
        (define-values (method rest)
          (if (and (pair? args) (sym? (car args)))
              (values (string->symbol (sym-value (car args))) (cdr args))
              (values 'call args)))
        (define answer (deliver-event-answer event))
        (define resolution
          (with-handlers ([(lambda (_) #t) (lambda (e) (brk (exn->message e)))])
            (fulfill (apply $ (actor-ref v actor-id) method rest))))
        (when answer
          ;; A reply that is a capability living on another connection trips the
          ;; gifter half: the interceptor deposits it with its exporter and
          ;; answers with a signed give instead of an ordinary cross-connection
          ;; resolve (ADR-0009). Anything else falls through to the normal resolve.
          (define interceptor (unbox (vat-resolve-interceptor v)))
          (unless (and (fulfill? resolution) interceptor
                       (interceptor answer (fulfill-value resolution)))
            (peer-send-resolve! (vat-peer v) answer resolution)))
        #t])]))

(define (serve-resolve v event)
  (define answer (resolve-event-answer event))
  (define listener (hash-ref (vat-far-listeners v) answer #f))
  (cond
    [(not listener)
     ;; No listener yet: stash the resolution so a later `on` / `conn-await` for
     ;; this answer still settles. A resolve-event is always for an answer this
     ;; peer issued, so it belongs to this vat (returns #t).
     (hash-set! (vat-far-resolutions v) answer (resolve-event-resolution event))
     #t]
    [else
     (hash-remove! (vat-far-listeners v) answer)
     (define res (resolve-event-resolution event))
     (cond
       [(fulfill? res) (listener (fulfill-value res) #f)]
       [(brk? res) (listener (brk-message res) #t)]
       ;; A handoff reaching the vat means no redeemer intercepted it (the
       ;; connection redeems transparently before serving); break rather than
       ;; hand the application an unredeemed give.
       [else (listener "handoff give arrived at a vat with no redeemer" #t)])
     #t]))

;; Map a wire reference to a vat target, routing a `near-ref` export this vat
;; hosts to its local `actor-ref` so a self-spawned capability resolves
;; in-process rather than going out on the wire to its own export — the same
;; routing Rust's `Vat::resolve_target` performs. A reference this vat does not
;; host comes back unchanged.
(define (vat-resolve-target v target)
  (define actor-id
    (and (near-ref? target) (hash-ref (vat-exports v) (near-ref-id target) #f)))
  (if actor-id (actor-ref v actor-id) target))

;; ── break-far-vows! : settle every outstanding far vow as broken ──────────────
;; A far vow settles only when the partner's resolve arrives over the wire, so
;; once the connection is gone those resolves can never come. A serve loop calls
;; this on disconnect, so an `on` form's `#:catch` handler runs instead of a vow
;; waiting forever. Local vows are untouched: they settle in `drive` and never
;; wait on the wire.
(define (break-far-vows! v message)
  ;; Snapshot then clear before firing: a listener may register another far vow,
  ;; and mutating the table mid-iteration would lose it.
  (define pending (hash-values (vat-far-listeners v)))
  (hash-clear! (vat-far-listeners v))
  ;; Stashed resolutions for never-awaited answers die with the connection.
  (hash-clear! (vat-far-resolutions v))
  (for ([listener (in-list pending)])
    (listener message #t)))

;; ── Bootstrap serving ────────────────────────────────────────────────────────
;; Publishing a capability behind a swiss number is core OCapN, not transport:
;; the explicit blocking netlayer/listener/endpoint handles for the TCP and
;; in-process archives live in their own composable modules (`pancake-tcp.rkt`,
;; `pancake-inproc.rkt`), built on the transport seam this module exports below.
(provide peer-register-bootstrap-cap!)

(define (peer-register-bootstrap-cap! p swissnum)
  (define buf (malloc (max (bytes-length swissnum) 1) 'atomic-interior))
  (memcpy buf swissnum (bytes-length swissnum))
  (define-values (rc id) (pancake_peer_register_bootstrap_cap (peer-handle p) buf (bytes-length swissnum)))
  (check rc)
  id)

;; ── Async connection over Racket ports ───────────────────────────────────────
;; The sync peer is sans-io: it never blocks and never owns a socket. An
;; `async-connection` owns one peer plus a Racket TCP port pair and *drives* the
;; peer over it — read bytes, let the peer frame and dispatch them, write the
;; peer's outbound frames back, surface events. Racket's blocking port reads
;; yield to the green-thread scheduler, so this cooperates with other threads
;; without ever entering the C netlayer. One async-connection owns one peer and
;; is driven from one thread (the peer is a single-owner state machine). This is
;; the pump layer `connection` builds on; an application usually holds a
;; `connection`.
;; The transport an async connection drives: how whole frames move and how the
;; connection tears down. The core supplies the TCP port transport below; the
;; `pancake-iroh` companion supplies the iroh one and injects it through
;; `async-connection/transport`, so the iroh artifact stays out of this core
;; driver entirely.
;;   write-frame! : (bytes? -> void)                 write one outbound frame
;;   flush!       : (-> void)                         flush buffered output
;;   fill-inbox!  : (-> (or/c bytes? eof-object?))    block for more inbound bytes
;;   close!       : (-> void)                         release the transport
(struct async-transport (write-frame! flush! fill-inbox! close!))

;; The pump layer `connection` builds on: a `peer`, the accumulated inbound
;; `inbox`, and the `transport` carrying its frames. The driver is transport
;; agnostic — it never branches on TCP vs iroh; the transport closures do.
(struct async-connection (peer [inbox #:mutable] transport) #:transparent)

;; The TCP port transport: frames concatenate into the byte stream and flush
;; once; a fill reads whatever is ready (blocking for at least one byte while
;; yielding to the scheduler); close shuts both ports.
(define (port-transport in out)
  (async-transport
   (lambda (frame) (write-bytes frame out))
   (lambda () (flush-output out))
   (lambda ()
     (define buf (make-bytes 65536))
     (define n (read-bytes-avail! buf in))
     (if (eof-object? n) eof (subbytes buf 0 n)))
   (lambda () (close-output-port out) (close-input-port in))))

;; Connect to host:port and complete the keyed OCapN handshake.
(define (async-connect host port)
  (define-values (in out) (tcp-connect host port))
  (define ac (async-connection (make-peer) #"" (port-transport in out)))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port))
  ac)

;; Wrap a peer you have configured (exports/imports/bootstrap caps) and an
;; accepted port pair.
(define (async-connection/ports peer in out)
  (async-connection peer #"" (port-transport in out)))

;; Wrap a peer and a transport a netlayer companion built (the iroh path). The
;; binding-internal seam `pancake-iroh` constructs its connections through.
(define (async-connection/transport peer transport)
  (async-connection peer #"" transport))

;; Encode pending outbound work and write every queued frame to the wire through
;; the transport, then flush once.
(define (async-pump-outbound! conn)
  (define p (async-connection-peer conn))
  ;; Step to idle, not once: settling one answer can cascade (a projection
  ;; resolves, fires a listener, queues a deliver), and a single step would leave
  ;; the cascade's frames queued behind the next blocking inbox read. Draining to
  ;; quiescence here puts the whole batch on the wire in one pump.
  (peer-step-to-idle! p)
  (define t (async-connection-transport conn))
  (let loop ()
    (define frame (peer-take-outbound p))
    (when frame
      ((async-transport-write-frame! t) frame)
      (loop)))
  ((async-transport-flush! t)))

;; Pull more inbound bytes onto the inbox through the transport. Returns #t after
;; appending, or `eof` on clean close.
(define (async-fill-inbox! conn)
  (define got ((async-transport-fill-inbox! (async-connection-transport conn))))
  (cond
    [(eof-object? got) eof]
    [else (set-async-connection-inbox! conn (bytes-append (async-connection-inbox conn) got)) #t]))

;; Flush whatever is already queued on the peer's outbound to the wire. A `<-`
;; far-send only enqueues; the bytes leave when something pumps the peer.
;; `async-next-event` pumps at the top of its loop, so a reply queued while
;; serving an event leaves on the next turn. But work another green thread queues
;; onto this peer — a server pushing a broadcast to a subscriber whose own thread
;; is parked reading — would sit unsent until that thread woke. Call `async-flush!`
;; right after such a cross-thread send to put the bytes on the wire now.
(define (async-flush! conn) (async-pump-outbound! conn))

;; Queue a call to `target` and flush it to the wire. `answer` requests a reply.
(define (async-send-deliver! conn target args #:answer [answer #f])
  (peer-send-deliver! (async-connection-peer conn) target args #:answer answer)
  (async-pump-outbound! conn))

;; Queue a reply settling `answer` and flush it to the wire.
(define (async-send-resolve! conn answer resolution)
  (peer-send-resolve! (async-connection-peer conn) answer resolution)
  (async-pump-outbound! conn))

;; The connection as a sequence of events: `(for ([event (in-async-events conn)])
;; …)`. It yields each event the peer surfaces and ends on a clean disconnect, so
;; the idiomatic receive loop is a `for` over a sequence. (Same as calling
;; `async-next-event` until it returns `eof`.)
(define (in-async-events conn)
  (in-producer (lambda () (async-next-event conn)) eof))

;; Await the next application event, driving the port as needed. Returns the
;; typed event struct, or `eof` on a clean end of stream.
(define (async-next-event conn)
  (define p (async-connection-peer conn))
  (let outer ()
    (cond
      ;; A surfaced event takes priority.
      [(peer-poll p) => values]
      [else
       ;; Flush anything the last dispatch queued (replies, aborts).
       (async-pump-outbound! conn)
       ;; Consume one whole buffered frame if present; on consume, loop the
       ;; outer pump (it may have surfaced an event or queued outbound).
       (define n (peer-recv-stream! p (async-connection-inbox conn)))
       (cond
         [n
          (set-async-connection-inbox! conn (subbytes (async-connection-inbox conn) n))
          (outer)]
         ;; Need more bytes from whichever transport this connection rides.
         [(eof-object? (async-fill-inbox! conn)) eof]
         [else (outer)])])))

;; ── Connection: the application surface ──────────────────────────────────────
;; One object an application holds. It bundles the async connection and a vat, so
;; a consumer never wires peer + vat + ports by hand. `connect`/`listen`/`accept`
;; construct a connection; the operations on one are `conn-` prefixed
;; (`conn-fetch`/`conn-publish`/`conn-spawn`/`conn-send`/`conn-tell`/`conn-serve`),
;; since Racket has no method-receiver syntax to carry the verb. `connection-close!`
;; keeps the full prefix so the application-surface close reads distinctly from
;; the netlayer's `endpoint-close!`. The Goblins verbs (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`)
;; are unchanged — you use them through the connection's vat.
(provide (struct-out connection)
         connect listen accept server? server-port server-close! server-machine
         machine-publish-giftable
         tcp-locator parse-locator format-peer-uri (struct-out locator)
         conn-vat conn-async conn-peer conn-spawn conn-publish
         conn-fetch conn-enliven conn-send conn-send-promise conn-await
         conn-get conn-index conn-untag conn-serve conn-tell connection-close!
         conn-with-gc!)

;; ── Transport seam ───────────────────────────────────────────────────────────
;; The binding-internal surface every transport companion builds on, mirroring
;; the à-la-carte archive split (ADR-0059): `pancake-tcp.rkt`,
;; `pancake-inproc.rkt`, and `pancake-iroh.rkt` each open only their own archive
;; and reach the shared core machinery through here. The companions that drive a
;; live session (iroh) construct an `async-transport` over their own FFI, wrap it
;; with `async-connection/transport`, complete the keyed handshake through
;; `open-keyed-session!`, and return a `connection`. The explicit netlayer
;; companions (tcp, inproc) reuse `check-with` to raise the same typed
;; `exn:fail:pancake` from their own last-error reader, `codec-id` to spell a
;; codec symbol, and `context-handle` to thread an allocation context into a
;; `*-new-in` constructor. The cstruct and managed-frame release bindings are the
;; shared frame ABI all the archives speak by layout. Not a public API — an
;; application reaches a transport through its companion module's own surface.
(provide async-transport async-connection/transport make-peer make-vat make-fresh-machine
         open-keyed-session! check check-with bytes<-c codec-id context-handle
         _PancakeFrame _PancakeFrame-pointer make-PancakeFrame
         _PancakeManagedFrame _PancakeManagedFrame-pointer make-PancakeManagedFrame
         PancakeManagedFrame-bytes PancakeManagedFrame-len
         pancake_managed_frame_release)

;; A connection carries its async transport, its vat, and a machine router. The
;; machine (Goblins `mycapn` analogue, ADR-0009/ADR-0056) retains the session
;; identity seed and the exporter connections it has dialed, so the connection
;; can redeem three-party handoff gives transparently in its pump loop and route
;; redeemed-capability sends to the exporter that hosts them — the application's
;; `conn-send`/`conn-fetch`/`conn-tell` surface is unchanged.
(struct connection (async vat machine))

;; Distributed GC (ADR-0063), opt-in and off by default. A connection opted in
;; with `conn-with-gc!` carries a gc-state in this weak table; absent means GC is
;; off. The `connection` struct itself stays immutable, so the state lives beside
;; it keyed by identity. The table is weak so a dropped connection's state is
;; reclaimed with it.
(define gc-states (make-weak-hasheq))

;; The per-connection GC state: an async-channel onto which a fetched import's
;; finalizer (run on Racket's finalizer thread) parks its position. The
;; connection's own loops drain it on the main thread, where the peer FFI is
;; safe to touch, and send one `op:gc-export` per parked position.
(struct gc-state (channel))

;; Opt this connection into distributed GC (ADR-0063), off by default. Once on, a
;; far capability returned by `conn-fetch` releases its import to the partner — a
;; single `op:gc-export` delta — when Racket's collector reclaims the last
;; reference to it, so the partner can release the matching export. Collection is
;; best-effort on the collector's schedule. Capabilities lifted elsewhere (a
;; `conn-send` reply, a delivered argument, an `conn-enliven` result the dedup
;; cache owns) are outside this seam. Returns the connection for chaining.
(define (conn-with-gc! c)
  (hash-set! gc-states c (gc-state (make-async-channel)))
  c)

;; Register a fetched far import for GC when GC is on (ADR-0063). The finalizer
;; captures only the integer position, never the `far-ref`, so it cannot resurrect
;; the handle whose death it waits on. The bootstrap import (position 0, refused
;; in a `gc-export`) and a redeemed-handoff token (a synthetic far id, never a
;; wire import) are never tracked.
(define (track-import! c val)
  (define gs (hash-ref gc-states c #f))
  (when (and gs (far-ref? val)
             (not (= (far-ref-id val) 0))
             (< (far-ref-id val) REDEEMED-TOKEN-BASE))
    (define id (far-ref-id val))
    (define ch (gc-state-channel gs))
    (register-finalizer val (lambda (_) (async-channel-put ch id))))
  val)

;; Drain the parked GC releases on the main thread: one `op:gc-export` delta per
;; reclaimed import, then flush. Best-effort — a refused release strands a partner
;; export reclaimed at teardown, never a fault. Called at the head of the
;; connection's own loops, so a release queued by a finalizer rides out on the
;; next thing the connection does.
(define (drain-gc! c)
  (define gs (hash-ref gc-states c #f))
  (when gs
    (define ch (gc-state-channel gs))
    (define drained
      (let loop ([acc '()])
        (define id (sync/timeout 0 ch))
        (if id (loop (cons id acc)) acc)))
    (unless (null? drained)
      (for ([id (in-list drained)])
        (with-handlers ([(lambda (_) #t) void])
          (peer-send-gc-export! (conn-peer c) (list id) (list 1))))
      (async-flush! (conn-async c)))))

;; Redeemed three-party handoff capabilities live on a dialed exporter
;; connection, not the connection the give arrived over. A redeemed capability is
;; handed to the application as an ordinary `far-ref` whose id is drawn from this
;; reserved high range — above any wire-allocated import position — and the
;; machine records the route (exporter connection + the real exporter-side
;; reference) under that id. A later `conn-send`/`conn-tell` to that id is
;; forwarded to the exporter with the real reference swapped in, so transparency
;; lives entirely inside the binding and the public `far-ref`/`conn-send` surface
;; is untouched. The range is disjoint from real session ids, so a redeemed token
;; can never alias a partner's import.
(define REDEEMED-TOKEN-BASE (expt 2 60))

;; The machine router's mutable state — pancake's analogue of Goblins' `mycapn`,
;; one per node. It holds the retained 32-byte identity `seed` (reused for every
;; connection it opens), the exporter connections keyed by `ocapn://` locator,
;; the per-exporter-session withdrawal `counts`, the `redeemed` table (token ->
;; (exporter-connection . real-reference)), and the next token to mint. The
;; gifter half adds four shared-state fields: a lazily-created shared
;; `gift-registry` (boxed) bound on every peer of this node so a gift deposited
;; on one connection and withdrawn on another resolve against one authority; the
;; live `connections` of this node (so a node-giftable published once appears on
;; all of them, including connections accepted later); the `giftables` by swiss
;; name (capabilities this node exports under one identity on every connection);
;; and `fetched-homes`, an identity table mapping a fetched capability to the
;; connection it lives on, so a published actor returning a capability whose home
;; is a different connection trips the transparent gifter.
(struct machine (seed exporters counts redeemed next-token gift-registry connections giftables fetched-homes))

(define (make-machine seed)
  (machine seed (make-hash) (make-hash) (make-hash) (box REDEEMED-TOKEN-BASE)
           (box #f) (make-hasheq) (make-hash) (make-weak-hasheq)))

;; Bind this node's shared gift registry onto `peer` before its handshake, so the
;; peer's inbound deposit/withdraw resolve against the node-wide table. The
;; registry is created lazily the first time a peer is bound and outlives every
;; connection. Binding-internal: every connection path calls it.
(define (machine-bind-registry! m peer)
  (define grb (machine-gift-registry m))
  (unless (unbox grb) (set-box! grb (make-gift-registry)))
  (peer-set-gift-registry! peer (gift-registry-pointer (unbox grb))))

;; Release the shared gift registry, once every connection that referenced it is
;; closed. Idempotent; a machine with no exporter activity never allocated one.
;; Call at node shutdown — the gate leaks it at process exit instead.
(define (machine-dispose-registry! m)
  (define grb (machine-gift-registry m))
  (when (unbox grb) (gift-registry-free! (unbox grb)) (set-box! grb #f)))

;; Track a connection and publish every node-giftable on it. Binding-internal:
;; `build-connection` calls it as a connection is constructed.
(define (machine-register! m c)
  (hash-set! (machine-connections m) c #t)
  (for ([(name behavior) (in-hash (machine-giftables m))])
    (publish-giftable-on-conn! c name behavior)))

;; Stop tracking a closed connection. Binding-internal.
(define (machine-unregister! m c)
  (hash-remove! (machine-connections m) c))

;; Publish `behavior` under `name` on every connection of this node — those open
;; now and any accepted later — so a recipient can withdraw a gift naming it on a
;; connection it dialed itself (the exporter half of a three-party handoff). The
;; behavior is an ordinary actor behavior `(lambda (method . args) …)`, e.g. one
;; built with `methods`.
(define (machine-publish-giftable m name behavior)
  (hash-set! (machine-giftables m) name behavior)
  (for ([c (in-hash-keys (machine-connections m))])
    (publish-giftable-on-conn! c name behavior)))

;; A machine with a fresh random identity seed — the transport seam a companion
;; (iroh) uses to build a `connection` without reaching for an entropy source of
;; its own. An iroh recipient redeeming a `tcp` exporter give dials it with this
;; retained seed, the same shape the core's tcp `connect` retains.
(define (make-fresh-machine) (make-machine (crypto-random-bytes 32)))

;; The exporter route for a redeemed token, if `target` names one: a pair of the
;; exporter connection and the real exporter-side reference. #f for any ordinary
;; capability, so the caller falls through to the normal path.
(define (machine-route m target)
  (and (far-ref? target)
       (>= (far-ref-id target) REDEEMED-TOKEN-BASE)
       (hash-ref (machine-redeemed m) (far-ref-id target) #f)))

;; Complete the keyed op:start-session handshake over a negotiating peer: sign a
;; tcp locator naming `designator` with the session key `seed` (a fresh random
;; key when none is given — entropy at the I/O boundary, never in the sans-io
;; core; an explicit `seed` reuses a machine's retained identity to dial an
;; exporter), flush it, and pump until the partner's start-session opens the
;; session.
(define (open-keyed-session! ac designator #:transport [transport "tcp"] #:seed [seed (crypto-random-bytes 32)])
  (define p (async-connection-peer ac))
  (peer-start-session! p seed #:designator designator #:transport transport)
  (async-flush! ac)
  (drive-handshake-until-open! ac))

(define (drive-handshake-until-open! ac)
  (define p (async-connection-peer ac))
  (let loop ()
    (unless (peer-session-open? p)
      (async-flush! ac)
      (let consume ()
        (define n (peer-recv-stream! p (async-connection-inbox ac)))
        (when n
          (set-async-connection-inbox! ac (subbytes (async-connection-inbox ac) n))
          (unless (peer-session-open? p) (consume))))
      (unless (peer-session-open? p)
        (cond
          [(eof-object? (async-fill-inbox! ac))
           (error 'connect "connection closed during the OCapN handshake")]
          [else (loop)])))))

;; Wrap a freshly-handshaken async connection and its peer in a `connection`
;; bound to node machine `m`: build the vat, install the foreign-home resolve
;; interceptor that originates the gifter half of a three-party handoff, and join
;; the node so every node-giftable is published on this connection too. The
;; single place a `connection` is born, so every path shares the machine seam.
(define (build-connection ac peer m #:time-travel? [time-travel? #f])
  (define v (make-vat #:peer peer #:time-travel? time-travel?))
  (define conn (connection ac v m))
  (set-box! (vat-resolve-interceptor v)
            (lambda (answer value) (intercept-resolve! conn answer value)))
  (machine-register! m conn)
  conn)

;; The TCP dial mechanism behind `connect`: open a socket to host:port, bind the
;; node's shared gift registry, and complete the keyed op:start-session handshake
;; keyed with the machine's retained identity (so the session is open before this
;; returns — the same handshake a real Goblins peer requires). The connection
;; shares `m`, so a fetched capability and any handoff it triggers share one
;; identity and connection table. Not provided; a `tcp` locator reaches it
;; through `connect`.
(define (dial-tcp host port m)
  (define-values (in out) (tcp-connect host port))
  (define peer (make-peer))
  (define ac (async-connection/ports peer in out))
  (machine-bind-registry! m peer)
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port) #:seed (machine-seed m))
  (build-connection ac peer m))

;; Dial host:port for `connect`. A shared `machine` threads one node identity and
;; gift registry across several connections (the gifter side of a three-party
;; handoff); omit it for a standalone connection with a fresh identity.
(define (connect-tcp host port #:machine [machine #f])
  (dial-tcp host port (or machine (make-fresh-machine))))

;; ── Hosting: listen and accept ────────────────────────────────────────────────
;; The host side of the same surface. `listen` binds host:port and returns a
;; server; `accept` blocks for the next partner, completes the keyed OCapN
;; handshake (the exchange is symmetric — both ends send their op:start-session
;; first, then read), and returns a ready connection exactly like `connect`.
;; Each accepted partner gets its own peer and vat. Pass port 0 for an ephemeral
;; port and read the bound one back with `server-port`. `accept` takes
;; `#:time-travel?`: pass #t to give the accepted connection's vat a retained,
;; revisable behavior history (every actor it hosts), off by default. The server
;; carries one node `machine` (read it with `server-machine`): every accepted
;; connection shares its identity and gift registry, so a node-giftable published
;; on it with `machine-publish-giftable` appears on each accepted partner.
(struct server (listener machine))

(define (listen host [port 0])
  (server (tcp-listen port 64 #t host) (make-fresh-machine)))

;; The struct's `server-machine` accessor is the node machine shared by every
;; connection this server accepts — pass it to `connect`'s `#:machine` so a
;; fetched capability and the recipient connection share one node (the gifter
;; side of a three-party handoff), and publish a node-giftable on it with
;; `machine-publish-giftable`.

(define (server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (server-listener s) #t))
  port)

(define (accept s #:time-travel? [time-travel? #f])
  (define-values (in out) (tcp-accept (server-listener s)))
  (define peer (make-peer))
  (define ac (async-connection/ports peer in out))
  (define m (server-machine s))
  (machine-bind-registry! m peer)
  ;; Construct the connection — which registers the node's giftables as bootstrap
  ;; caps — *before* driving the handshake to completion, so a dialer's pipelined
  ;; bootstrap fetch for a giftable is answered the instant the session opens (a
  ;; recipient redeeming a gift fetches it immediately).
  (define conn (build-connection ac peer m #:time-travel? time-travel?))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port) #:seed (machine-seed m))
  conn)

;; Stop accepting new partners. Connections already accepted are unaffected.
(define (server-close! s) (tcp-close (server-listener s)))

;; Dial a partner from its `ocapn://` locator — the one dialer, dispatching on the
;; locator's transport: `iroh` dials the endpoint id with its `direct-addresses`
;; hints, `tcp` dials the `host:port` designator. There is no other dial: a
;; literal address is a `tcp` locator, built with `tcp-locator`. Parse once
;; through the core grammar, which picks the netlayer. `reachability` (an
;; IROH-REACH-* posture) governs the iroh branch and is required only when the
;; locator's transport is `iroh`; a `tcp` locator ignores it, so a plain TCP dial
;; needs nothing but the locator. An iroh locator with no posture fails closed
;; rather than guessing one.
;; `#:machine` shares one node identity and gift registry across several
;; connections — the gifter side of a three-party handoff, where the same node
;; both serves recipients (via `listen`/`accept`) and dials the exporter it
;; re-gifts from. Omit it for a standalone connection with a fresh identity. Only
;; the `tcp` branch threads it today; an iroh locator builds its own machine.
(define (connect uri [reachability #f] #:machine [machine #f])
  (define loc (parse-locator uri))
  (define transport (locator-transport loc))
  (cond
    [(string=? transport "iroh")
     (unless reachability
       (error 'connect "an iroh locator requires a reachability posture: ~a" uri))
     ;; Load the iroh companion lazily — only an iroh locator pulls in
     ;; libpancake_net_transport_iroh and its binding; a TCP-only program never touches either.
     ((dynamic-require iroh-companion-path 'connect-iroh)
      (locator-designator loc) (hash-ref (locator-hints loc) "direct-addresses" "") reachability)]
    [(string=? transport "tcp")
     (define designator (locator-designator loc))
     (define colon (let loop ([i (- (string-length designator) 1)])
                     (cond [(< i 0) #f]
                           [(char=? (string-ref designator i) #\:) i]
                           [else (loop (- i 1))])))
     (unless colon (error 'connect "tcp locator designator is not host:port: ~a" designator))
     (connect-tcp (substring designator 0 colon)
                  (string->number (substring designator (+ colon 1)))
                  #:machine machine)]
    [else (error 'connect "unsupported transport \"~a\"" transport)]))

;; Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
;; rendered through the core grammar. The convenience for the common case — a
;; caller holding a host and port passes `(connect (tcp-locator host port))`
;; instead of hand-formatting the URI. `host:port` is not a dial of its own; it
;; is a locator like any other.
(define (tcp-locator host port)
  (format-peer-uri "tcp" (format "~a:~a" host port)))

;; ── OCapN locator URIs ───────────────────────────────────────────────────────
;; The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
;; vocabulary, defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*`
;; surface, so this binding hand-rolls no percent codec. `parse-locator` copies
;; every borrowed view into Racket strings before releasing the handle;
;; `format-peer-uri` renders through the same grammar.

;; A parsed OCapN locator: `swissnum` is "" for a peer URI, the swiss bytes for a
;; sturdyref; `hints` is a string→string hash.
(struct locator (transport designator swissnum hints) #:transparent)

;; Copy a malloc'd immobile buffer of `str`'s bytes, returning (values ptr len).
;; Used to pin format inputs across the (synchronous) FFI call.
(define (pin-bytes str)
  (define b (string->bytes/utf-8 str))
  (define len (bytes-length b))
  (define buf (malloc (max len 1) 'atomic-interior))
  (memcpy buf b len)
  (values buf len))

;; Read a borrowed (pointer, length) view an accessor filled into a Racket string.
(define (locator-field accessor loc)
  (define-values (rc ptr len) (accessor loc))
  (check rc)
  (if (or (not ptr) (= len 0)) "" (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))

(define (read-locator-hints loc)
  (define-values (rc count) (pancake_locator_hint_count loc))
  (check rc)
  (for/hash ([i (in-range count)])
    (define-values (r2 kptr klen vptr vlen) (pancake_locator_hint_at loc i))
    (check r2)
    (values (bytes->string/utf-8 (bytes<-c kptr klen) #\uFFFD)
            (bytes->string/utf-8 (bytes<-c vptr vlen) #\uFFFD))))

;; Parse an `ocapn://` URI into a `locator` through the core grammar.
;; `#:sturdyref?` selects the `/s/<swiss>` form. Raises for a malformed URI.
(define (parse-locator uri #:sturdyref? [sturdyref? #f])
  (define-values (sbuf slen) (pin-bytes uri))
  (define-values (rc loc)
    (if sturdyref?
        (pancake_uri_parse_sturdyref sbuf slen)
        (pancake_uri_parse_peer sbuf slen)))
  (check rc)
  (dynamic-wind
   void
   (lambda ()
     (locator (locator-field pancake_locator_transport loc)
              (locator-field pancake_locator_designator loc)
              (locator-field pancake_locator_swissnum loc)
              (read-locator-hints loc)))
   (lambda () (pancake_locator_release loc))))

;; Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
;; through the core grammar. `hints` is a string→string hash.
(define (format-peer-uri transport designator [hints (hash)])
  (define pairs (hash->list hints))
  (define n (length pairs))
  (define-values (tbuf tlen) (pin-bytes transport))
  (define-values (dbuf dlen) (pin-bytes designator))
  ;; Pin each key/value; keep the (ptr len) pairs live until the call returns.
  (define keys (for/list ([p (in-list pairs)]) (call-with-values (lambda () (pin-bytes (car p))) list)))
  (define vals (for/list ([p (in-list pairs)]) (call-with-values (lambda () (pin-bytes (cdr p))) list)))
  (define key-ptrs (and (> n 0) (list->cblock (map car keys) _pointer)))
  (define key-lens (and (> n 0) (list->cblock (map cadr keys) _size)))
  (define val-ptrs (and (> n 0) (list->cblock (map car vals) _pointer)))
  (define val-lens (and (> n 0) (list->cblock (map cadr vals) _size)))
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc out-len)
      (pancake_uri_format_peer tbuf tlen dbuf dlen
                               key-ptrs key-lens val-ptrs val-lens n
                               buf cap))
    (cond
      [(and (= rc ERR-INVALID-ARGUMENT) (> out-len cap)) (loop out-len)]
      [else (check rc) (bytes->string/utf-8 (subbytes buf 0 out-len))])))

(define (conn-async c) (connection-async c))
(define (conn-vat c) (connection-vat c))
(define (conn-peer c) (async-connection-peer (connection-async c)))

;; Named `connection-close!` with the full prefix, keeping the
;; application-surface close distinct from the netlayer's `endpoint-close!`.
(define (connection-close! c)
  (machine-unregister! (connection-machine c) c)
  (define ac (connection-async c))
  ((async-transport-close! (async-connection-transport ac))))

;; Spawn a local actor at a fresh export position and return a near capability to
;; hand a partner. `(conn-spawn c ^name arg …)` constructs like `spawn`. The
;; position comes from the session's one export allocator, so it can never alias
;; a bootstrap or resolver export. `publish!` binds the position to the actor, so
;; a `conn-send`/`conn-tell` to the returned capability resolves in process.
(define (conn-spawn c constructor . args)
  (define pos (peer-next-export! (conn-peer c)))
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (publish! (conn-vat c) actor pos)
  (near pos))

;; Publish an actor fetchable by name (a swiss-number). Returns the near capability.
(define (conn-publish c name constructor . args)
  (define pos (peer-register-bootstrap-cap! (conn-peer c) (string->bytes/utf-8 name)))
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (publish! (conn-vat c) actor pos)
  (near pos))

;; Publish a node-giftable `behavior` (an actor behavior `(lambda (method . args)
;; …)`) under `name` on connection `c`. Binding-internal: `machine-register!` and
;; `machine-publish-giftable` call it so a node-giftable appears as a bootstrap
;; cap on every connection of the node. The behavior is spawned directly (no
;; constructor), so a giftable built with `methods` works unchanged.
(define (publish-giftable-on-conn! c name behavior)
  (define pos (peer-register-bootstrap-cap! (conn-peer c) (string->bytes/utf-8 name)))
  (define actor (with-vat (conn-vat c) (spawn (lambda (_bcom) behavior))))
  (publish! (conn-vat c) actor pos)
  (void))

;; ── Machine router: transparent three-party handoff redemption ────────────────
;; A give arriving as a resolution is redeemed by the connection's machine, not
;; the vat: dial the named exporter keyed with this connection's retained
;; identity, withdraw the gift, and hand back the live capability under a reserved
;; token so the application's `conn-send`/`conn-fetch` yields an ordinary
;; capability. All synchronous, matching the rest of the Racket binding.

;; Dial an exporter named by a give's `ocapn://` locator, bound to node machine
;; `m` so the redeemed capability and any further handoff it triggers share one
;; identity and connection table (and the exporter recognizes the recipient the
;; give names, keyed with the machine's retained seed). TCP today; an iroh
;; exporter locator is a later lift.
(define (dial-exporter uri m)
  (define loc (parse-locator uri))
  (unless (string=? (locator-transport loc) "tcp")
    (raise-pancake 'conn-send ERR-INVALID-ARGUMENT
                   "handoff redeem: unsupported exporter transport \"~a\" in ~a"
                   (locator-transport loc) uri))
  (define designator (locator-designator loc))
  (define colon (let loop ([i (- (string-length designator) 1)])
                  (cond [(< i 0) #f]
                        [(char=? (string-ref designator i) #\:) i]
                        [else (loop (- i 1))])))
  (unless colon
    (raise-pancake 'conn-send ERR-INVALID-ARGUMENT "tcp locator designator is not host:port: ~a" designator))
  (dial-tcp (substring designator 0 colon)
            (string->number (substring designator (+ colon 1)))
            m))

;; Withdraw a deposited gift over an exporter connection: sign a
;; `desc:handoff-receive` over `give` keyed by `seed`, deliver `withdraw-gift`,
;; and pump the exporter connection until the withdrawn capability's reference
;; resolves.
(define (withdraw-gift! c give seed count)
  (define v (conn-vat c))
  (define p (conn-peer c))
  (define answer (peer-next-answer! p))
  (define result (box 'pending))
  (with-vat v
    (on (promise-ref answer)
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (peer-send-withdraw-gift! p give seed count answer)
  (async-flush! (conn-async c))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'withdraw-gift "exporter closed before the gift settled"))
       (vat-serve! v (maybe-redeem! c ev))
       (loop)]
      [(eq? (car r) 'broken)
       (raise-pancake 'conn-send ERR-BROKEN "withdraw-gift broke: ~a" (cdr r))]
      [else
       (define val (cdr r))
       (unless (or (far-ref? val) (near-ref? val))
         (raise-pancake 'conn-send ERR-UNSUPPORTED-VALUE "withdraw-gift did not resolve to a capability: ~a" val))
       val])))

;; Redeem one give through the connection's machine: reuse or dial the exporter
;; keyed with the retained identity, withdraw the gift, enroll the live capability
;; under a fresh reserved token, and return the `far-ref` the application sees.
(define (machine-redeem! c a-handoff)
  (define m (connection-machine c))
  (define locator (handoff-exporter-locator a-handoff))
  (when (= 0 (string-length locator))
    (raise-pancake 'conn-send ERR-INVALID-ARGUMENT "handoff give names no dialable exporter locator"))
  (define exporter
    (or (hash-ref (machine-exporters m) locator #f)
        (let ([conn (dial-exporter locator m)])
          (hash-set! (machine-exporters m) locator conn)
          conn)))
  ;; Goblins requires the handoff-count to rise; the first withdrawal on a fresh
  ;; exporter session is 0, the next 1, and so on.
  (define count (hash-ref (machine-counts m) locator 0))
  (hash-set! (machine-counts m) locator (+ count 1))
  (define real-ref (withdraw-gift! exporter (handoff-give a-handoff) (machine-seed m) count))
  (define token (unbox (machine-next-token m)))
  (set-box! (machine-next-token m) (+ token 1))
  (hash-set! (machine-redeemed m) token (cons exporter real-ref))
  (far token))

;; Redeem a handoff resolve-event in place: rewrite it to a `fulfill` carrying the
;; live capability (or a `brk` on redeem failure). Any other event passes through.
(define (maybe-redeem! c ev)
  (if (and (resolve-event? ev) (handoff? (resolve-event-resolution ev)))
      (let ([answer (resolve-event-answer ev)])
        (with-handlers ([exn:fail? (lambda (e)
                                     (resolve-event answer (brk (format "handoff redeem failed: ~a" (exn-message e)))))])
          (resolve-event answer (fulfill (machine-redeem! c (resolve-event-resolution ev))))))
      ev))

;; ── Machine router: transparent gifter (introducer) origination ───────────────
;; The vat's resolve interceptor (installed by `build-connection`). When a
;; published actor on connection `c` returns a capability whose home is a
;; *different* connection of this node, resolving `answer` with the bare
;; cross-connection reference would be meaningless to the partner. Instead claim
;; the answer (return #t) and originate the gifter half of a three-party handoff;
;; an ordinary reply falls through (return #f) to the normal resolve.
(define (intercept-resolve! c answer value)
  (define home
    (and (or (far-ref? value) (near-ref? value))
         (hash-ref (machine-fetched-homes (connection-machine c)) value #f)))
  (cond
    [(and home (not (eq? home c)))
     (originate-handoff! c answer value home)
     #t]
    [else #f]))

;; Originate the gifter half of a three-party handoff (ADR-0009): deposit
;; `gifted` (a capability that lives on the `exporter` connection) back with the
;; exporter, then resolve the recipient's `answer` with a signed
;; `desc:handoff-give` the recipient redeems transparently. The crypto inputs
;; come from this gifter's two sessions — the recipient key from this
;; (to-recipient) connection `c`, the exporter locator and key from the exporter
;; connection — signed with the node's one retained identity, which is also what
;; the exporter saw on the deposit, so the give's signature and the deposit's
;; provenance match. A failure breaks the recipient's answer.
(define (originate-handoff! c answer gifted exporter)
  (with-handlers
      ([(lambda (_) #t)
        (lambda (e)
          (with-handlers ([(lambda (_) #t) void])
            (peer-send-resolve! (conn-peer c) answer
                                (brk (format "handoff origination failed: ~a" (exn->message e))))
            (async-flush! (conn-async c))))])
    (define gift-id (crypto-random-bytes 32))
    ;; Deposit on the exporter connection (the gifted reference is one the
    ;; exporter exported to us, so it re-encodes to its own export there), and put
    ;; it on the wire before the recipient can dial in to withdraw.
    (peer-send-deposit-gift! (conn-peer exporter) gift-id gifted)
    (async-flush! (conn-async exporter))
    (define recipient-key (peer-partner-session-key (conn-peer c)))
    (define exporter-locator-raw (peer-partner-locator-raw (conn-peer exporter)))
    (define exporter-session-key (peer-partner-session-key (conn-peer exporter)))
    (when (or (= 0 (bytes-length recipient-key))
              (= 0 (bytes-length exporter-locator-raw))
              (= 0 (bytes-length exporter-session-key)))
      (raise-pancake 'conn-serve ERR-INVALID-ARGUMENT
                     "handoff origination needs open keyed sessions to both the recipient and the exporter"))
    (define give (build-handoff-give (machine-seed (connection-machine c))
                                     recipient-key exporter-locator-raw exporter-session-key gift-id))
    (peer-send-resolve-handoff-give! (conn-peer c) answer give)
    (async-flush! (conn-async c))))

;; Eventual-send `verb` to `target` and drive the connection until the reply
;; settles, returning the fulfilled value — the request/reply half whose
;; fire-and-forget sibling is `conn-tell`. A `near-ref` this connection spawned
;; resolves in process; a partner's ref goes out on the wire. A broken reply
;; raises a typed `exn:fail:pancake` carrying PANCAKE_ERR_BROKEN, exactly as
;; the Python and Rust `send`s fail. Single-threaded: it pumps events itself,
;; matching the rest of the Racket binding. A redeemed-handoff capability is
;; routed to the exporter connection that hosts it, with the real reference.
(define (conn-send c target verb . args)
  (define route (machine-route (connection-machine c) target))
  (if route
      (apply conn-send (car route) (cdr route) verb args)
      (conn-send/here c target verb args)))

(define (conn-send/here c target verb args)
  (drain-gc! c) ; flush any imports reclaimed since the last connection op
  (define v (conn-vat c))
  ;; Route a self-spawned target to its local actor; a partner's ref stays far.
  ;; A local send queues a turn that `drive` runs in-process (firing the
  ;; listener), so it resolves without a wire round-trip.
  (define resolved (vat-resolve-target v target))
  (define result (box 'pending))
  (with-vat v
    (define vow (apply <- resolved verb args))
    (on vow
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (if (actor-ref? resolved)
      (drive v)
      (async-flush! (conn-async c)))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'conn-send "connection closed before ~a settled" verb))
       ;; A handoff resolution is redeemed transparently before the vat sees it,
       ;; so the awaiting send settles with the live capability, never the give.
       (vat-serve! v (maybe-redeem! c ev))
       (loop)]
      ;; A partner break is a typed pancake failure (PANCAKE_ERR_BROKEN), so a
      ;; caller can tell "the partner refused this call" from a local bug —
      ;; matching Python's VowBroken and Rust's ERR_BROKEN.
      [(eq? (car r) 'broken) (raise-pancake 'conn-send ERR-BROKEN "~a broke: ~a" verb (cdr r))]
      [else (cdr r)])))

;; Eventual-send `verb` to `target` and return its `promise-ref` WITHOUT driving
;; the connection to a reply — the non-blocking half of `conn-send` and the seam
;; for promise pipelining (ADR-0007). The returned `promise-ref` is itself a
;; valid `target` for a later `conn-send`/`conn-send-promise`/`conn-tell`, so a
;; dependent call rides a `desc:answer` deliver the partner queues until the
;; answer settles; a `create -> use` chain then costs one round trip. The
;; deliver is queued now and its bytes leave the wire when the chain is settled
;; by passing its tail to `conn-send` (which flushes the batch and pumps to the
;; value) — a chain never settled is fire-and-forget, for which `conn-tell` is
;; the right call. A `near-ref` this connection spawned resolves in process.
(define (conn-send-promise c target verb . args)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (define vow (with-vat v (apply <- resolved verb args)))
  ;; A local target runs its turn now; a far/pipelined target leaves on the
  ;; settling `conn-send`'s flush, so the whole chain travels as one batch.
  (when (actor-ref? resolved) (drive v))
  vow)

;; ── Pipelined projections (ADR-0050) ─────────────────────────────────────────
;; Project a field, element, or unwrapped tag out of a far vow WITHOUT waiting
;; for it to settle, returning a new `promise-ref` for the projected value. The
;; projection rides the wire as `op:get` / `op:index` / `op:untag` against the
;; receiver's answer (ADR-0052), so it pipelines exactly like a dependent call:
;; `(conn-untag c vow "row")` then `(conn-index c that 0)` reaches the first
;; element of an unwrapped tagged record in one batch, before the source resolves.
;; The returned vow is itself a projection or `conn-send` target, and settles via
;; `conn-await`. Bytes leave on the next pump (a `conn-await`/`conn-send` flush),
;; matching `conn-send-promise`.
(define (conn-get c a-vow field)
  (project-vow c a-vow (lambda (p recv answer) (peer-send-get! p recv field answer))))

(define (conn-index c a-vow i)
  (project-vow c a-vow (lambda (p recv answer) (peer-send-index! p recv i answer))))

(define (conn-untag c a-vow tag)
  (project-vow c a-vow (lambda (p recv answer) (peer-send-untag! p recv tag answer))))

(define (project-vow c a-vow send!)
  (unless (promise-ref? a-vow)
    (raise-pancake 'conn-project ERR-INVALID-ARGUMENT
                   "projection target is not a far vow: ~a" a-vow))
  (define p (conn-peer c))
  ;; The projected answer comes from the peer's one outbound-answer allocator, so
  ;; it can never alias a live question.
  (define answer (peer-next-answer! p))
  (send! p a-vow answer)
  (promise-ref answer))

;; Drive the connection until `a-vow` settles, returning its fulfilled value —
;; the awaiting half of `conn-send-promise` / `conn-get` / `conn-index` /
;; `conn-untag`. A broken vow raises a typed `exn:fail:pancake` (PANCAKE_ERR_BROKEN),
;; as `conn-send` does. A local vow settles in `drive`; a far vow on a wire reply.
;; Single-threaded: it pumps events itself, like the rest of the binding.
(define (conn-await c a-vow)
  (define v (conn-vat c))
  (define result (box 'pending))
  (with-vat v
    (on a-vow
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (if (local-vow? a-vow) (drive v) (async-flush! (conn-async c)))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'conn-await "connection closed before the vow settled"))
       (vat-serve! v (maybe-redeem! c ev))
       (loop)]
      [(eq? (car r) 'broken)
       (raise-pancake 'conn-await ERR-BROKEN "vow broke: ~a" (cdr r))]
      [else (cdr r)])))

;; Fetch a partner's published capability by name, returning the far
;; reference. The canonical fetch lives in the library: one call registers the
;; bootstrap import, allocates the answer, and queues the deliver; the vow on
;; that answer settles when the partner resolves. A partner break raises a
;; typed pancake failure (PANCAKE_ERR_BROKEN); a fetch that fulfills with
;; anything but a capability raises a typed unsupported-value failure, the
;; same code the Python binding uses for the same shape.
(define (conn-fetch c name)
  (drain-gc! c) ; flush any imports reclaimed since the last connection op
  (define v (conn-vat c))
  (define answer (peer-send-bootstrap-fetch! (conn-peer c) (string->bytes/utf-8 name)))
  (define result (box 'pending))
  (with-vat v
    (on (promise-ref answer)
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (async-flush! (conn-async c))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'conn-fetch "connection closed before \"~a\" settled" name))
       ;; A fetch that resolves to a handoff give is redeemed transparently, so
       ;; `conn-fetch` returns an ordinary capability.
       (vat-serve! v (maybe-redeem! c ev))
       (loop)]
      [(eq? (car r) 'broken)
       (raise-pancake 'conn-fetch ERR-BROKEN "fetch \"~a\" broke: ~a" name (cdr r))]
      [else
       (define val (cdr r))
       (unless (or (near-ref? val) (far-ref? val) (promise-ref? val))
         (raise-pancake 'conn-fetch ERR-UNSUPPORTED-VALUE
                        "fetch \"~a\" did not resolve to a capability: ~a" name val))
       ;; Stamp the home: a fetched capability lives on *this* connection. Used on
       ;; this connection, home is a no-op; returned to another connection (a gift
       ;; to pass on), the recorded home is what lets the gifter half recognize it
       ;; as foreign and originate a three-party handoff rather than mis-encode a
       ;; cross-connection reference (ADR-0009).
       (when (or (far-ref? val) (near-ref? val))
         (hash-set! (machine-fetched-homes (connection-machine c)) val c))
       (track-import! c val)])))

;; Enliven a sturdyref against this connection (ADR-0012): bring the durable
;; `(peer, swissnum)` to life as a live capability. Parses `sturdyref` for its
;; swissnum, then fetches it through the dedup cache — a repeat enliven of the
;; same swissnum on this session short-circuits with no wire traffic. The
;; connection must already be open to the sturdyref's peer; the sans-io core
;; tracks no remote locator and never dials. A partner break raises a typed
;; PANCAKE_ERR_BROKEN; a fulfill that is not a capability raises the typed
;; unsupported-value failure, matching `conn-fetch` and the other bindings.
(define (conn-enliven c sturdyref)
  (define swissnum (string->bytes/utf-8 (locator-swissnum (parse-locator sturdyref #:sturdyref? #t))))
  (define p (conn-peer c))
  (define start (peer-prepare-enliven! p swissnum))
  (cond
    [(= (PancakeEnlivenStart-status start) ENLIVEN-CACHED)
     ;; Cache hit: reconstruct the far reference, no wire traffic.
     (far (PancakeEnlivenStart-import-position start)
          (= (PancakeEnlivenStart-kind start) REF-PROMISE-KIND))]
    [else
     ;; FRESH or IN-FLIGHT: drive the (possibly shared) answer to settlement.
     (define answer (PancakeEnlivenStart-answer start))
     (define v (conn-vat c))
     (define result (box 'pending))
     (with-vat v
       (on (promise-ref answer)
           (lambda (val) (set-box! result (cons 'ok val)))
           #:catch (lambda (m) (set-box! result (cons 'broken m)))))
     (async-flush! (conn-async c))
     (let loop ()
       (define r (unbox result))
       (cond
         [(eq? r 'pending)
          (define ev (async-next-event (conn-async c)))
          (when (eof-object? ev)
            (peer-record-enlivenment! p swissnum ENLIVEN-OUTCOME-BROKEN 0 0)
            (error 'conn-enliven "connection closed before \"~a\" settled" sturdyref))
          (vat-serve! v (maybe-redeem! c ev))
          (loop)]
         [(eq? (car r) 'broken)
          (peer-record-enlivenment! p swissnum ENLIVEN-OUTCOME-BROKEN 0 0)
          (raise-pancake 'conn-enliven ERR-BROKEN "enliven \"~a\" broke: ~a" sturdyref (cdr r))]
         [else
          (define val (cdr r))
          (cond
            [(far-ref? val)
             ;; Cache the fulfilled far reference so a repeat enliven short-circuits.
             (peer-record-enlivenment!
              p swissnum ENLIVEN-OUTCOME-FULFILLED (far-ref-id val)
              (if (far-ref-promise val) REF-PROMISE-KIND REF-OBJECT))
             val]
            [(near-ref? val) val]
            [else
             (peer-record-enlivenment! p swissnum ENLIVEN-OUTCOME-BROKEN 0 0)
             (raise-pancake 'conn-enliven ERR-UNSUPPORTED-VALUE
                            "enliven \"~a\" did not resolve to a capability: ~a" sturdyref val)])]))]))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `conn-send`); a far one
;; flushes the deliver to the wire.
(define (conn-tell c target verb . args)
  (define route (machine-route (connection-machine c) target))
  (cond
    ;; A redeemed-handoff capability is told on its exporter connection, with the
    ;; real exporter-side reference — as `conn-send` routes it.
    [route (apply conn-tell (car route) (cdr route) verb args)]
    [else
     (define v (conn-vat c))
     (define resolved (vat-resolve-target v target))
     (with-vat v (apply <-np resolved verb args))
     (if (actor-ref? resolved)
         (drive v)
         (async-flush! (conn-async c)))]))

;; Drive inbound events into the vat until the connection closes: serve each
;; event (run published actors, settle far vows). A receive-style app reads from
;; whatever its actors enqueue.
(define (conn-serve c)
  (for ([ev (in-async-events (conn-async c))])
    (vat-serve! (conn-vat c) (maybe-redeem! c ev)))
  ;; The loop ends only when the connection closes. The wire is gone, so break
  ;; any far vow still awaiting a reply rather than leaving it pending forever —
  ;; the same disconnect guarantee the Deno and Python connections give.
  (break-far-vows! (conn-vat c) "connection closed"))
