#lang racket/base
;; Idiomatic Racket API for libpancake — an OCapN/CapTP peer you drive.
;;
;; The raw `ffi/unsafe` layer is private to this module. What you use is a `peer`
;; you create and release, native Racket values as arguments (exact integers,
;; flonums, booleans, bytes, strings, symbols, references, lists), and event
;; structs out of `peer-poll`.
;;
;;   (define p (make-peer))
;;   (peer-register-import! p 5)
;;   (peer-send-deliver! p (far 5) (list 42 #"hi") #:answer 9)
;;   (peer-step! p)
;;   (peer-take-outbound p)

(require ffi/unsafe
         ffi/unsafe/define
         racket/runtime-path
         racket/tcp
         racket/random
         (for-syntax racket/base))

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out deliver-event) (struct-out resolve-event) (struct-out other-event)
         (struct-out fulfill) (struct-out brk)
         abi-version last-error clear-last-error
         make-context make-context/allocator context-release!
         make-peer make-peer/in make-peer/negotiating peer-release!
         peer-register-export! peer-register-import!
         peer-start-session-keyed! peer-session-open?
         peer-feed! peer-feed-owned! peer-step! peer-send-deliver! peer-send-resolve!
         peer-take-outbound peer-poll peer-recv-stream!
         exn:fail:pancake?
         (struct-out async-connection)
         async-connect async-connection/ports
         async-send-deliver! async-send-resolve! async-next-event async-flush!
         in-async-events)

;; ── Constants ────────────────────────────────────────────────────────────────
(define OK 0)
(define WOULD-BLOCK -7)
(define FRAME-SHAPE-BYTE 0)
(define EVENT-DELIVER 1)
(define EVENT-RESOLVE 2)
(define REF-NEAR 0) (define REF-FAR 1) (define REF-PROMISE 2)
(define REF-STURDY 3) (define REF-BROKEN 4)
(define REF-OBJECT 0) (define REF-PROMISE-KIND 1)
(define ARG-INTEGER 0) (define ARG-FLOAT64 1) (define ARG-BOOLEAN 2) (define ARG-BYTES 3)
(define ARG-STRING 4) (define ARG-SYMBOL 5) (define ARG-VOID 6) (define ARG-REFERENCE 7) (define ARG-LIST 8)
(define ARG-SET 9) (define ARG-TAGGED 10) (define ARG-KEYWORD 11)
(define RESOLUTION-FULFILL 0) (define RESOLUTION-BREAK 1)

;; ── Raw FFI (private) ────────────────────────────────────────────────────────
;; No extension: `ffi-lib` appends the platform-correct one (`.so`, `.dylib`,
;; `.dll`) and tries the versioned variants, so this loads on Linux, macOS, and
;; Windows from the one `zig build` output.
(define-runtime-path lib-path "../../zig-out/lib/libpancake")
(define lib (ffi-lib (path->string lib-path)))

(define-cstruct _PancakeFrame ([bytes _pointer] [len _size] [shape _uint32]))
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer] [len _size] [shape _uint32] [release _pointer] [private-data _pointer]))

;; The host-allocator callback types are callable from C: `_fun` makes the
;; Racket procedures C-callable trampolines. The closures must stay reachable
;; (see `context`) for as long as the library may invoke them.
(define _PancakeAllocFn (_fun _pointer _size _size -> _pointer))
(define _PancakeFreeFn (_fun _pointer _pointer _size _size -> _void))
(define-cstruct _PancakeAllocator
  ([alloc _PancakeAllocFn] [free _PancakeFreeFn] [user-data _pointer]))
(define-cstruct _PancakeEvent ([kind _uint32] [frame _PancakeManagedFrame]))
(define-cstruct _PancakeReference ([kind _uint32] [sub-kind _uint32] [id _uint64]))
(define-cstruct _PancakeArgument
  ([kind _uint32] [boolean _uint32] [integer _int64] [float64 _double]
   [bytes _pointer] [bytes-len _size] [reference _PancakeReference]
   [items _pointer] [items-len _size]))
(define-cstruct _PancakeDeliver
  ([target _PancakeReference] [args _pointer] [args-len _size]
   [has-answer _uint32] [answer _uint64] [owner _pointer]))
(define-cstruct _PancakeResolve
  ([answer _uint64] [resolution-kind _uint32] [fulfill _PancakeArgument]
   [break-message _pointer] [break-message-len _size] [owner _pointer]))

(define-ffi-definer define-pancake lib)
(define-pancake pancake_abi_version
  (_fun (major : (_ptr o _uint32)) (minor : (_ptr o _uint32)) (patch : (_ptr o _uint32))
        -> _void -> (values major minor patch)))
(define-pancake pancake_last_error (_fun _pointer _size -> _size))
(define-pancake pancake_clear_last_error (_fun -> _void))
(define-pancake pancake_context_new_default (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_new_with_allocator
  (_fun _PancakeAllocator-pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_context_release (_fun _pointer -> _void))
(define-pancake pancake_peer_new_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_netlayer_new_in
  (_fun _pointer (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_feed_owned (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_peer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_new_negotiating (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_peer_start_session_keyed
  (_fun _pointer _uint32 _pointer _size _pointer _size _uint32 _pointer -> _int32))
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
(define-pancake pancake_peer_register_import (_fun _pointer _uint64 -> _int32))
(define-pancake pancake_peer_peek_event (_fun _pointer -> _int32))
(define-pancake pancake_peer_send_deliver
  (_fun _pointer _PancakeReference-pointer _pointer _size _uint32 _uint64 -> _int32))
(define-pancake pancake_peer_send_resolve
  (_fun _pointer _uint64 _uint32 _PancakeArgument-pointer/null _pointer _size -> _int32))
(define-pancake pancake_peer_poll_event_deliver (_fun _pointer _PancakeDeliver-pointer -> _int32))
(define-pancake pancake_peer_poll_event_resolve (_fun _pointer _PancakeResolve-pointer -> _int32))
(define-pancake pancake_deliver_free (_fun _PancakeDeliver-pointer -> _void))
(define-pancake pancake_resolve_free (_fun _PancakeResolve-pointer -> _void))
(define-pancake pancake_peer_register_bootstrap_cap
  (_fun _pointer _pointer _size (out : (_ptr o _uint64)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_netlayer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_tcp_netlayer_release (_fun _pointer -> _void))
(define-pancake pancake_endpoint_tcp_testing_connect
  (_fun _pointer _pointer _size _uint16 _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_endpoint_tcp_testing_listen
  (_fun _pointer _pointer _size _uint16 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_endpoint_tcp_listener_port
  (_fun _pointer (out : (_ptr o _uint16)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_endpoint_tcp_testing_accept
  (_fun _pointer _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_endpoint_tcp_read_frame (_fun _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake pancake_endpoint_tcp_write_frame (_fun _pointer _PancakeFrame-pointer -> _int32))
(define-pancake pancake_endpoint_tcp_conn_close (_fun _pointer -> _void))
(define-pancake pancake_endpoint_tcp_listener_close (_fun _pointer -> _void))

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
     (define buf (make-bytes len))
     (define written (pancake_last_error buf len))
     (bytes->string/utf-8 (subbytes buf 0 (min written len)) #\uFFFD)]))

(define (clear-last-error) (pancake_clear_last_error))

;; ── Public value vocabulary ──────────────────────────────────────────────────
(struct exn:fail:pancake exn:fail (code))
(define (check code)
  (unless (= code OK)
    (define msg (last-error))   ; capture immediately, before any later call clobbers it
    (raise (exn:fail:pancake
            (if msg
                (format "pancake error ~a: ~a" code msg)
                (format "pancake error ~a" code))
            (current-continuation-marks) code))))

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

;; near/far take an optional promise? flag.
(define (near id [promise #f]) (near-ref id promise))
(define (far id [promise #f]) (far-ref id promise))

;; ── Marshalling (encode) ─────────────────────────────────────────────────────
(define (ref->c ref)
  (cond
    [(near-ref? ref) (make-PancakeReference REF-NEAR (if (near-ref-promise ref) REF-PROMISE-KIND REF-OBJECT) (near-ref-id ref))]
    [(far-ref? ref) (make-PancakeReference REF-FAR (if (far-ref-promise ref) REF-PROMISE-KIND REF-OBJECT) (far-ref-id ref))]
    [(promise-ref? ref) (make-PancakeReference REF-PROMISE 0 (promise-ref-answer ref))]
    [else (check -13) (error "unreachable")]))

;; Returns (values cpointer count), keeping backing buffers alive via `keep`.
(define (args->c args keep)
  (define n (length args))
  (cond
    [(zero? n) (values #f 0)]
    [else
     (define arr (malloc (* n (ctype-sizeof _PancakeArgument)) 'atomic))
     (set-box! keep (cons arr (unbox keep)))
     (for ([a (in-list args)] [i (in-naturals)])
       (ptr-set! arr _PancakeArgument i (arg->c a keep)))
     (values arr n)]))

(define (bytes->c-ptr bs keep)
  (define n (bytes-length bs))
  (define buf (malloc (max n 1) 'atomic))
  (set-box! keep (cons buf (unbox keep)))
  (memcpy buf bs n)
  (values buf n))

(define (arg->c a keep)
  (define c (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0))
  (cond
    [(boolean? a) (set-PancakeArgument-kind! c ARG-BOOLEAN) (set-PancakeArgument-boolean! c (if a 1 0))]
    [(exact-integer? a) (set-PancakeArgument-kind! c ARG-INTEGER) (set-PancakeArgument-integer! c a)]
    [(real? a) (set-PancakeArgument-kind! c ARG-FLOAT64) (set-PancakeArgument-float64! c (exact->inexact a))]
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
    [else (check -13)])
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
    [(= k ARG-STRING) (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)))]
    [(= k ARG-SYMBOL) (sym (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))))]
    [(= k ARG-REFERENCE) (ref<-c (PancakeArgument-reference c))]
    [(= k ARG-LIST) (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c))]
    [(= k ARG-SET) (pset (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-TAGGED) (tagged-arg (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)))
                                  (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-KEYWORD) (kw (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))))]
    [(= k ARG-VOID) (void)]
    [else (error 'arg<-c "unrecognized argument kind: ~a" k)]))

(define (args<-c ptr len)
  (if (or (not ptr) (zero? len)) '()
      (for/list ([i (in-range len)]) (arg<-c (ptr-ref ptr _PancakeArgument i)))))

;; ── The allocation context ───────────────────────────────────────────────────
;; A context owns allocation policy for the handles created in it. Peers and
;; netlayers made with `make-peer/in` / `make-netlayer/in` route every
;; allocation through it, so the context must outlive them. `keep` retains the
;; allocator cstruct and its callback trampolines for the custom-allocator path
;; (the library may invoke them until release); it is #f for the default path.
(struct context (handle keep) #:mutable)

(define (make-context)
  (define-values (rc h) (pancake_context_new_default))
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
  ;; Retain the cstruct (and through it the callbacks) until release.
  (define ctx (context h allocator))
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

(define (make-peer)
  (define-values (rc h) (pancake_peer_new))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

(define (make-peer/in ctx)
  (define-values (rc h) (pancake_peer_new_in (context-handle ctx)))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

;; A negotiating peer, awaiting the keyed op:start-session handshake — the peer
;; to drive when the partner requires it (a real Goblins vat). Pair it with
;; `peer-start-session-keyed!`, then pump until `peer-session-open?`.
(define (make-peer/negotiating)
  (define-values (rc h) (pancake_peer_new_negotiating))
  (check rc)
  (define p (peer h))
  (register-finalizer p (lambda (q) (peer-release! q)))
  p)

(define (peer-release! p)
  (when (peer-handle p)
    (pancake_peer_release (peer-handle p))
    (set-peer-handle! p #f)))

(define (peer-register-export! p id) (check (pancake_peer_register_export (peer-handle p) id)))
(define (peer-register-import! p id) (check (pancake_peer_register_import (peer-handle p) id)))

;; Sign and queue a keyed op:start-session from a negotiating peer over the
;; canonical v1.0 wire. `seed` is a 32-byte bytestring (the session key);
;; `transport`/`designator` form the locator the partner verifies — for a Goblins
;; partner, "tcp" with `hints-empty-false?` #t (an empty hints map encoded as
;; `#f`). Flush it, then pump until `peer-session-open?`.
(define (peer-start-session-keyed! p seed
                                   #:designator designator
                                   #:transport [transport "tcp"]
                                   #:hints-empty-false? [hints-empty-false? #t])
  (unless (= (bytes-length seed) 32)
    (error 'peer-start-session-keyed! "a session seed must be 32 bytes; got ~a" (bytes-length seed)))
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define tbuf (malloc (max (bytes-length tb) 1) 'atomic)) (memcpy tbuf tb (bytes-length tb))
  (define dbuf (malloc (max (bytes-length db) 1) 'atomic)) (memcpy dbuf db (bytes-length db))
  (define sbuf (malloc 32 'atomic)) (memcpy sbuf seed 32)
  (check (pancake_peer_start_session_keyed
          (peer-handle p) 0
          tbuf (bytes-length tb)
          dbuf (bytes-length db)
          (if hints-empty-false? 1 0)
          sbuf)))

;; Whether the keyed handshake has completed and the session is open for traffic.
(define (peer-session-open? p)
  (define rc (pancake_peer_session_is_open (peer-handle p)))
  (when (< rc 0) (check rc))
  (= rc 1))

(define (peer-feed! p frame)
  (define buf (malloc (max (bytes-length frame) 1) 'atomic))
  (memcpy buf frame (bytes-length frame))
  (check (pancake_peer_feed_borrowed (peer-handle p) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

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
       (hash-remove! owned-frame-releases (PancakeManagedFrame-release frame)))
     _PancakeReleaseFn))
  (hash-set! owned-frame-releases release-cb #t)
  (define mf (make-PancakeManagedFrame buf len FRAME-SHAPE-BYTE release-cb #f))
  (define rc (pancake_peer_feed_owned (peer-handle p) mf))
  (cond
    [(= rc OK) (void)]            ; library now owns buf; it will invoke release-cb
    [else
     (free buf)
     (hash-remove! owned-frame-releases release-cb)
     (check rc)]))

(define (peer-step! p) (check (pancake_peer_step (peer-handle p))))

;; Feed buffered wire bytes; the peer frames and dispatches one whole frame if
;; present. Returns the consumed byte count on OK, #f on WOULD-BLOCK (the buffer
;; holds only a partial frame), and raises (via `check`) on any other code.
(define (peer-recv-stream! p bs)
  (define len (bytes-length bs))
  (define buf (malloc (max len 1) 'atomic))
  (memcpy buf bs len)
  (define-values (r consumed) (pancake_peer_recv_stream (peer-handle p) buf len))
  (cond
    [(= r OK) consumed]
    [(= r WOULD-BLOCK) #f]
    [else (check r) (error "unreachable")]))

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
     (define buf (malloc (max (bytes-length msg) 1) 'atomic))
     (memcpy buf msg (bytes-length msg))
     (check (pancake_peer_send_resolve (peer-handle p) answer RESOLUTION-BREAK #f buf (bytes-length msg)))]))

(define (peer-take-outbound p)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (cond
    [(not (= OK (pancake_peer_take_outbound (peer-handle p) mf))) #f]
    [else
     (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
     (pancake_managed_frame_release mf)
     out]))

(define (peer-poll p)
  (define kind (pancake_peer_peek_event (peer-handle p)))
  (cond
    [(= kind EVENT-DELIVER) (poll-deliver p)]
    [(= kind EVENT-RESOLVE) (poll-resolve p)]
    [(= kind WOULD-BLOCK) #f]
    [else (poll-other p)]))

(define (poll-deliver p)
  (define d (make-PancakeDeliver (make-PancakeReference 0 0 0) #f 0 0 0 #f))
  (check (pancake_peer_poll_event_deliver (peer-handle p) d))
  (define ev (deliver-event (ref<-c (PancakeDeliver-target d))
                            (args<-c (PancakeDeliver-args d) (PancakeDeliver-args-len d))
                            (if (zero? (PancakeDeliver-has-answer d)) #f (PancakeDeliver-answer d))))
  (pancake_deliver_free d)
  ev)

(define (poll-resolve p)
  (define r (make-PancakeResolve 0 0 (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0) #f 0 #f))
  (check (pancake_peer_poll_event_resolve (peer-handle p) r))
  (define res
    (if (= (PancakeResolve-resolution-kind r) RESOLUTION-FULFILL)
        (fulfill (arg<-c (PancakeResolve-fulfill r)))
        (brk (bytes->string/utf-8 (bytes<-c (PancakeResolve-break-message r) (PancakeResolve-break-message-len r))))))
  (define ev (resolve-event (PancakeResolve-answer r) res))
  (pancake_resolve_free r)
  ev)

(define (poll-other p)
  (define e (make-PancakeEvent 0 (make-PancakeManagedFrame #f 0 0 #f #f)))
  (pancake_peer_poll_event (peer-handle p) e)
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
;; id. `peer` is the bound peer (or #f for a pure-local vat), and `next-answer`
;; allocates fresh answer positions for far sends.
(struct vat (peer cells next queue listeners far-listeners exports next-answer) #:transparent)

;; (make-vat #:peer p) — a vat, optionally bound to a peer for far sends and
;; hosting. Far-send answers start at 1000 to stay clear of answers a partner
;; allocates for its own calls.
(define (make-vat #:peer [peer #f])
  (vat peer (make-hasheqv) (box 1) (box '()) (make-hasheqv) (make-hasheqv) (make-hasheqv) (box 1000)))

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
  (define answer (and answer? (let ([a (unbox (vat-next-answer v))])
                                (set-box! (vat-next-answer v) (add1 a)) a)))
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
  chained)

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
(provide CODEC-SYRUP
         make-netlayer make-netlayer/in netlayer-release! netlayer-listen netlayer-connect
         listener-port listener-accept listener-close!
         conn-read-frame conn-write-frame! conn-close!
         peer-register-bootstrap-cap!)

(define CODEC-SYRUP 0)

(struct netlayer (handle) #:mutable)
(struct listener (handle) #:mutable)
(struct conn (handle) #:mutable)

(define (host->ptr host)
  (define bs (string->bytes/utf-8 host))
  (define buf (malloc (max (bytes-length bs) 1) 'atomic))
  (memcpy buf bs (bytes-length bs))
  (values buf (bytes-length bs)))

(define (make-netlayer)
  (define-values (rc h) (pancake_tcp_netlayer_new))
  (check rc)
  (netlayer h))

(define (make-netlayer/in ctx)
  (define-values (rc h) (pancake_tcp_netlayer_new_in (context-handle ctx)))
  (check rc)
  (netlayer h))

(define (netlayer-release! nl)
  (when (netlayer-handle nl)
    (pancake_tcp_netlayer_release (netlayer-handle nl))
    (set-netlayer-handle! nl #f)))

(define (netlayer-listen nl host [port 0])
  (define-values (buf n) (host->ptr host))
  (define-values (rc h) (pancake_endpoint_tcp_testing_listen (netlayer-handle nl) buf n port))
  (check rc)
  (listener h))

(define (netlayer-connect nl host port [codec CODEC-SYRUP] [max-frame 4096])
  (define-values (buf n) (host->ptr host))
  (define-values (rc h) (pancake_endpoint_tcp_testing_connect (netlayer-handle nl) buf n port codec max-frame))
  (check rc)
  (conn h))

(define (listener-port lst)
  (define-values (rc port) (pancake_endpoint_tcp_listener_port (listener-handle lst)))
  (check rc)
  port)

(define (listener-accept lst [codec CODEC-SYRUP] [max-frame 4096])
  (define-values (rc h) (pancake_endpoint_tcp_testing_accept (listener-handle lst) codec max-frame))
  (check rc)
  (conn h))

(define (listener-close! lst)
  (when (listener-handle lst)
    (pancake_endpoint_tcp_listener_close (listener-handle lst))
    (set-listener-handle! lst #f)))

(define (conn-read-frame cn)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (check (pancake_endpoint_tcp_read_frame (conn-handle cn) mf))
  (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
  (pancake_managed_frame_release mf)
  out)

(define (conn-write-frame! cn frame)
  (define buf (malloc (max (bytes-length frame) 1) 'atomic))
  (memcpy buf frame (bytes-length frame))
  (check (pancake_endpoint_tcp_write_frame (conn-handle cn) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

(define (conn-close! cn)
  (when (conn-handle cn)
    (pancake_endpoint_tcp_conn_close (conn-handle cn))
    (set-conn-handle! cn #f)))

(define (peer-register-bootstrap-cap! p swissnum)
  (define buf (malloc (max (bytes-length swissnum) 1) 'atomic))
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
;; is driven from one thread (the peer is a single-owner state machine).
(struct async-connection (peer in out [inbox #:mutable]) #:transparent)

;; Connect to host:port and wrap a fresh peer driven over the connection.
(define (async-connect host port)
  (define-values (in out) (tcp-connect host port))
  (async-connection (make-peer) in out #""))

;; Wrap a peer you have configured (exports/imports/bootstrap caps) and an
;; accepted port pair.
(define (async-connection/ports peer in out)
  (async-connection peer in out #""))

;; Encode pending outbound work and write every queued frame to the wire.
(define (async-pump-outbound! conn)
  (define p (async-connection-peer conn))
  (define out (async-connection-out conn))
  (peer-step! p)
  (let loop ()
    (define frame (peer-take-outbound p))
    (when frame
      (write-bytes frame out)
      (loop)))
  (flush-output out))

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
  (define in (async-connection-in conn))
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
         [else
          ;; Need more bytes; this blocks for at least one byte (yielding to
          ;; the green-thread scheduler) and returns whatever is ready — it
          ;; does not wait to fill the whole buffer.
          (define buf (make-bytes 65536))
          (define n (read-bytes-avail! buf in))
          (cond
            [(eof-object? n) eof]
            [else
             (set-async-connection-inbox!
              conn (bytes-append (async-connection-inbox conn) (subbytes buf 0 n)))
             (outer)])])])))

;; ── Connection: the application surface ──────────────────────────────────────
;; One object an application holds. It bundles the async connection and a vat, so
;; a consumer never wires peer + vat + ports by hand. `connect`/`fetch`/`conn-spawn`/
;; `conn-serve` are the surface; the Goblins verbs (`spawn`, `$`, `<-`, `on`,
;; `bcom`, `methods`) are unchanged — you use them through the connection's vat.
(provide (struct-out connection)
         connect conn-vat conn-async conn-peer conn-spawn conn-publish
         fetch conn-serve conn-tell connection-close!)

(define BOOTSTRAP-POSITION 0)
(define FIRST-SPAWN-POSITION 32)

(struct connection (async vat [next #:mutable]))

;; Complete the keyed op:start-session handshake over a negotiating peer: sign a
;; tcp locator naming `designator` with a per-connection random session key,
;; flush it, and pump until the partner's start-session opens the session.
;; Entropy is generated here, at the I/O boundary, never in the sans-io core.
(define (open-keyed-session! ac designator)
  (define p (async-connection-peer ac))
  (peer-start-session-keyed! p (crypto-random-bytes 32) #:designator designator)
  (async-flush! ac)
  (let loop ()
    (unless (peer-session-open? p)
      (when (eof-object? (async-next-event ac))
        (error 'connect "connection closed during the OCapN handshake"))
      (loop))))

;; Dial host:port, complete the keyed OCapN handshake, and return a ready
;; connection with its vat wired. The session is open (the op:start-session
;; exchange has completed) before this returns — the same handshake a real
;; Goblins peer requires.
(define (connect host port)
  (define-values (in out) (tcp-connect host port))
  (define peer (make-peer/negotiating))
  (define ac (async-connection/ports peer in out))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (open-keyed-session! ac (format "~a:~a" local-host local-port))
  (connection ac (make-vat #:peer peer) FIRST-SPAWN-POSITION))

(define (conn-async c) (connection-async c))
(define (conn-vat c) (connection-vat c))
(define (conn-peer c) (async-connection-peer (connection-async c)))

(define (connection-close! c)
  (define ac (connection-async c))
  (close-output-port (async-connection-out ac))
  (close-input-port (async-connection-in ac)))

;; Spawn a local actor at a fresh export position and return a near capability to
;; hand a partner. `(conn-spawn c ^name arg …)` constructs like `spawn`.
(define (conn-spawn c constructor . args)
  (define pos (connection-next c))
  (set-connection-next! c (add1 pos))
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (publish! (conn-vat c) actor pos)
  (near pos))

;; Publish an actor fetchable by name (a swiss-number). Returns the near capability.
(define (conn-publish c name constructor . args)
  (define pos (peer-register-bootstrap-cap! (conn-peer c) (string->bytes/utf-8 name)))
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (publish! (conn-vat c) actor pos)
  (near pos))

;; Fetch a partner's published capability by name. Drives the connection until
;; the bootstrap-fetch resolves, then returns the far reference. Single-threaded:
;; it pumps events itself, matching the rest of the Racket binding.
(define (fetch c name)
  (peer-register-import! (conn-peer c) BOOTSTRAP-POSITION)
  (define result (box 'pending))
  (with-vat (conn-vat c)
    (define vow (<- (far BOOTSTRAP-POSITION) 'fetch (string->bytes/utf-8 name)))
    (on vow
        (lambda (ref) (set-box! result ref))
        #:catch (lambda (msg) (set-box! result (cons 'broken msg)))))
  (async-flush! (conn-async c))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'fetch "connection closed before \"~a\" resolved" name))
       (vat-serve! (conn-vat c) ev)
       (loop)]
      [(and (pair? r) (eq? (car r) 'broken)) (error 'fetch "fetch \"~a\" broke: ~a" name (cdr r))]
      [else r])))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. Flushes.
(define (conn-tell c target verb . args)
  (with-vat (conn-vat c) (apply <-np target verb args))
  (async-flush! (conn-async c)))

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
