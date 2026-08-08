#lang racket/base
;; Internal: the native-value argument codec. Marshals Racket values to and from
;; the C `PancakeArgument`/`PancakeReference` cstructs, keeping pinned backing
;; buffers alive through a `keep` box for the extent of a synchronous C call.
;; `codec-id` (the codec symbol's ABI spelling) rides the transport seam; the
;; rest is binding-internal.

(require ffi/unsafe
         "constants.rkt"
         "ffi-ocapn.rkt"
         "value.rkt"
         "errors.rkt")

(provide (all-defined-out))

;; The Unicode replacement character used as the decode fallback for invalid
;; UTF-8 in a borrowed wire view.
(define UFFFD (integer->char #xFFFD))

;; The ABI spelling of a codec symbol, for the transport endpoints that take a
;; PANCAKE_CODEC_* selector.
;; The `PANCAKE-CAPTP-*` id for a CapTP profile (ADR-0003): `v1_0` is the
;; interop floor a Goblins vat speaks, `next` the pancake-to-pancake track
;; `Offer.native` prefers with Cap'n Proto.
(define (captp-version-id version)
  (case version
    [(v1_0) CAPTP-V1-0]
    [(next) CAPTP-NEXT]
    [else (error 'captp-version-id "unknown CapTP version: ~a" version)]))

(define (codec-id codec)
  (case codec
    [(syrup) CODEC-SYRUP]
    [(capnp) CODEC-CAPNP]
    [else (error 'codec-id "unknown OCapN codec: ~a" codec)]))

(define (feature-mask features)
  (cond
    [(eq? features 'full) FEATURE-FULL]
    [(eq? features 'minimum) FEATURE-MINIMUM]
    [(exact-nonnegative-integer? features)
     (unless (zero? (bitwise-and features (bitwise-not FEATURE-FULL)))
       (error 'feature-mask "unknown OCapN feature mask: ~a" features))
     features]
    [else
     (for/fold ([mask 0]) ([feature (in-list features)])
       (bitwise-ior
        mask
        (case feature
          [(pipelining) FEATURE-PIPELINING]
          [(handoff) FEATURE-HANDOFF]
          [(wire_delta) FEATURE-WIRE-DELTA]
          [(sturdyref) FEATURE-STURDYREF]
          [else (error 'feature-mask "unknown OCapN feature: ~a" feature)])))]))

;; ── Marshalling (encode) ─────────────────────────────────────────────────────
(define (ref->c ref)
  (unless (ref? ref)
    (raise-pancake 'ref->c ERR-UNSUPPORTED-VALUE
                    "unsupported reference type: ~a" ref))
  (when (ref-released? ref)
    (error 'pancake "this capability was released"))
  (make-PancakeReference (ref-id ref)))

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

(define (arg->c a keep)
  (define c (make-PancakeArgument ARG-VOID 0 0 0.0 #f 0 (make-PancakeReference 0) #f 0))
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
    [(ref? a) (set-PancakeArgument-kind! c ARG-REFERENCE) (set-PancakeArgument-reference! c (ref->c a))]
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
    [else (raise-pancake 'arg->c ERR-UNSUPPORTED-VALUE
                         "unsupported argument type: ~a" a)])
  c)

(define (set-bytes-field! c kind bs keep)
  (define buf (pin-immobile bs))
  (set-box! keep (cons buf (unbox keep)))
  (set-PancakeArgument-kind! c kind)
  (set-PancakeArgument-bytes! c buf)
  (set-PancakeArgument-bytes-len! c (bytes-length bs)))

;; ── Marshalling (decode) ─────────────────────────────────────────────────────
(define (ref<-c r)
  (make-ref/internal (PancakeReference-id r)))

(define (arg<-c c)
  (define k (PancakeArgument-kind c))
  (cond
    [(= k ARG-INTEGER) (PancakeArgument-integer c)]
    [(= k ARG-FLOAT64) (PancakeArgument-float64 c)]
    [(= k ARG-BOOLEAN) (not (zero? (PancakeArgument-boolean c)))]
    [(= k ARG-BYTES) (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))]
    [(= k ARG-STRING) (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) UFFFD)]
    [(= k ARG-SYMBOL) (sym (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) UFFFD))]
    [(= k ARG-REFERENCE) (ref<-c (PancakeArgument-reference c))]
    [(= k ARG-LIST) (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c))]
    [(= k ARG-SET) (pset (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-TAGGED) (tagged-arg (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) UFFFD)
                                  (args<-c (PancakeArgument-items c) (PancakeArgument-items-len c)))]
    [(= k ARG-KEYWORD) (kw (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c)) UFFFD))]
    [(= k ARG-VOID) (void)]
    ;; Canonical decimal digits + sign flag back to a native bignum (ADR-0049).
    [(= k ARG-BIG-INTEGER)
     (let ([magnitude (string->number (bytes->string/utf-8 (bytes<-c (PancakeArgument-bytes c) (PancakeArgument-bytes-len c))))])
       (if (not (zero? (PancakeArgument-boolean c))) (- magnitude) magnitude))]
    [else (error 'arg<-c "unrecognized argument kind: ~a" k)]))

(define (args<-c ptr len)
  (if (or (not ptr) (zero? len)) '()
      (for/list ([i (in-range len)]) (arg<-c (ptr-ref ptr _PancakeArgument i)))))
