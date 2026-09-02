#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libglowcap_net_transport_onion.
;;
;; Nothing here is public; `../glowcap-onion.rkt` is the ergonomic surface over
;; it. This loader opens ONLY the onion transport archive (ADR-0059): it carries
;; the `glowcap_onion_*` family plus its own thread-local last-error,
;; symbol-disjoint from libglowcap_ocapn and from the other transports.
;; Requiring it loads no other archive.
;;
;; The onion netlayer reaches a Tor daemon the deployment already runs, so its
;; dial and accept park the calling thread for as long as a circuit takes, which
;; is seconds rather than milliseconds. The generated `#:blocking?` marks keep
;; the runtime GC-cooperative during that park. The readiness rows carry no mark
;; because they return at once: park on the descriptor they hand back and the
;; blocking rows are only entered when they will return. Netlayer shutdown is
;; the owner-level cancellation edge for a connect or listen already inside Tor.
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-onion-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them.
(require ffi/unsafe
         "ffi-shared.rkt"
         "ffi-onion-gen.rkt")
(provide (except-out (all-from-out "ffi-onion-gen.rkt")
                     glowcap_onion_netlayer_release*
                     glowcap_onion_connect*
                     glowcap_onion_listen*
                     glowcap_onion_listener_wait*
                     glowcap_onion_accept*
                     glowcap_onion_conn_read_frame*
                     glowcap_onion_conn_write_frame*
                     glowcap_onion_conn_release*
                     glowcap_onion_listener_release*)
         glowcap_onion_netlayer_release
         glowcap_onion_connect
         glowcap_onion_listen
         glowcap_onion_listener_wait
         glowcap_onion_accept
         glowcap_onion_conn_read_frame
         glowcap_onion_conn_write_frame
         glowcap_onion_conn_release
         glowcap_onion_listener_release)

(define (glowcap_onion_netlayer_release netlayer)
  (call/without-diagnostic glowcap_onion_netlayer_release* netlayer))

(define (glowcap_onion_connect netlayer service-id service-id-len codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic glowcap_onion_connect*
                                       netlayer service-id service-id-len codec
                                       max-frame out))))

(define (glowcap_onion_listen netlayer out-service-id out-service-id-cap
                              out-service-key out-service-key-cap)
  (call/outs (list (cons _size 0) (cons _size 0) (cons _pointer #f))
             (lambda (out-id-len out-key-len out-listener)
               (call/without-diagnostic
                glowcap_onion_listen*
                netlayer out-service-id out-service-id-cap out-id-len
                out-service-key out-service-key-cap out-key-len out-listener))))

(define (glowcap_onion_listener_wait listener timeout-ms)
  (call/out _uint32 0
            (lambda (out)
              (call/without-diagnostic glowcap_onion_listener_wait*
                                       listener timeout-ms out))))

(define (glowcap_onion_accept listener codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic glowcap_onion_accept*
                                       listener codec max-frame out))))

(define (glowcap_onion_conn_read_frame conn frame)
  (call/without-diagnostic glowcap_onion_conn_read_frame* conn frame))

(define (glowcap_onion_conn_write_frame conn frame)
  (call/without-diagnostic glowcap_onion_conn_write_frame* conn frame))

(define (glowcap_onion_conn_release conn)
  (call/without-diagnostic glowcap_onion_conn_release* conn))

(define (glowcap_onion_listener_release listener)
  (call/without-diagnostic glowcap_onion_listener_release* listener))
