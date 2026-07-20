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
         "layouts-gen.rkt")
(provide (except-out (all-defined-out) pin-layout! reference-layout argument-layout)
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
(define (call/out ctype init proc)
  (define cell (malloc ctype 'atomic-interior))
  (ptr-set! cell ctype init)
  (define rc (proc cell))
  (values rc (ptr-ref cell ctype)))

;; `specs` is a list of `(cons ctype init)`. `proc` receives one cell per
;; spec, in order, and returns the i32 status code.
(define (call/outs specs proc)
  (define cells
    (for/list ([s (in-list specs)])
      (define cell (malloc (car s) 'atomic-interior))
      (ptr-set! cell (car s) (cdr s))
      cell))
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

(define-cstruct _PancakeReference ([kind _uint32] [sub-kind _uint32] [id _uint64]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeArgument
  ([kind _uint32] [boolean _uint32] [integer _int64] [float64 _double]
   [bytes _pointer] [bytes-len _size] [reference _PancakeReference]
   [items _pointer] [items-len _size]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeHostAction` in pancake_driver.h: one embedder effect popped
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
;; pinned at require time against `want-size` (from `layouts-gen.rkt`,
;; reflected off the real Zig C ABI types) and the field layout hand-copied
;; here — so the gate catches a mirror that drifts from its documented layout
;; (a mis-swept field, a wrong ctype), not a C-side change that updates
;; neither; the dogfoods defend that behaviorally. `ctype->layout` reads the
;; struct as declared, so a reordered or retyped field fails here even when
;; the total size happens to survive.
(define (pin-layout! name ctype want-size want-layout)
  (define got-size (ctype-sizeof ctype))
  (define got-layout (ctype->layout ctype))
  (unless (and (= got-size want-size) (equal? got-layout want-layout))
    (error 'pancake
           "FFI layout drift in ~a: size ~a layout ~a, expected size ~a layout ~a; re-mirror the cstruct"
           name got-size got-layout want-size want-layout)))

(define reference-layout '(uint32 uint32 uint64))
(define argument-layout
  `(uint32 uint32 int64 double pointer uint64 ,reference-layout pointer uint64))
(pin-layout! '_PancakeFrame _PancakeFrame PANCAKE-FRAME-SIZE '(pointer uint64 uint32))
(pin-layout! '_PancakeManagedFrame _PancakeManagedFrame PANCAKE-MANAGED-FRAME-SIZE
             '(pointer uint64 uint32 pointer pointer))
(pin-layout! '_PancakeReference _PancakeReference PANCAKE-REFERENCE-SIZE reference-layout)
(pin-layout! '_PancakeArgument _PancakeArgument PANCAKE-ARGUMENT-SIZE argument-layout)
(pin-layout! '_PancakeHostAction _PancakeHostAction PANCAKE-HOST-ACTION-SIZE
             `(uint32 uint64 pointer ,argument-layout pointer uint64))
(pin-layout! '_PancakeLastAbort _PancakeLastAbort PANCAKE-LAST-ABORT-SIZE
             '(uint32 uint32 pointer uint64 pointer uint64 pointer uint64))

;; ── Driver-archive types (pancake_driver.h) ──────────────────────────────────

;; The C behavior callback. `_fun` makes a Racket closure C-callable; the
;; closure must stay reachable while the host may invoke it (the host's
;; strong `keep` table in `private/host.rkt` provides that).
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
             '(pointer fpointer fpointer fpointer fpointer fpointer))

;; PancakeDialPlan: the resolved dial pancake_host_plan_dial hands back.
;; `shape` selects the live fields (HOST-PORT fills host/port, PEER-ID fills
;; addresses/reach); host/addresses borrow the caller's input buffers.
(define-cstruct _PancakeDialPlan
  ([shape _uint32] [host _pointer] [host-len _size] [port _uint16]
   [addresses _pointer] [addresses-len _size]
   [reach-kind _uint32] [reach-value _uint32]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDialPlan _PancakeDialPlan PANCAKE-DIAL-PLAN-SIZE
             '(uint32 pointer uint64 uint16 pointer uint64 uint32 uint32))

;; PancakeAcceptPlan: signing designator + hint from pancake_host_plan_accept.
(define-cstruct _PancakeAcceptPlan
  ([designator _pointer]
   [designator-len _size]
   [direct-addresses-hint _pointer]
   [direct-addresses-hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeAcceptPlan _PancakeAcceptPlan PANCAKE-ACCEPT-PLAN-SIZE
             '(pointer uint64 pointer uint64))

;; Borrowed pending dial view (transport/designator/hint).
(define-cstruct _PancakePendingDial
  ([transport _pointer]
   [transport-len _size]
   [designator _pointer]
   [designator-len _size]
   [hint _pointer]
   [hint-len _size]) #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakePendingDial _PancakePendingDial PANCAKE-PENDING-DIAL-SIZE
             '(pointer uint64 pointer uint64 pointer uint64))
