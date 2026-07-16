#lang racket/base
;; Internal: the shared C-ABI vocabulary the pancake archives agree on by layout.
;;
;; This module is the Racket mirror of the C ABI's `c_abi/shared` leaf (ADR-0059):
;; the C-visible cstructs the binding consumes — frame, reference, argument,
;; host action, and last abort. It declares the *types*, not any bound
;; function, and it opens no library — so requiring it loads nothing. Archive
;; path resolve + `ffi-lib` live in `lib-resolve.rkt`. Each per-archive loader
;; (`ffi-ocapn.rkt`, `ffi-tcp.rkt`, `ffi-inproc.rkt`, `ffi-iroh.rkt`) requires this
;; for the cstruct types its `_fun` signatures name, exactly as the C archives
;; share these layouts without sharing a symbol.
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
;; action's byte views — the full locator URI plus its parsed transport,
;; designator, and direct-addresses hint — a SETTLE's `value` sub-structure,
;; and a FAIL's `message` are host-owned and valid until the next
;; `pancake_host_next_action`, so the binding copies them out immediately.
(define-cstruct _PancakeHostAction
  ([kind _uint32] [ticket _uint64] [conn _pointer]
   [locator _pointer] [locator-len _size]
   [transport _pointer] [transport-len _size]
   [designator _pointer] [designator-len _size]
   [direct-addresses-hint _pointer] [direct-addresses-hint-len _size]
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
             `(uint32 uint64 pointer
               pointer uint64 pointer uint64 pointer uint64 pointer uint64
               ,argument-layout pointer uint64))
(pin-layout! '_PancakeLastAbort _PancakeLastAbort PANCAKE-LAST-ABORT-SIZE
             '(uint32 uint32 pointer uint64 pointer uint64 pointer uint64))
