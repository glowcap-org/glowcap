#lang racket/base
;; Transport-neutral product composition values.
;;
;; A driver-provider installs one archive-owned provider package into an FFI
;; loop. A byte-connector realizes one locator as a byte-fed Session. Neither
;; value knows how a transport works; the archive companion that constructs it
;; owns that policy.

(require ffi/unsafe
         racket/list)

(provide (struct-out driver-provider)
         (struct-out byte-connector)
         make-driver-provider
         make-byte-connector
         byte-connector-supports?
         transport-operation-options?
         make-transport-operation-options
         transport-operation-options-data
         transport-operation-options-size)

(struct driver-provider (install!) #:transparent)
(struct byte-connector (transports realize) #:transparent)
(struct transport-operation-options (data size))

(define (make-transport-operation-options data size)
  (unless (cpointer? data)
    (raise-argument-error 'make-transport-operation-options "cpointer?" data))
  (unless (exact-nonnegative-integer? size)
    (raise-argument-error 'make-transport-operation-options
                          "exact-nonnegative-integer?" size))
  (transport-operation-options data size))

(define (transport-symbol-list who transports)
  (unless (and (list? transports)
               (pair? transports)
               (andmap (lambda (transport)
                         (and (string? transport)
                              (positive? (string-length transport))))
                       transports))
    (raise-argument-error who "non-empty (listof non-empty-string?)" transports))
  (when (check-duplicates transports string=?)
    (raise-arguments-error who "transport symbols must be unique" "transports" transports))
  transports)

(define (make-driver-provider install!)
  (unless (procedure? install!)
    (raise-argument-error 'make-driver-provider "procedure?" install!))
  (driver-provider install!))

;; `realize` is `(lambda (host locator handshake-timeout-ms introducer) ...)`
;; and returns an established session. `introducer` is the live session that
;; supplied the give this dial redeems, captured before `realize` runs, or #f
;; for an application dial and for a pending dial whose introducing session
;; has closed. `realize` borrows it for signaling context and does not own its
;; lifetime.
(define (make-byte-connector transports realize)
  (unless (and (procedure? realize) (procedure-arity-includes? realize 4))
    (raise-argument-error 'make-byte-connector "(procedure-arity-includes/c 4)" realize))
  (byte-connector (transport-symbol-list 'make-byte-connector transports)
                  realize))

(define (byte-connector-supports? connector transport)
  (and (byte-connector? connector)
       (member transport (byte-connector-transports connector) string=?)))
