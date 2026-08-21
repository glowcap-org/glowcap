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
(provide (except-out (all-defined-out) normalize-layout)
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

;; An immobile block of `cap` bytes for a C call to write into, read back with
;; `bytes<-c` once the call returns.
;;
;; Neither of the two nearby shapes works for an out buffer on a call marked
;; `#:blocking?`. `pin-immobile` copies inbound, so the callee's write lands in a
;; block nobody reads back, and the length out-params still report the write, which
;; is what makes the mistake look like success. Handing the callee a Racket
;; bytestring directly is right only where the collector cannot run during the
;; call, and a blocking call is exactly where it can.
(define (out-immobile cap) (malloc (max cap 1) 'atomic-interior))

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

;; Omit the C transport ABI's optional caller-buffer diagnostic. Racket's
;; synchronous FFI wrappers read the archive-local last-error slot on the same
;; calling thread; worker-dispatched runtimes supply these three arguments.
(define (call/without-diagnostic raw . args)
  (apply raw (append args (list #f 0 #f))))

(define-cstruct _PancakeFrame ([bytes _pointer] [len _size] [shape _uint32]) #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeManagedFrame
  ([bytes _pointer] [len _size] [shape _uint32] [release _pointer] [private-data _pointer]) #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeReference ([id _uint64]) #:malloc-mode 'atomic-interior)

;; Mirrors `PancakeOnionConfig`, whose Zig declaration in
;; `src/c_abi/net_transport/onion/mod.zig` documents every field. Every pointer is
;; borrowed for the constructor call only, because the netlayer copies the text it
;; needs; `'atomic-interior` keeps the struct itself immobile for that call.
(define-cstruct _PancakeOnionConfig
  ([socks _pointer] [socks_len _size]
   [control_endpoint _pointer] [control_endpoint_len _size]
   [auth_kind _uint32]
   [auth_secret _pointer] [auth_secret_len _size]
   [service_key _pointer] [service_key_len _size]
   [forward _pointer] [forward_len _size])
  #:malloc-mode 'atomic-interior)

;; Mirrors `PancakeRelayConfig`: one archive-owned runtime serves both
;; keyed-relay and noise-relay. The constructor copies both URL views before
;; returning, so the pinned buffers are call-local.
(define-cstruct _PancakeRelayConfig
  ([abi_version _uint32] [struct_size _size]
   [relay_url _pointer] [relay_url_len _size]
   [register_url _pointer] [register_url_len _size]
   [trust _uint32]
   [trust_pem _pointer] [trust_pem_len _size])
  #:malloc-mode 'atomic-interior)
(define-cstruct _PancakeRelayTrustSummary
  ([loaded _size]
   [skipped_by_engine _size]
   [first_skipped_engine_code _int32])
  #:malloc-mode 'atomic-interior)
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
  ([kind _uint32] [ticket _uint64] [session _pointer]
   [value _PancakeArgument] [message _pointer] [message-len _size]
   [result _int32]) #:malloc-mode 'atomic-interior)
;; Mirrors `PancakeLastAbort` in pancake_ocapn.h: two leading u32s, five
;; (pointer, length) views of process-static strings the library owns, then a
;; bounded secondary-failure count.
(define-cstruct _PancakeLastAbort
  ([domain _uint32] [has-kind _uint32]
   [kind-name _pointer] [kind-name-len _size]
   [message _pointer] [message-len _size]
   [error-name _pointer] [error-name-len _size]
   [abort-delivery-error-name _pointer] [abort-delivery-error-name-len _size]
   [secondary-error-name _pointer] [secondary-error-name-len _size]
   [secondary-error-count _uint32]) #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeFailureReport
  ([abi-version _uint32] [struct-size _size]
   [layer _uint32] [scope-kind _uint32]
   [scope-id _uint64] [operation-id _uint64]
   [primary-result _int32] [secondary-result _int32]
   [secondary-count _uint32]
   [operation _pointer] [operation-len _size]
   [primary-name _pointer] [primary-name-len _size]
   [primary-message _pointer] [primary-message-len _size]
   [secondary-name _pointer] [secondary-name-len _size]
   [secondary-message _pointer] [secondary-message-len _size])
  #:malloc-mode 'atomic-interior)

(define-cstruct _PancakeFailureEvent
  ([abi-version _uint32] [struct-size _size]
   [sequence _uint64] [dropped-before _uint64]
   [layer _uint32] [scope-kind _uint32]
   [scope-id _uint64] [operation-id _uint64]
   [primary-result _int32] [secondary-result _int32]
   [secondary-count _uint32] [flags _uint32]
   [operation _pointer] [operation-len _size]
   [primary-name _pointer] [primary-name-len _size]
   [primary-message _pointer] [primary-message-len _size]
   [secondary-name _pointer] [secondary-name-len _size]
   [secondary-message _pointer] [secondary-message-len _size])
  #:malloc-mode 'atomic-interior)

;; Caller-owned deterministic provider-install and loop-release outcome. The
;; pointed-to names are process-lifetime stable and copied by the runtime tier
;; before another native call can retire the record.
(define-cstruct _PancakeDriverFailure
  ([abi-version _uint32] [struct-size _size]
   [primary-result _int32] [secondary-result _int32]
   [secondary-count _uint32]
   [carrier-phase _uint32] [carrier-detail-flags _uint32]
   [carrier-verification-flags _uint32] [carrier-peer-alert _uint32]
   [carrier-engine-code _int32]
   [primary-name _pointer] [primary-name-len _size]
   [secondary-name _pointer] [secondary-name-len _size])
  #:malloc-mode 'atomic-interior)

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
(pin-layout! '_PancakeFailureReport _PancakeFailureReport PANCAKE-FAILURE-REPORT-SIZE
             PANCAKE-FAILURE-REPORT-LAYOUT)
(pin-layout! '_PancakeFailureEvent _PancakeFailureEvent PANCAKE-FAILURE-EVENT-SIZE
             PANCAKE-FAILURE-EVENT-LAYOUT)
(pin-layout! '_PancakeDriverFailure _PancakeDriverFailure
             PANCAKE-DRIVER-FAILURE-SIZE PANCAKE-DRIVER-FAILURE-LAYOUT)
(pin-layout! '_PancakeRelayConfig _PancakeRelayConfig
             PANCAKE-RELAY-CONFIG-SIZE PANCAKE-RELAY-CONFIG-LAYOUT)
(pin-layout! '_PancakeRelayTrustSummary _PancakeRelayTrustSummary
             PANCAKE-RELAY-TRUST-SUMMARY-SIZE PANCAKE-RELAY-TRUST-SUMMARY-LAYOUT)

;; ── Driver-archive types (pancake_host.h) ──────────────────────────────────

;; The C behavior callback. `_fun` makes a Racket closure C-callable; the
;; closure must stay reachable while the host may invoke it (the host's
;; strong `keep` table in `private/host/state.rkt` provides that).
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

;; ── Loop-archive types (pancake_driver.h, ADR-0112) ────────────────────────

(define-cstruct _PancakeDriverOptions
  ([abi-version _uint32] [struct-size _size]
   [wire-buffer-bytes _size] [max-pending-opens _size]
   [handshake-ms _uint32] [listener-setup-ms _uint32] [settle-ms _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDriverOptions _PancakeDriverOptions PANCAKE-DRIVER-OPTIONS-SIZE
             PANCAKE-DRIVER-OPTIONS-LAYOUT)

(define-cstruct _PancakeCloseOptions
  ([abi-version _uint32] [struct-size _size]
   [pending _uint32] [grace-mode _uint32] [grace-ms _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeCloseOptions _PancakeCloseOptions
             PANCAKE-CLOSE-OPTIONS-SIZE PANCAKE-CLOSE-OPTIONS-LAYOUT)

;; PancakeDriverEvent: one drained loop event. `kind` selects the live fields;
;; OPENED/OPEN_FAILED use `operation-id`, while ACCEPTED and listener setup use
;; `listener-id`. A COMPLETION carries the byte-fed queue's own SETTLE/FAIL
;; shape in `action`. Every borrowed failure name and action view dies at the
;; next `pancake_driver_next_event`, so the loop copies it
;; out immediately.
(define-cstruct _PancakeDriverEvent
  ([kind _uint32] [primary-result _int32]
   [secondary-result _int32] [secondary-count _uint32]
   [carrier-phase _uint32] [carrier-detail-flags _uint32]
   [carrier-verification-flags _uint32] [carrier-peer-alert _uint32]
   [carrier-engine-code _int32]
   [operation-id _uint64] [listener-id _uint64] [session _pointer]
   [action _PancakeHostAction]
   [primary-name _pointer] [primary-name-len _size]
   [secondary-name _pointer] [secondary-name-len _size])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeDriverEvent _PancakeDriverEvent PANCAKE-DRIVER-EVENT-SIZE
             PANCAKE-DRIVER-EVENT-LAYOUT)

(define-cstruct _PancakeLocatorHintView
  ([name _pointer] [name-len _size] [kind _uint32]
   [bytes _pointer] [bytes-len _size] [boolean-value _uint8] [integer-value _int64])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeLocatorHintView _PancakeLocatorHintView
             PANCAKE-LOCATOR-HINT-VIEW-SIZE PANCAKE-LOCATOR-HINT-VIEW-LAYOUT)

(define-cstruct _PancakeLocatorView
  ([abi-version _uint32] [struct-size _size]
   [transport _pointer] [transport-len _size]
   [designator _pointer] [designator-len _size]
   [hints _pointer] [hint-count _size] [hint-wire-form _uint32])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeLocatorView _PancakeLocatorView
             PANCAKE-LOCATOR-VIEW-SIZE PANCAKE-LOCATOR-VIEW-LAYOUT)

;; The only transport shape a binding mirrors. Execution-model tables stay
;; private to transport archives and the driver.
(define-cstruct _PancakeTransportOperationOptions
  ([data _pointer] [size _size])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeTransportOperationOptions _PancakeTransportOperationOptions
             PANCAKE-TRANSPORT-OPERATION-OPTIONS-SIZE
             PANCAKE-TRANSPORT-OPERATION-OPTIONS-LAYOUT)

(define-cstruct _PancakeTransportProvider
  ([abi-version _uint32] [struct-size _size]
   [entries _pointer] [entry-count _size]
   [lease-ctx _pointer] [same-configuration _pointer]
   [retain _pointer] [release _pointer])
  #:malloc-mode 'atomic-interior)
(pin-layout! '_PancakeTransportProvider _PancakeTransportProvider
             PANCAKE-TRANSPORT-PROVIDER-SIZE PANCAKE-TRANSPORT-PROVIDER-LAYOUT)
