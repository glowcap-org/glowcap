#lang racket/base
;; Idiomatic Racket API for libpancake — an OCapN/CapTP peer you drive.
;;
;; The raw `ffi/unsafe` layer is private to this module. What you use is a `peer`
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
         ffi/unsafe/define
         racket/runtime-path
         racket/tcp
         racket/random
         "constants.rkt"
         (for-syntax racket/base))

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out deliver-event) (struct-out resolve-event) (struct-out other-event)
         (struct-out fulfill) (struct-out brk)
         abi-version last-error clear-last-error
         make-context make-context/allocator context-release!
         make-peer make-peer/in make-peer/raw-open make-peer/raw-open/in peer-release!
         peer-register-export! peer-next-export! peer-register-import!
         peer-next-answer! peer-codec peer-send-bootstrap-fetch!
         peer-send-gc-export! peer-send-gc-answer!
         peer-start-session! peer-session-open?
         peer-feed! peer-feed-owned! peer-step! peer-send-deliver! peer-send-resolve!
         peer-take-outbound peer-poll peer-recv-stream!
         peer-last-abort (struct-out abort-info)
         exn:fail:pancake? exn:fail:pancake-code exn:fail:pancake-abort
         (struct-out async-connection)
         async-connect async-connection/ports
         async-send-deliver! async-send-resolve! async-next-event async-flush!
         in-async-events)

;; ── Raw FFI (private) ────────────────────────────────────────────────────────
;; No extension: `ffi-lib` appends the platform-correct one (`.so`, `.dylib`,
;; `.dll`) and tries the versioned variants, so this loads on Linux, macOS, and
;; Windows from the one `zig build` output.
;;
;; Memory discipline: Racket's collector moves GC-managed memory, so every
;; buffer whose raw address C reads — and every cstruct C reads or writes — is
;; allocated 'atomic-interior, which stays put while a Racket reference is
;; retained; the `keep` lists threaded through the marshalling code provide
;; exactly that reference for the duration C may use the address. Plain
;; 'atomic memory is kept *alive* by a reference but not *in place*, so an
;; address stored into a struct field would dangle when a collection moves the
;; block.
(define-runtime-path lib-path "../../zig-out/lib/libpancake")
(define lib (ffi-lib (path->string lib-path)))

(define-cstruct _PancakeFrame ([bytes _pointer] [len _size] [shape _uint32]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer] [len _size] [shape _uint32] [release _pointer] [private-data _pointer]) #:malloc-mode 'atomic-interior)

;; The host-allocator callback types are callable from C: `_fun` makes the
;; Racket procedures C-callable trampolines. The closures must stay reachable
;; (see `context`) for as long as the library may invoke them.
(define _PancakeAllocFn (_fun _pointer _size _size -> _pointer))
(define _PancakeFreeFn (_fun _pointer _pointer _size _size -> _void))
(define-cstruct _PancakeAllocator
  ([alloc _PancakeAllocFn] [free _PancakeFreeFn] [user-data _pointer]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeEvent ([kind _uint32] [frame _PancakeManagedFrame]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeReference ([kind _uint32] [sub-kind _uint32] [id _uint64]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeArgument
  ([kind _uint32] [boolean _uint32] [integer _int64] [float64 _double]
   [bytes _pointer] [bytes-len _size] [reference _PancakeReference]
   [items _pointer] [items-len _size]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeDeliver
  ([target _PancakeReference] [args _pointer] [args-len _size]
   [has-answer _uint32] [answer _uint64] [owner _pointer]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeResolve
  ([answer _uint64] [resolution-kind _uint32] [fulfill _PancakeArgument]
   [break-message _pointer] [break-message-len _size] [owner _pointer]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeLastAbort` in pancake.h: two leading u32s, then three
;; (pointer, length) views of process-static strings the library owns.
(define-cstruct _PancakeLastAbort
  ([domain _uint32] [has-kind _uint32]
   [kind-name _pointer] [kind-name-len _size]
   [message _pointer] [message-len _size]
   [error-name _pointer] [error-name-len _size]) #:malloc-mode 'atomic-interior)

(define-ffi-definer define-pancake lib)
(define-pancake pancake_abi_version
  (_fun (major : (_ptr o _uint32)) (minor : (_ptr o _uint32)) (patch : (_ptr o _uint32))
        -> _void -> (values major minor patch)))
(define-pancake pancake_last_error (_fun _pointer _size -> _size))
(define-pancake pancake_clear_last_error (_fun -> _void))
(define-pancake pancake_context_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_new_with_allocator
  (_fun _PancakeAllocator-pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_release (_fun _pointer -> _void))
(define-pancake pancake_peer_new_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_netlayer_new_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_feed_owned (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_peer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_negotiated
  (_fun _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_negotiated_in
  (_fun _pointer _uint32 _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_raw_open (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_raw_open_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_start_session
  (_fun _pointer _pointer _size _pointer _size _uint32 _pointer _size -> _int32))
(define-pancake pancake_peer_session_is_open (_fun _pointer -> _int32))
(define-pancake pancake_peer_release (_fun _pointer -> _void))
(define-pancake pancake_peer_feed_borrowed (_fun _pointer _PancakeFrame-pointer -> _int32))
(define-pancake pancake_peer_step (_fun _pointer -> _int32))
(define-pancake pancake_peer_recv_stream
  (_fun _pointer _pointer _size (consumed : (_ptr o _size)) -> (r : _int32) -> (values r consumed)))
(define-pancake pancake_peer_take_outbound (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_managed_frame_release (_fun _PancakeManagedFrame-pointer -> _void))
(define-pancake pancake_peer_poll_event (_fun _pointer _PancakeEvent-pointer -> _int32))
(define-pancake pancake_event_release (_fun _PancakeEvent-pointer -> _void))
(define-pancake pancake_peer_register_export (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_peer_next_export
  (_fun _pointer (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_register_import (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_peer_next_answer
  (_fun _pointer (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_last_abort (_fun _pointer _PancakeLastAbort-pointer -> _int32))
(define-pancake pancake_peer_peek_event (_fun _pointer -> _int32))
(define-pancake pancake_peer_send_deliver
  (_fun _pointer _PancakeReference-pointer _pointer _size _uint32 _uint64 -> _int32))
(define-pancake pancake_peer_send_resolve
  (_fun _pointer _uint64 _uint32 _PancakeArgument-pointer/null _pointer _size -> _int32))
(define-pancake pancake_peer_poll_event_deliver (_fun _pointer _PancakeDeliver-pointer -> _int32))
(define-pancake pancake_peer_poll_event_resolve (_fun _pointer _PancakeResolve-pointer -> _int32))
(define-pancake pancake_deliver_release (_fun _PancakeDeliver-pointer -> _void))
(define-pancake pancake_resolve_release (_fun _PancakeResolve-pointer -> _void))
(define-pancake pancake_peer_register_bootstrap_cap
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_send_bootstrap_fetch
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_codec
  (_fun _pointer (out : (_ptr o _uint32)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_send_gc_export
  (_fun _pointer _pointer _pointer _size -> _int32))
(define-pancake pancake_peer_send_gc_answer (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_tcp_netlayer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_netlayer_release (_fun _pointer -> _void))
(define-pancake pancake_tcp_connect
  (_fun _pointer _pointer _size _uint16 _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_listen
  (_fun _pointer _pointer _size _uint16 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_listener_port
  (_fun _pointer (out : (_ptr o _uint16)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_accept
  (_fun _pointer _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_conn_read_frame (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_tcp_conn_write_frame (_fun _pointer _PancakeFrame-pointer -> _int32))
(define-pancake pancake_tcp_conn_release (_fun _pointer -> _void))
(define-pancake pancake_tcp_listener_release (_fun _pointer -> _void))

;; OCapN locator URIs — core libpancake vocabulary, so a TCP-only program reaches
;; the grammar without the iroh superset. One grammar, no hand-rolled percent
;; codec: verbs mint an opaque locator handle, nouns read borrowed views from it.
(define-pancake pancake_uri_parse_peer
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_parse_sturdyref
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_format_peer
  (_fun _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out-len)))
(define-pancake pancake_uri_format_sturdyref
  (_fun _pointer _size _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out-len)))
(define-pancake pancake_locator_transport
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_designator
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_swissnum
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_hint
  (_fun _pointer _pointer _size (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_hint_count
  (_fun _pointer (c : (_ptr o _size)) -> (r : _int32) -> (values r c)))
(define-pancake pancake_locator_hint_at
  (_fun _pointer _size (k : (_ptr o _pointer)) (kl : (_ptr o _size)) (v : (_ptr o _pointer)) (vl : (_ptr o _size))
        -> (r : _int32) -> (values r k kl v vl)))
(define-pancake pancake_locator_release (_fun _pointer -> _void))

;; ── iroh transport FFI (separate libpancake_iroh artifact, loaded lazily) ────
;; iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
;; out of libpancake; it ships as its own optional superset library
;; (libpancake_iroh, `zig build iroh-abi`, needs cargo). It is loaded only on
;; first iroh use, so a Racket program (and the TCP dogfood) that never touches
;; iroh never needs it built. The frame unit is identical to TCP's, so the async
;; driver below carries a peer over an iroh connection exactly as over a port.
(define-runtime-path iroh-lib-path "../../zig-out/lib/libpancake_iroh")
(define iroh-ffi-cache (box #f))

;; Reachability posture — REQUIRED on every public iroh constructor, with NO
;; default: a peer states how it is reachable, the binding never guesses.
(define IROH-REACH-DIRECT 0)             ; dial by id + direct-address hints; relay-less, no discovery
(define IROH-REACH-DISCOVERY 1)          ; n0 relays + DNS discovery; dial by id alone
(define IROH-REACH-DISCOVERY-NO-RELAY 2) ; DNS discovery, no relays
(define IROH-REACH-LOCAL-DISCOVERY 3)    ; in-process address book; tests/same-process

;; Open the iroh ABI library and bind its symbols on first use, caching the
;; table. Optional — a clear error names the build step when it is absent.
(define (iroh-ffi)
  (or (unbox iroh-ffi-cache)
      (let ([table (load-iroh-ffi)])
        (set-box! iroh-ffi-cache table)
        table)))

(define (load-iroh-ffi)
  (define L
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (error 'iroh
                              (string-append
                               "iroh transport unavailable: could not load libpancake_iroh from "
                               "zig-out/lib. Build it with `zig build iroh-abi` (needs cargo). ~a")
                              (exn-message e)))])
      (ffi-lib (path->string iroh-lib-path))))
  (hasheq
   'netlayer-new   (get-ffi-obj 'pancake_iroh_netlayer_new L
                     (_fun _pointer _size _uint32 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'netlayer-close (get-ffi-obj 'pancake_iroh_netlayer_close L (_fun _pointer -> _void))
   'netlayer-release (get-ffi-obj 'pancake_iroh_netlayer_release L (_fun _pointer -> _void))
   'node-id        (get-ffi-obj 'pancake_iroh_netlayer_node_id L
                     (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
   'direct-addrs   (get-ffi-obj 'pancake_iroh_netlayer_direct_addrs L
                     (_fun _pointer _pointer _size (out : (_ptr o _size)) -> (r : _int32) -> (values r out)))
   ;; connect/accept/read/write block the calling thread (the endpoint runs its
   ;; own runtime), so #:blocking? lets the Racket scheduler and GC run while one
   ;; parks — other green threads keep going instead of the place freezing.
   'connect        (get-ffi-obj 'pancake_iroh_netlayer_connect L
                     (_fun #:blocking? #t _pointer _pointer _size _pointer _size _uint32 _size
                           (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'accept         (get-ffi-obj 'pancake_iroh_netlayer_accept L
                     (_fun #:blocking? #t _pointer _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
   'read-frame     (get-ffi-obj 'pancake_iroh_conn_read_frame L
                     (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32))
   'write-frame    (get-ffi-obj 'pancake_iroh_conn_write_frame L
                     (_fun #:blocking? #t _pointer _PancakeFrame-pointer -> _int32))
   'conn-release   (get-ffi-obj 'pancake_iroh_conn_release L (_fun _pointer -> _void))))

(define (iroh-fn key) (hash-ref (iroh-ffi) key))

;; A bound iroh endpoint, dialed connection, and the dialer's optional owned
;; endpoint. The async connection below carries `iroh-link` instead of a port
;; pair when it rides iroh.
;; `reachability` is required — an IROH-REACH-* posture, no default.
(define (iroh-netlayer-new reachability)
  (define-values (rc h) ((iroh-fn 'netlayer-new) #f 0 reachability)) ; #f/0 secret seed = a fresh random key
  (check rc)
  h)

(define (iroh-netlayer-node-id h)
  (define buf (make-bytes 64)) ; an endpoint id is 64 lowercase-hex bytes
  (define-values (rc len) ((iroh-fn 'node-id) h buf 64))
  (check rc)
  (bytes->string/utf-8 (subbytes buf 0 len)))

(define (iroh-netlayer-direct-addresses h)
  ;; A buffer too small is ERR-INVALID-ARGUMENT; grow until the comma-separated
  ;; hint string fits (loopback hints are short, but be safe).
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc len) ((iroh-fn 'direct-addrs) h buf cap))
    (cond
      [(and (= rc ERR-INVALID-ARGUMENT) (< cap (* 64 1024))) (loop (* cap 4))]
      [else (check rc) (bytes->string/utf-8 (subbytes buf 0 len))])))

(define (iroh-netlayer-connect h node-id hints)
  ;; connect is #:blocking?, so GC may run mid-call; pin the borrowed inputs in
  ;; immobile memory rather than passing movable byte strings.
  (define nb (string->bytes/utf-8 node-id))
  (define hb (string->bytes/utf-8 hints))
  (define nbuf (malloc (max (bytes-length nb) 1) 'atomic-interior)) (memcpy nbuf nb (bytes-length nb))
  (define hbuf (malloc (max (bytes-length hb) 1) 'atomic-interior)) (memcpy hbuf hb (bytes-length hb))
  (define-values (rc conn) ((iroh-fn 'connect) h nbuf (bytes-length nb) hbuf (bytes-length hb) CODEC-SYRUP 4096))
  (check rc)
  conn)

(define (iroh-netlayer-accept h)
  (define-values (rc conn) ((iroh-fn 'accept) h CODEC-SYRUP 4096))
  (values rc conn))

(define (iroh-netlayer-close! h) ((iroh-fn 'netlayer-close) h))
(define (iroh-netlayer-release! h) ((iroh-fn 'netlayer-release) h))

;; Block for one whole frame's bytes, or `eof` on a clean end of stream.
(define (iroh-conn-read-bytes conn)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (define code ((iroh-fn 'read-frame) conn mf))
  (cond
    [(= code ERR-CLOSED) eof]
    [(not (= code OK)) (check code)]
    [else
     (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
     (pancake_managed_frame_release mf)
     out]))

(define (iroh-conn-write-frame! conn frame)
  (define buf (malloc (max (bytes-length frame) 1) 'atomic-interior))
  (memcpy buf frame (bytes-length frame))
  (check ((iroh-fn 'write-frame) conn (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

(define (iroh-conn-close! conn) ((iroh-fn 'conn-release) conn))

;; The iroh address a peer signs and publishes: an `ocapn://<nodeid>.iroh?…` URI.
(struct iroh-link (conn netlayer))
(struct iroh-server (netlayer node-id))

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
(define (check code)
  (unless (= code OK)
    (define msg (last-error))   ; capture immediately, before any later call clobbers it
    (raise (exn:fail:pancake
            (if msg
                (format "pancake error ~a: ~a" code msg)
                (format "pancake error ~a" code))
            (current-continuation-marks) code #f))))

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
  (define r (make-PancakeResolve 0 0 (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0) #f 0 #f))
  (define rc (pancake_peer_poll_event_resolve (peer-handle p) r))
  (cond
    ;; Same leave-queued contract as poll-deliver: drain the refused resolve
    ;; as an opaque other-event so the loop survives.
    [(= rc ERR-UNSUPPORTED-VALUE) (poll-other p)]
    [else
     (check rc)
     (define res
       (if (= (PancakeResolve-resolution-kind r) RESOLUTION-FULFILL)
           (fulfill (arg<-c (PancakeResolve-fulfill r)))
           (brk (bytes->string/utf-8 (bytes<-c (PancakeResolve-break-message r) (PancakeResolve-break-message-len r)) #\uFFFD))))
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
(struct vat (peer cells next queue listeners far-listeners exports) #:transparent)

;; (make-vat #:peer p) — a vat, optionally bound to a peer for far sends and
;; hosting.
(define (make-vat #:peer [peer #f])
  (vat peer (make-hasheqv) (box 1) (box '()) (make-hasheqv) (make-hasheqv) (make-hasheqv)))

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
  (set-box! cell (apply constructor bcom args))
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
    [(become? result) (set-box! cell (become-behavior result)) (become-result result)]
    [else result]))

;; ── <- : the eventual-send (returns a vow) ────────────────────────────────────
;; `(<- ref 'method arg …)` is location-transparent. To a local actor it queues
;; a turn for `drive` and returns a `local-vow`. To a `far-ref` it sends an
;; `op:deliver` over the bound peer with a fresh answer — marshalling the method
;; symbol to an OCapN `(sym …)` ahead of the args — and returns a `promise-ref`
;; backed by that answer.
(define (<- ref method . args)
  (cond
    [(actor-ref? ref) (queue-local-send ref method args)]
    [(far-ref? ref) (far-send ref method args #:answer? #t)]
    [else (error '<- "not a reference: ~a" ref)]))

;; `<-np` ("no promise") is the fire-and-forget eventual-send: deliver with no
;; answer requested, return void. To a local actor it queues a promise-less turn.
(define (<-np ref method . args)
  (cond
    [(actor-ref? ref) (queue-local-send ref method args) (void)]
    [(far-ref? ref) (far-send ref method args #:answer? #f) (void)]
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
  (peer-send-deliver! p ref (cons (sym (symbol->string method)) args) #:answer answer)
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
    [(promise-ref? a-vow) (hash-set! (vat-far-listeners v) (promise-ref-answer a-vow) listener)]
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
        (when answer (peer-send-resolve! (vat-peer v) answer resolution))
        #t])]))

(define (serve-resolve v event)
  (define answer (resolve-event-answer event))
  (define listener (hash-ref (vat-far-listeners v) answer #f))
  (cond
    [(not listener) #f]
    [else
     (hash-remove! (vat-far-listeners v) answer)
     (define res (resolve-event-resolution event))
     (if (fulfill? res)
         (listener (fulfill-value res) #f)
         (listener (brk-message res) #t))
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
  (for ([listener (in-list pending)])
    (listener message #t)))

;; ── Blocking TCP endpoints ───────────────────────────────────────────────────
(provide make-netlayer make-netlayer/in netlayer-release! netlayer-listen netlayer-connect
         listener-port listener-accept listener-close!
         endpoint-read-frame endpoint-write-frame! endpoint-close!
         peer-register-bootstrap-cap!)

(struct netlayer (handle) #:mutable)
(struct listener (handle) #:mutable)
(struct endpoint (handle) #:mutable)

(define (host->ptr host)
  (define bs (string->bytes/utf-8 host))
  (define buf (malloc (max (bytes-length bs) 1) 'atomic-interior))
  (memcpy buf bs (bytes-length bs))
  (values buf (bytes-length bs)))

(define (make-netlayer)
  (define-values (rc h) (pancake_tcp_netlayer_new))
  (check rc)
  (define nl (netlayer h))
  (register-finalizer nl (lambda (q) (netlayer-release! q)))
  nl)

(define (make-netlayer/in ctx)
  (define-values (rc h) (pancake_tcp_netlayer_new_in (context-handle ctx)))
  (check rc)
  (define nl (netlayer h))
  (register-finalizer nl (lambda (q) (netlayer-release! q)))
  nl)

(define (netlayer-release! nl)
  (when (netlayer-handle nl)
    (pancake_tcp_netlayer_release (netlayer-handle nl))
    (set-netlayer-handle! nl #f)))

(define (netlayer-listen nl host [port 0])
  (define-values (buf n) (host->ptr host))
  (define-values (rc h) (pancake_tcp_listen (netlayer-handle nl) buf n port))
  (check rc)
  (define lst (listener h))
  (register-finalizer lst (lambda (q) (listener-close! q)))
  lst)

(define (netlayer-connect nl host port [codec 'syrup] [max-frame 4096])
  (define-values (buf n) (host->ptr host))
  (define-values (rc h) (pancake_tcp_connect (netlayer-handle nl) buf n port (codec-id codec) max-frame))
  (check rc)
  (define cn (endpoint h))
  (register-finalizer cn (lambda (q) (endpoint-close! q)))
  cn)

(define (listener-port lst)
  (define-values (rc port) (pancake_tcp_listener_port (listener-handle lst)))
  (check rc)
  port)

(define (listener-accept lst [codec 'syrup] [max-frame 4096])
  (define-values (rc h) (pancake_tcp_accept (listener-handle lst) (codec-id codec) max-frame))
  (check rc)
  (define cn (endpoint h))
  (register-finalizer cn (lambda (q) (endpoint-close! q)))
  cn)

(define (listener-close! lst)
  (when (listener-handle lst)
    (pancake_tcp_listener_release (listener-handle lst))
    (set-listener-handle! lst #f)))

(define (endpoint-read-frame cn)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (check (pancake_tcp_conn_read_frame (endpoint-handle cn) mf))
  (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
  (pancake_managed_frame_release mf)
  out)

(define (endpoint-write-frame! cn frame)
  (define buf (malloc (max (bytes-length frame) 1) 'atomic-interior))
  (memcpy buf frame (bytes-length frame))
  (check (pancake_tcp_conn_write_frame (endpoint-handle cn) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

(define (endpoint-close! cn)
  (when (endpoint-handle cn)
    (pancake_tcp_conn_release (endpoint-handle cn))
    (set-endpoint-handle! cn #f)))

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
;; `in`/`out` are the Racket port pair for the TCP path; `iroh` is an
;; `iroh-link` (and then `in`/`out` are #f) when the peer rides iroh instead.
;; The driver below branches on whichever is present, so a peer is carried over
;; an encrypted iroh QUIC connection exactly as over a port pair.
(struct async-connection (peer in out [inbox #:mutable] iroh) #:transparent)

;; Connect to host:port and complete the keyed OCapN handshake.
(define (async-connect host port)
  (define-values (in out) (tcp-connect host port))
  (define ac (async-connection (make-peer) in out #"" #f))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port))
  ac)

;; Wrap a peer you have configured (exports/imports/bootstrap caps) and an
;; accepted port pair.
(define (async-connection/ports peer in out)
  (async-connection peer in out #"" #f))

;; Wrap a peer and an established iroh link (#f port pair). The driver sources
;; and sinks whole frames through the iroh FFI instead of byte-stream ports.
(define (async-connection/iroh peer link)
  (async-connection peer #f #f #"" link))

;; Encode pending outbound work and write every queued frame to the wire. On
;; iroh each queued frame is one FFI write; on a port the frames concatenate
;; into the byte stream and flush once.
(define (async-pump-outbound! conn)
  (define p (async-connection-peer conn))
  (peer-step! p)
  (define link (async-connection-iroh conn))
  (cond
    [link
     (let loop ()
       (define frame (peer-take-outbound p))
       (when frame
         (iroh-conn-write-frame! (iroh-link-conn link) frame)
         (loop)))]
    [else
     (define out (async-connection-out conn))
     (let loop ()
       (define frame (peer-take-outbound p))
       (when frame
         (write-bytes frame out)
         (loop)))
     (flush-output out)]))

;; Pull more inbound bytes onto the inbox: one whole iroh frame, or whatever a
;; port read makes ready. Returns #t after appending, or `eof` on clean close.
(define (async-fill-inbox! conn)
  (define link (async-connection-iroh conn))
  (cond
    [link
     (define got (iroh-conn-read-bytes (iroh-link-conn link)))
     (cond
       [(eof-object? got) eof]
       [else (set-async-connection-inbox! conn (bytes-append (async-connection-inbox conn) got)) #t])]
    [else
     ;; Blocks for at least one byte (yielding to the green-thread scheduler) and
     ;; returns whatever is ready — it does not wait to fill the whole buffer.
     (define buf (make-bytes 65536))
     (define n (read-bytes-avail! buf (async-connection-in conn)))
     (cond
       [(eof-object? n) eof]
       [else (set-async-connection-inbox! conn (bytes-append (async-connection-inbox conn) (subbytes buf 0 n))) #t])]))

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
         connect listen accept server? server-port server-close!
         connect-iroh connect-iroh-uri listen-iroh
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server? iroh-server-node-id iroh-server-direct-addresses
         iroh-server-uri iroh-server-accept iroh-server-close!
         connect-uri parse-locator format-peer-uri (struct-out locator)
         conn-vat conn-async conn-peer conn-spawn conn-publish
         conn-fetch conn-send conn-serve conn-tell connection-close!)

(struct connection (async vat))

;; Complete the keyed op:start-session handshake over a negotiating peer: sign a
;; tcp locator naming `designator` with a per-connection random session key,
;; flush it, and pump until the partner's start-session opens the session.
;; Entropy is generated here, at the I/O boundary, never in the sans-io core.
(define (open-keyed-session! ac designator #:transport [transport "tcp"])
  (define p (async-connection-peer ac))
  (peer-start-session! p (crypto-random-bytes 32) #:designator designator #:transport transport)
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

;; Dial host:port, complete the keyed OCapN handshake, and return a ready
;; connection with its vat wired. The session is open (the op:start-session
;; exchange has completed) before this returns — the same handshake a real
;; Goblins peer requires.
(define (connect host port)
  (define-values (in out) (tcp-connect host port))
  (define peer (make-peer))
  (define ac (async-connection/ports peer in out))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port))
  (connection ac (make-vat #:peer peer)))

;; ── Hosting: listen and accept ────────────────────────────────────────────────
;; The host side of the same surface. `listen` binds host:port and returns a
;; server; `accept` blocks for the next partner, completes the keyed OCapN
;; handshake (the exchange is symmetric — both ends send their op:start-session
;; first, then read), and returns a ready connection exactly like `connect`.
;; Each accepted partner gets its own peer and vat. Pass port 0 for an ephemeral
;; port and read the bound one back with `server-port`.
(struct server (listener))

(define (listen host [port 0])
  (server (tcp-listen port 64 #t host)))

(define (server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (server-listener s) #t))
  port)

(define (accept s)
  (define-values (in out) (tcp-accept (server-listener s)))
  (define peer (make-peer))
  (define ac (async-connection/ports peer in out))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port))
  (connection ac (make-vat #:peer peer)))

;; Stop accepting new partners. Connections already accepted are unaffected.
(define (server-close! s) (tcp-close (server-listener s)))

;; ── iroh: the same surface over encrypted QUIC ───────────────────────────────
;; `connect-iroh`/`listen-iroh` mirror `connect`/`listen` but ride the iroh
;; sidecar: a peer addresses a partner by endpoint id + direct-address hints (an
;; `ocapn://<nodeid>.iroh?direct-addresses=…` URI) instead of host:port. They
;; need the iroh ABI library — `zig build iroh-abi` (cargo). Everything above the
;; pump (vat, conn-* verbs, events) is identical; only the transport differs.

;; Dial an iroh partner by endpoint id and direct-address hints, complete the
;; keyed OCapN handshake over the encrypted-QUIC transport, and return a ready
;; connection — the iroh sibling of `connect`. The local endpoint is ephemeral (a
;; fresh key) and released with the connection. `reachability` is required — an
;; IROH-REACH-* posture, no default.
(define (connect-iroh reachability node-id direct-addresses)
  (define netlayer (iroh-netlayer-new reachability))
  (define conn
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (iroh-netlayer-release! netlayer) (raise e))])
      (iroh-netlayer-connect netlayer node-id direct-addresses)))
  (define peer (make-peer))
  (define ac (async-connection/iroh peer (iroh-link conn netlayer)))
  ;; A dialer signs an empty designator (its identity is the session key),
  ;; matching the Zig driver; the connection owns the ephemeral netlayer.
  (open-keyed-session! ac "" #:transport "iroh")
  (connection ac (make-vat #:peer peer)))

;; Dial a partner from its published `ocapn://` URI, dispatching on the locator's
;; transport: `iroh` dials the endpoint id with its `direct-addresses` hints,
;; `tcp` dials the `host:port` designator. The transport-agnostic entry point —
;; parse once through the core grammar, which picks the netlayer.
;; `reachability` is required — an IROH-REACH-* posture, no default. It governs
;; the iroh branch; the tcp branch ignores it.
(define (connect-uri reachability uri)
  (define loc (parse-locator uri))
  (define transport (locator-transport loc))
  (cond
    [(string=? transport "iroh")
     (connect-iroh reachability (locator-designator loc) (hash-ref (locator-hints loc) "direct-addresses" ""))]
    [(string=? transport "tcp")
     (define designator (locator-designator loc))
     (define colon (let loop ([i (- (string-length designator) 1)])
                     (cond [(< i 0) #f]
                           [(char=? (string-ref designator i) #\:) i]
                           [else (loop (- i 1))])))
     (unless colon (error 'connect-uri "tcp locator designator is not host:port: ~a" designator))
     (connect (substring designator 0 colon)
              (string->number (substring designator (+ colon 1))))]
    [else (error 'connect-uri "unsupported transport \"~a\"" transport)]))

;; Dial an iroh partner from its published `ocapn://<nodeid>.iroh?…` URI — a thin
;; wrapper over the transport-dispatching `connect-uri`. `reachability` is
;; required — an IROH-REACH-* posture, no default.
(define (connect-iroh-uri reachability uri) (connect-uri reachability uri))

;; Bind a fresh ephemeral iroh endpoint and return a server that accepts
;; partners on it. Read its dialable URI with `iroh-server-uri` and pass that to
;; a partner's `connect-iroh-uri`. `reachability` is required — an IROH-REACH-*
;; posture, no default.
(define (listen-iroh reachability)
  (define nl (iroh-netlayer-new reachability))
  (iroh-server nl (iroh-netlayer-node-id nl)))

;; This endpoint's direct-address hints (comma-separated) — the dialable
;; addresses with no relay, valid on loopback/LAN.
(define (iroh-server-direct-addresses s) (iroh-netlayer-direct-addresses (iroh-server-netlayer s)))

;; The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials, rendered
;; through the core locator grammar.
(define (iroh-server-uri s)
  (define addrs (iroh-server-direct-addresses s))
  (format-peer-uri "iroh" (iroh-server-node-id s)
                   (if (= 0 (string-length addrs)) (hash) (hash "direct-addresses" addrs))))

;; Block for the next partner, complete the responder handshake (signing the
;; server's endpoint id as the locator designator), and return a ready
;; connection exactly like `accept`. The accepted connection borrows the server's
;; netlayer (which the server owns), so `connection-close!` releases only the
;; accepted iroh connection, not the endpoint.
(define (iroh-server-accept s)
  (define-values (rc conn) (iroh-netlayer-accept (iroh-server-netlayer s)))
  (check rc)
  (define peer (make-peer))
  (define ac (async-connection/iroh peer (iroh-link conn #f)))
  (open-keyed-session! ac (iroh-server-node-id s) #:transport "iroh")
  (connection ac (make-vat #:peer peer)))

;; Stop accepting and release the server's endpoint. Accepted connections are
;; unaffected until their own `connection-close!`.
(define (iroh-server-close! s)
  (iroh-netlayer-close! (iroh-server-netlayer s))
  (iroh-netlayer-release! (iroh-server-netlayer s)))

;; ── OCapN locator URIs ───────────────────────────────────────────────────────
;; The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
;; vocabulary, defined once in libpancake's `pancake_uri_*` / `pancake_locator_*`
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
  (define ac (connection-async c))
  (define link (async-connection-iroh ac))
  (cond
    [link
     (iroh-conn-close! (iroh-link-conn link))
     ;; A dialer owns its ephemeral endpoint; an accepted link's netlayer belongs
     ;; to the server, so leave it (the server closes it).
     (when (iroh-link-netlayer link)
       (iroh-netlayer-close! (iroh-link-netlayer link))
       (iroh-netlayer-release! (iroh-link-netlayer link)))]
    [else
     (close-output-port (async-connection-out ac))
     (close-input-port (async-connection-in ac))]))

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

;; Eventual-send `verb` to `target` and drive the connection until the reply
;; settles, returning the fulfilled value — the request/reply half whose
;; fire-and-forget sibling is `conn-tell`. A `near-ref` this connection spawned
;; resolves in process; a partner's ref goes out on the wire. A broken reply
;; raises a typed `exn:fail:pancake` carrying PANCAKE_ERR_BROKEN, exactly as
;; the Python and Rust `send`s fail. Single-threaded: it pumps events itself,
;; matching the rest of the Racket binding.
(define (conn-send c target verb . args)
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
       (vat-serve! v ev)
       (loop)]
      ;; A partner break is a typed pancake failure (PANCAKE_ERR_BROKEN), so a
      ;; caller can tell "the partner refused this call" from a local bug —
      ;; matching Python's VowBroken and Rust's ERR_BROKEN.
      [(eq? (car r) 'broken) (raise-pancake 'conn-send ERR-BROKEN "~a broke: ~a" verb (cdr r))]
      [else (cdr r)])))

;; Fetch a partner's published capability by name, returning the far
;; reference. The canonical fetch lives in the library: one call registers the
;; bootstrap import, allocates the answer, and queues the deliver; the vow on
;; that answer settles when the partner resolves. A partner break raises a
;; typed pancake failure (PANCAKE_ERR_BROKEN); a fetch that fulfills with
;; anything but a capability raises a typed unsupported-value failure, the
;; same code the Python binding uses for the same shape.
(define (conn-fetch c name)
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
       (vat-serve! v ev)
       (loop)]
      [(eq? (car r) 'broken)
       (raise-pancake 'conn-fetch ERR-BROKEN "fetch \"~a\" broke: ~a" name (cdr r))]
      [else
       (define val (cdr r))
       (unless (or (near-ref? val) (far-ref? val) (promise-ref? val))
         (raise-pancake 'conn-fetch ERR-UNSUPPORTED-VALUE
                        "fetch \"~a\" did not resolve to a capability: ~a" name val))
       val])))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `conn-send`); a far one
;; flushes the deliver to the wire.
(define (conn-tell c target verb . args)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (with-vat v (apply <-np resolved verb args))
  (if (actor-ref? resolved)
      (drive v)
      (async-flush! (conn-async c))))

;; Drive inbound events into the vat until the connection closes: serve each
;; event (run published actors, settle far vows). A receive-style app reads from
;; whatever its actors enqueue.
(define (conn-serve c)
  (for ([ev (in-async-events (conn-async c))])
    (vat-serve! (conn-vat c) ev))
  ;; The loop ends only when the connection closes. The wire is gone, so break
  ;; any far vow still awaiting a reply rather than leaving it pending forever —
  ;; the same disconnect guarantee the Deno and Python connections give.
  (break-far-vows! (conn-vat c) "connection closed"))
