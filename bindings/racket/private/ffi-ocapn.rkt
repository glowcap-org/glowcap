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
(require ffi/unsafe
         ffi/unsafe/define
         "ffi-shared.rkt"
         "lib-resolve.rkt")
;; Re-export the shared cstruct vocabulary so a module that requires this loader
;; has the layouts the bound functions read and write.
(provide (all-from-out "ffi-shared.rkt")
         (all-defined-out))

(define ocapn-lib (open-pancake-archive "pancake_ocapn"))

(define-ffi-definer define-pancake ocapn-lib)
(define-pancake pancake_abi_version
  (_fun (major : (_ptr o _uint32)) (minor : (_ptr o _uint32)) (patch : (_ptr o _uint32))
        -> _void -> (values major minor patch)))
(define-pancake pancake_last_error (_fun _pointer _size -> _size))
(define-pancake pancake_managed_frame_release (_fun _PancakeManagedFrame-pointer -> _void))
;; Build the verbatim exporter location-record bytes a give names (transport +
;; designator, plus optional comma-separated direct-addresses), for an iroh
;; exporter reachable only by a dial hint.
(define-pancake pancake_encode_peer_locator
  (_fun _pointer _size _pointer _size _pointer _size
        (out : (_ptr o _pointer)) (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out out-len)))
(define-pancake pancake_peer_locator_bytes_release (_fun _pointer _size -> _void))

;; OCapN locator URIs, core libpancake_ocapn vocabulary, so a TCP-only program reaches
;; the grammar without any transport companion. One grammar, no hand-rolled percent
;; codec: verbs mint an opaque locator handle, nouns read borrowed views from it.
(define-pancake pancake_uri_parse_peer
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_parse_sturdyref
  (_fun _pointer _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake pancake_uri_format_peer
  (_fun _pointer _size _pointer _size _pointer _pointer _pointer _pointer _size
        _pointer _size (out-len : (_ptr o _size)) -> (r : _int32) -> (values r out-len)))
(define-pancake pancake_locator_transport
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_designator
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_host_port
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) (port : (_ptr o _uint16))
        -> (r : _int32) -> (values r p l port)))
(define-pancake pancake_designator_host_port
  (_fun _pointer _size (p : (_ptr o _pointer)) (l : (_ptr o _size)) (port : (_ptr o _uint16))
        -> (r : _int32) -> (values r p l port)))
(define-pancake pancake_locator_swissnum
  (_fun _pointer (p : (_ptr o _pointer)) (l : (_ptr o _size)) -> (r : _int32) -> (values r p l)))
(define-pancake pancake_locator_hint_count
  (_fun _pointer (c : (_ptr o _size)) -> (r : _int32) -> (values r c)))
(define-pancake pancake_locator_hint_at
  (_fun _pointer _size (k : (_ptr o _pointer)) (kl : (_ptr o _size)) (v : (_ptr o _pointer)) (vl : (_ptr o _size))
        -> (r : _int32) -> (values r k kl v vl)))
(define-pancake pancake_locator_release (_fun _pointer -> _void))
