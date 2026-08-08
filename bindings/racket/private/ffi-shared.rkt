#lang racket/base
;; Internal: the shared C-ABI vocabulary the pancake archives agree on by layout.
;;
;; This module is the binding's one types leaf: every C-visible cstruct and
;; callback type the archives' `_fun` signatures name — frame, reference,
;; argument, host action, last abort, and the driver's plan/dial views and
;; callback types. It declares the *types*, not any bound function, and it
;; opens no library — so requiring it loads nothing, and the generated
;; per-archive tables (`ffi-*-gen.rkt`) can require it below every hand
;; module. Archive path resolve + `ffi-lib` live in `lib-resolve.rkt`.
;;
;; Memory discipline: Racket's collector moves GC-managed memory, so every
;; buffer whose raw address C reads — and every cstruct C reads or writes — is
;; allocated 'atomic-interior, which stays put while a Racket reference is
;; retained; the `keep` lists threaded through the marshalling code provide
;; exactly that reference for the duration C may use the address. Plain
;; 'atomic memory is kept *alive* by a reference but not *in place*, so an
;; address stored into a struct field would dangle when a collection moves the
;; block.
(require ffi/unsafe
         "layouts-gen.rkt"
         ;; The trace record's digest is a fixed-width array, so its width is
         ;; the reflected constant rather than a number retyped here.
         (only-in "constants-gen.rkt" TRACE-DIGEST-BYTES))
(provide (except-out (all-defined-out) pin-layout! normalize-layout)
         ;; Archive loaders (e.g. ffi-iroh) pin their own cstructs with this.
         pin-layout!)

;; Pin `bs` into immobile memory for one synchronous FFI call, returning the
;; buffer (usable even for empty input, where C receives a valid pointer and a
;; zero length). This is the one spelling of "copy bytes where the collector
;; cannot move them"; every borrowed byte input the C side reads goes through it.
(define (pin-immobile bs)
  (define buf (malloc (max (bytes-length bs) 1) 'atomic-interior))
  (when (> (bytes-length bs) 0) (memcpy buf bs (bytes-length bs)))
  buf)

;; The other direction of the same boundary: a bounded copy out of a borrowed
;; C (pointer, length) view into a fresh Racket bytestring, so the result
;; outlives whatever library call owned the view.
(define (bytes<-c ptr len)
  (if (or (not ptr) (zero? len)) #""
      (let ([bs (make-bytes len)]) (memcpy bs ptr len) bs)))

;; Fresh caller-owned out cells for C ABI out-params. Archive loaders wrap
;; every out-bearing stub so callers see `(values rc …)` and never touch the
;; cell. Two green threads sharing one auto-allocated out slot have lost a
;; just-written consumed count (inbox re-feed → live answer-id reuse); the
;; build bans automatic FFI out syntax under bindings/racket.
;; One fresh out cell for `ctype`, seeded with `init`. A cstruct init is a
;; tagged pointer, and the generated stub types that out-param `_ID-pointer`,
;; whose argument conversion refuses an untagged malloc block — so the fresh
;; cell must carry the init's tag before it crosses.
(define (out-cell ctype init)
  (define cell (malloc ctype 'atomic-interior))
  (when (cpointer? init) (cpointer-push-tag! cell (cpointer-tag init)))
  (ptr-set! cell ctype init)
  cell)

(define (call/out ctype init proc)
  (define cell (out-cell ctype init))
  (define rc (proc cell))
  (values rc (ptr-ref cell ctype)))

;; `specs` is a list of `(cons ctype init)`. `proc` receives one cell per
;; spec, in order, and returns the i32 status code.
(define (call/outs specs proc)
  (define cells
    (for/list ([s (in-list specs)])
      (out-cell (car s) (cdr s))))
  (define rc (apply proc cells))
  (apply values rc
         (for/list ([s (in-list specs)] [c (in-list cells)])
           (ptr-ref c (car s)))))

;; Wrap a raw FFI procedure whose last argument is an out cell of `ctype`.
;; The public name takes the preceding args and returns `(values rc out)`.
(define (wrap-out1 raw ctype [init 0])
  (lambda args
    (call/out ctype init (lambda (out) (apply raw (append args (list out)))))))

(define-cstruct _PancakeFrame ([bytes _pointer] [len _size] [shape _uint32]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer] [len _size] [shape _uint32] [release _pointer] [private-data _pointer]) #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeReference ([id _uint64]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeArgument
  ([kind _uint32] [boolean _uint32] [integer _int64] [float64 _double]
   [bytes _pointer] [bytes-len _size] [reference _PancakeReference]
   [items _pointer] [items-len _size]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeHostAction` in pancake_host.h: one embedder effect popped
;; from `pancake_host_next_action`. `kind` selects the live fields; a DIAL
;; action carries only `ticket` (locator bytes come from
;; `pancake_host_pending_dial`); a SETTLE's `value` sub-structure and a
;; FAIL's `message` are host-owned and valid until the next
;; `pancake_host_next_action`, so the binding copies them out immediately.
(define-cstruct _PancakeHostAction
  ([kind _uint32] [ticket _uint64] [conn _pointer]
   [value _PancakeArgument] [message _pointer] [message-len _size]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeLastAbort` in pancake_ocapn.h: two leading u32s, then three
;; (pointer, length) views of process-static strings the library owns.
(define-cstruct _PancakeLastAbort
  ([domain _uint32] [has-kind _uint32]
   [kind-name _pointer] [kind-name-len _size]
   [message _pointer] [message-len _size]
   [error-name _pointer] [error-name-len _size]) #:malloc-mode 'atomic-interior)

;; The layout gate, the Rust mirror's `const` assert block made Racket
;; (bindings/rust/src/sys/driver.rs): every hand-mirrored cstruct above is
;; pinned at require time against the size and the kind layout `layouts-gen.rkt`
;; reflects off the real Zig C ABI types, so what a cstruct is compared with is
;; the ABI itself. `ctype->layout` reads the struct as declared, so a reordered
;; or retyped field fails here even when the total size happens to survive; the
;; dogfoods defend the behavior on top of that.
;;
;; `fpointer` slots normalize to `pointer` on both sides: whether a mirror
;; declares a callback slot `_pointer` or `_fpointer` is a convenience at the
;; declaration, while the ABI fact is that the slot is one pointer wide.
(define (normalize-layout layout)
  (cond [(eq? layout 'fpointer) 'pointer]
        [(pair? layout) (map normalize-layout layout)]
        [(vector? layout)
         (list->vector (map normalize-layout (vector->list layout)))]
        [else layout]))

(define (pin-layout! name ctype want-size want-layout)
  (define got-size (ctype-sizeof ctype))
  (define got-layout (normalize-layout (ctype->layout ctype)))
  (unless (and (= got-size want-size) (equal? got-layout want-layout))
    (error 'pancake
           "FFI layout drift in ~a: size ~a layout ~a, the C ABI says size ~a layout ~a; re-mirror the cstruct"
           name got-size got-layout want-size want-layout)))

(pin-layout! '_PancakeFrame _PancakeFrame PANCAKE-FRAME-SIZE PANCAKE-FRAME-LAYOUT)
(pin-layout! '_PancakeManagedFrame _PancakeManagedFrame PANCAKE-MANAGED-FRAME-SIZE
             PANCAKE-MANAGED-FRAME-LAYOUT)
(pin-layout! '_PancakeReference _PancakeReference PANCAKE-REFERENCE-SIZE
             PANCAKE-REFERENCE-LAYOUT)
(pin-layout! '_PancakeArgument _PancakeArgument PANCAKE-ARGUMENT-SIZE
             PANCAKE-ARGUMENT-LAYOUT)
(pin-layout! '_PancakeHostAction _PancakeHostAction PANCAKE-HOST-ACTION-SIZE
             PANCAKE-HOST-ACTION-LAYOUT)
(pin-layout! '_PancakeLastAbort _PancakeLastAbort PANCAKE-LAST-ABORT-SIZE
             PANCAKE-LAST-ABORT-LAYOUT)

;; ── Driver-archive types (pancake_host.h) ──────────────────────────────────

;; The C behavior callback. `_fun` makes a Racket closure C-callable; the
;; closure must stay reachable while the host may invoke it (the host's
;; strong `keep` table in `private/host.rkt` provides that).
;; PancakeTraceEvent — one live-trace fact (pancake_host_set_trace); the
;; layout facts in layouts-gen.rkt pin the mirror.
(define-cstruct _PancakeTraceEvent
  ([kind _uint32]
   [session _uint64]
   [outbound _uint8]
   [provenance _uint32]
   [codec _uint32]
   [captp-version _uint32]
   [designator _pointer]
   [designator-len _size]
   [transport _pointer]
   [transport-len _size]
   [session-id _pointer]
   [session-id-len _size]
   [verb _pointer]
   [verb-len _size]
   [frame _pointer]
   [frame-len _size]
   [frame-total-len _size]
   [dropped _uint64]
   ;; A tag over the frame's bytes, naming one message across the two peers
   ;; that carried it. Zero on the non-message kinds.
   [digest (_array _uint8 TRACE-DIGEST-BYTES)]) #:malloc-mode 'atomic-interior)

;; PancakeTraceCallback — void (*)(void *ctx, const PancakeTraceEvent *event).
(define _PancakeTraceCallback
  (_fun _pointer _PancakeTraceEvent-pointer -> _void))
(pin-layout! '_PancakeTraceEvent _PancakeTraceEvent PANCAKE-TRACE-EVENT-SIZE
             PANCAKE-TRACE-EVENT-LAYOUT)

(define _PancakeHostBehavior
  (_fun _pointer _pointer _pointer _size _pointer _size _PancakeArgument-pointer -> _int32))

;; Sync arm for pancake_host_pump_drain. Must not await — park decoded work
;; and run I/O after the C loop returns.
(define _PancakeHostPumpArmFn
  (_fun _pointer _pointer _PancakeHostAction-pointer _pointer -> _int32))

;; PancakeHostPumpHooks — five arm slots + caller ctx. Fields are `_fpointer`
;; so `function-ptr` callbacks install cleanly.
(define-cstruct _PancakeHostPumpHooks
  ([ctx _pointer]
   [flush _fpointer] [close _fpointer] [need-gift-id _fpointer]
   [complete _fpointer] [dial _fpointer]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeHostPumpHooks _PancakeHostPumpHooks PANCAKE-HOST-PUMP-HOOKS-SIZE
             PANCAKE-HOST-PUMP-HOOKS-LAYOUT)

;; PancakeDialPlan: the resolved dial pancake_host_plan_dial hands back.
;; `shape` selects the live fields (HOST-PORT fills host/port, PEER-ID fills
;; addresses/reach); host/addresses borrow the caller's input buffers.
(define-cstruct _PancakeDialPlan
  ([shape _uint32] [host _pointer] [host-len _size] [port _uint16]
   [addresses _pointer] [addresses-len _size]
   [reach-kind _uint32] [reach-value _uint32]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDialPlan _PancakeDialPlan PANCAKE-DIAL-PLAN-SIZE
             PANCAKE-DIAL-PLAN-LAYOUT)

;; PancakeAcceptPlan: signing designator + hint from pancake_host_plan_accept.
(define-cstruct _PancakeAcceptPlan
  ([designator _pointer]
   [designator-len _size]
   [direct-addresses-hint _pointer]
   [direct-addresses-hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeAcceptPlan _PancakeAcceptPlan PANCAKE-ACCEPT-PLAN-SIZE
             PANCAKE-ACCEPT-PLAN-LAYOUT)

;; PancakePartnerIdentity: the verified partner identity
;; `pancake_host_session_partner_identity` borrows into, as three (pointer,
;; length) views the session owns. The designator and the locator record may
;; each be NULL with a zero length; the session key is always present when the
;; call succeeded.
(define-cstruct _PancakePartnerIdentity
  ([session-key _pointer]
   [session-key-len _size]
   [designator _pointer]
   [designator-len _size]
   [locator-record _pointer]
   [locator-record-len _size]
   ;; How the durable identity in `designator` was authenticated, one of the
   ;; DURABLE-PROVENANCE-* constants (ADR-0097).
   [provenance _uint32]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakePartnerIdentity _PancakePartnerIdentity PANCAKE-PARTNER-IDENTITY-SIZE
             PANCAKE-PARTNER-IDENTITY-LAYOUT)

;; Borrowed pending dial view (transport/designator/hint).
(define-cstruct _PancakePendingDial
  ([transport _pointer]
   [transport-len _size]
   [designator _pointer]
   [designator-len _size]
   [hint _pointer]
   [hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakePendingDial _PancakePendingDial PANCAKE-PENDING-DIAL-SIZE
             PANCAKE-PENDING-DIAL-LAYOUT)
