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
         racket/tcp)

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out deliver-event) (struct-out resolve-event) (struct-out other-event)
         (struct-out fulfill) (struct-out brk)
         abi-version last-error clear-last-error
         make-context make-context/allocator context-release!
         make-peer make-peer/in peer-release!
         peer-register-export! peer-register-import!
         peer-feed! peer-feed-owned! peer-step! peer-send-deliver! peer-send-resolve!
         peer-take-outbound peer-poll peer-recv-stream!
         exn:fail:pancake?
         (struct-out async-connection)
         async-connect async-connection/ports
         async-send-deliver! async-send-resolve! async-next-event)

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
(define-runtime-path lib-path "../../zig-out/lib/libpancake.so")
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

(define (peer-release! p)
  (when (peer-handle p)
    (pancake_peer_release (peer-handle p))
    (set-peer-handle! p #f)))

(define (peer-register-export! p id) (check (pancake_peer_register_export (peer-handle p) id)))
(define (peer-register-import! p id) (check (pancake_peer_register_import (peer-handle p) id)))

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
  (pancake_peer_poll_event_deliver (peer-handle p) d)
  (define ev (deliver-event (ref<-c (PancakeDeliver-target d))
                            (args<-c (PancakeDeliver-args d) (PancakeDeliver-args-len d))
                            (if (zero? (PancakeDeliver-has-answer d)) #f (PancakeDeliver-answer d))))
  (pancake_deliver_free d)
  ev)

(define (poll-resolve p)
  (define r (make-PancakeResolve 0 0 (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0) #f 0 #f))
  (pancake_peer_poll_event_resolve (peer-handle p) r)
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

;; Queue a call to `target` and flush it to the wire. `answer` requests a reply.
(define (async-send-deliver! conn target args #:answer [answer #f])
  (peer-send-deliver! (async-connection-peer conn) target args #:answer answer)
  (async-pump-outbound! conn))

;; Queue a reply settling `answer` and flush it to the wire.
(define (async-send-resolve! conn answer resolution)
  (peer-send-resolve! (async-connection-peer conn) answer resolution)
  (async-pump-outbound! conn))

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
