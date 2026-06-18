#lang racket/base
;; Internal: the shared C-ABI vocabulary the pancake archives agree on by layout.
;;
;; This module is the Racket mirror of the C ABI's `c_abi/shared` leaf (ADR-0059):
;; the C-visible frame, allocator, reference, argument, and event cstructs every
;; archive reuses. It declares the *types*, not any bound function, and it opens
;; no library — so requiring it loads nothing. Each per-archive loader
;; (`ffi-core.rkt`, `ffi-tcp.rkt`, `ffi-inproc.rkt`, `ffi-iroh.rkt`) requires this
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
;; decoration; `ffi-lib` appends the platform-correct suffix in every case. The
;; cached-download "ship" leg drops in between override and dev later. `fail`
;; customizes the final error (the iroh loader names its build step).
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
;; Mirrors `PancakeEnlivenStart` in pancake_ocapn.h: the dedup-cache outcome of a
;; `prepare_enliven`. `status` selects the live fields — `answer` on FRESH/IN_FLIGHT,
;; `import-position`/`kind` on CACHED (a REF_SUB_* value).
(define-cstruct _PancakeEnlivenStart
  ([status _uint32] [kind _uint32] [answer _uint64] [import-position _uint64]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeArgument
  ([kind _uint32] [boolean _uint32] [integer _int64] [float64 _double]
   [bytes _pointer] [bytes-len _size] [reference _PancakeReference]
   [items _pointer] [items-len _size]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeDeliver
  ([target _PancakeReference] [args _pointer] [args-len _size]
   [has-answer _uint32] [answer _uint64] [owner _pointer]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeHandoffGive` in pancake_ocapn.h: three (pointer, length) views.
;; Carried by value inside `PancakeResolve`, so its 48 bytes are part of that
;; struct's layout even when the binding never reads a handoff — dropping it
;; makes `_PancakeResolve` too small and `poll_event_resolve` writes past it.
(define-cstruct _PancakeHandoffGive
  ([give _pointer] [give-len _size]
   [exporter-locator _pointer] [exporter-locator-len _size]
   [recipient-key _pointer] [recipient-key-len _size]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeResolve
  ([answer _uint64] [resolution-kind _uint32] [fulfill _PancakeArgument]
   [break-message _pointer] [break-message-len _size]
   [handoff _PancakeHandoffGive] [owner _pointer]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeLastAbort` in pancake_ocapn.h: two leading u32s, then three
;; (pointer, length) views of process-static strings the library owns.
(define-cstruct _PancakeLastAbort
  ([domain _uint32] [has-kind _uint32]
   [kind-name _pointer] [kind-name-len _size]
   [message _pointer] [message-len _size]
   [error-name _pointer] [error-name-len _size]) #:malloc-mode 'atomic-interior)
