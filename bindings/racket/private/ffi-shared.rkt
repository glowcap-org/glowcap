#lang racket/base
;; Internal: the shared C-ABI vocabulary the pancake archives agree on by layout.
;;
;; This module is the Racket mirror of the C ABI's `c_abi/shared` leaf (ADR-0059):
;; the C-visible cstructs the binding consumes — frame, reference, argument,
;; host action, and last abort. It declares the *types*, not any bound
;; function, and it opens no library — so requiring it loads nothing. Each per-archive loader
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
(require ffi/unsafe)
(provide (all-defined-out))

;; Resolve an archive through the cascade every pancake binding shares: an
;; explicit PANCAKE_LIB_DIR override (configure) wins, else the repo's
;; zig-out/lib build output passed as `dev` (the dev fallback, an extension-less
;; runtime path), else the bare library name handed to the OS dynamic-linker
;; search (find). `stem` is the archive stem without the platform `lib`/suffix
;; decoration; `ffi-lib` appends the platform-correct suffix in every case.
;; `fail` customizes the final error (the iroh loader names its build step).
(define (pancake-ffi-lib stem dev #:fail [fail #f])
  (define (try spec) (ffi-lib spec #:fail (lambda () #f)))
  (define name (string-append "lib" stem))
  (or (let ([dir (getenv "PANCAKE_LIB_DIR")])
        (and dir (try (build-path dir name))))
      (try dev)
      (ffi-lib name #:fail
               (or fail
                   (lambda ()
                     (error 'pancake "could not load ~a from PANCAKE_LIB_DIR, zig-out/lib, or the system library path" name))))))

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
;; pinned at require time against the LP64 size and field layout the C headers
;; document, hand-copied here — so the gate catches a mirror that drifts from
;; its documented layout (a mis-swept field, a wrong ctype), not a C-side
;; change that updates neither; the dogfoods defend that behaviorally.
;; `ctype->layout` reads the struct as declared, so a reordered or retyped
;; field fails here even when the total size happens to survive.
(define (pin-layout! name ctype want-size want-layout)
  (define got-size (ctype-sizeof ctype))
  (define got-layout (ctype->layout ctype))
  (unless (and (= got-size want-size) (equal? got-layout want-layout))
    (error 'pancake
           "FFI layout drift in ~a: size ~a layout ~a, the C header says size ~a layout ~a; re-mirror the cstruct"
           name got-size got-layout want-size want-layout)))

(define reference-layout '(uint32 uint32 uint64))
(define argument-layout
  `(uint32 uint32 int64 double pointer uint64 ,reference-layout pointer uint64))
(pin-layout! '_PancakeFrame _PancakeFrame 24 '(pointer uint64 uint32))
(pin-layout! '_PancakeManagedFrame _PancakeManagedFrame 40 '(pointer uint64 uint32 pointer pointer))
(pin-layout! '_PancakeReference _PancakeReference 16 reference-layout)
(pin-layout! '_PancakeArgument _PancakeArgument 72 argument-layout)
(pin-layout! '_PancakeHostAction _PancakeHostAction 176
             `(uint32 uint64 pointer
               pointer uint64 pointer uint64 pointer uint64 pointer uint64
               ,argument-layout pointer uint64))
(pin-layout! '_PancakeLastAbort _PancakeLastAbort 56
             '(uint32 uint32 pointer uint64 pointer uint64 pointer uint64))
