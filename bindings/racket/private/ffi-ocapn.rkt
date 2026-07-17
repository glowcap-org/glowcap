#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_ocapn, the core archive.
;;
;; Nothing here is public. This loader binds the library-level `pancake_*`
;; family the binding consumes: the ABI version and per-thread last error, the
;; managed-frame release every archive's frames free through, the OCapN
;; locator URI grammar, and the exporter location-record encoder gifter
;; origination feeds. The wire itself rides the byte-fed host
;; archive (`ffi-driver.rkt`); the raw `pancake_peer_*` family stays a
;; C-consumer surface with no Racket wrapper. This loader opens ONLY
;; libpancake_ocapn: the universal base usable alone (ADR-0059). The transport
;; archives have their own loaders (`ffi-tcp.rkt`, `ffi-inproc.rkt`,
;; `ffi-iroh.rkt`), each opening only its own symbol-disjoint archive, so
;; requiring the core pulls in no transport.
;;
;; No extension on the path: `ffi-lib` appends the platform-correct one (`.so`,
;; `.dylib`, `.dll`) and tries the versioned variants, so this loads on Linux,
;; macOS, and Windows from the one `zig build` output.
;;
;; Out-params are fresh caller-owned cells inside the public wrappers.
(require ffi/unsafe
         ffi/unsafe/define
         "ffi-shared.rkt"
         "lib-resolve.rkt")
;; Re-export the shared cstruct vocabulary so a module that requires this loader
;; has the layouts the bound functions read and write.
(provide (all-from-out "ffi-shared.rkt")
         (except-out (all-defined-out)
                     pancake_abi_version*
                     pancake_encode_peer_locator*
                     pancake_uri_parse_peer*
                     pancake_uri_parse_sturdyref*
                     pancake_uri_format_peer*
                     pancake_locator_transport*
                     pancake_locator_designator*
                     pancake_designator_host_port*
                     pancake_locator_swissnum*
                     pancake_locator_hint_count*
                     pancake_locator_hint_at*))

(define ocapn-lib (open-pancake-archive "pancake_ocapn"))

(define-ffi-definer define-pancake ocapn-lib)

(define-pancake pancake_abi_version*
  (_fun _pointer _pointer _pointer -> _void)
  #:c-id pancake_abi_version)
(define (pancake_abi_version)
  (define-values (_rc major minor patch)
    (call/outs (list (cons _uint32 0) (cons _uint32 0) (cons _uint32 0))
               (lambda (a b c)
                 (pancake_abi_version* a b c)
                 0)))
  (values major minor patch))

(define-pancake pancake_last_error (_fun _pointer _size -> _size))
(define-pancake pancake_managed_frame_release (_fun _PancakeManagedFrame-pointer -> _void))
;; Build the verbatim exporter location-record bytes a give names (transport +
;; designator, plus optional comma-separated direct-addresses), for an iroh
;; exporter reachable only by a dial hint.
(define-pancake pancake_encode_peer_locator*
  (_fun _pointer _size _pointer _size _pointer _size _pointer _pointer -> _int32)
  #:c-id pancake_encode_peer_locator)
(define (pancake_encode_peer_locator t tl d dl h hl)
  (call/outs (list (cons _pointer #f) (cons _size 0))
             (lambda (out out-len)
               (pancake_encode_peer_locator* t tl d dl h hl out out-len))))
(define-pancake pancake_peer_locator_bytes_release (_fun _pointer _size -> _void))

;; OCapN locator URIs, core libpancake_ocapn vocabulary, so a TCP-only program reaches
;; the grammar without any transport companion. One grammar, no hand-rolled percent
;; codec: verbs mint an opaque locator handle, nouns read borrowed views from it.
(define-pancake pancake_uri_parse_peer*
  (_fun _pointer _size _pointer -> _int32)
  #:c-id pancake_uri_parse_peer)
(define pancake_uri_parse_peer (wrap-out1 pancake_uri_parse_peer* _pointer #f))
(define-pancake pancake_uri_parse_sturdyref*
  (_fun _pointer _size _pointer -> _int32)
  #:c-id pancake_uri_parse_sturdyref)
(define pancake_uri_parse_sturdyref (wrap-out1 pancake_uri_parse_sturdyref* _pointer #f))
(define-pancake pancake_uri_format_peer*
  (_fun _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size _pointer -> _int32)
  #:c-id pancake_uri_format_peer)
(define (pancake_uri_format_peer a al b bl c d e f fl g gl)
  (call/out _size 0
            (lambda (out-len)
              (pancake_uri_format_peer* a al b bl c d e f fl g gl out-len))))
(define-pancake pancake_locator_transport*
  (_fun _pointer _pointer _pointer -> _int32)
  #:c-id pancake_locator_transport)
(define (pancake_locator_transport loc)
  (call/outs (list (cons _pointer #f) (cons _size 0))
             (lambda (p l) (pancake_locator_transport* loc p l))))
(define-pancake pancake_locator_designator*
  (_fun _pointer _pointer _pointer -> _int32)
  #:c-id pancake_locator_designator)
(define (pancake_locator_designator loc)
  (call/outs (list (cons _pointer #f) (cons _size 0))
             (lambda (p l) (pancake_locator_designator* loc p l))))
(define-pancake pancake_designator_host_port*
  (_fun _pointer _size _pointer _pointer _pointer -> _int32)
  #:c-id pancake_designator_host_port)
(define (pancake_designator_host_port designator designator-len)
  (call/outs (list (cons _pointer #f) (cons _size 0) (cons _uint16 0))
             (lambda (p l port)
               (pancake_designator_host_port* designator designator-len p l port))))
(define-pancake pancake_locator_swissnum*
  (_fun _pointer _pointer _pointer -> _int32)
  #:c-id pancake_locator_swissnum)
(define (pancake_locator_swissnum loc)
  (call/outs (list (cons _pointer #f) (cons _size 0))
             (lambda (p l) (pancake_locator_swissnum* loc p l))))
(define-pancake pancake_locator_hint_count*
  (_fun _pointer _pointer -> _int32)
  #:c-id pancake_locator_hint_count)
(define pancake_locator_hint_count (wrap-out1 pancake_locator_hint_count* _size 0))
(define-pancake pancake_locator_hint_at*
  (_fun _pointer _size _pointer _pointer _pointer _pointer -> _int32)
  #:c-id pancake_locator_hint_at)
(define (pancake_locator_hint_at loc i)
  (call/outs (list (cons _pointer #f) (cons _size 0) (cons _pointer #f) (cons _size 0))
             (lambda (k kl v vl) (pancake_locator_hint_at* loc i k kl v vl))))
(define-pancake pancake_locator_release (_fun _pointer -> _void))
