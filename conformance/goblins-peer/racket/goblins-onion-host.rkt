#lang racket/base
;; goblins-onion-host.rkt — a Goblins vat reachable at a Tor onion address.
;;
;; The vat runs its own CapTP, unchanged, over the onion netlayer upstream
;; Goblins ships. Nothing in this file is pancake's: `new-onion-netlayer` is
;; Goblins' own, and it asks the Tor daemon for a version 3 service exactly as it
;; would in a deployment. That is the point of the check that drives this. onion
;; is the one netlayer the OCapN draft standardizes and the one Goblins ships, so
;; it is the ground where a pancake peer and a Goblins vat meet without either
;; having written the other's transport.
;;
;; It publishes the OCapN conformance suite's canonical echo cap and waits to be
;; dialed.
;;
;; Usage:
;;   racket goblins-onion-host.rkt <tor-control-socket> <tor-socks-socket> <work-dir>
;;
;; The first two are absolute paths to Unix sockets of an already-running Tor,
;; and the third is a directory this vat may put its own forwarded sockets in.
;;
;; **That Tor must accept an unauthenticated control connection**, because
;; Goblins sends a bare `AUTHENTICATE` with no credential. pancake can send a
;; cookie or a password; its partner here cannot, so the daemon the check starts
;; is configured for the narrower of the two.
;;
;; Stdout (line-buffered NDJSON), once the service is published and the cap is
;; registered:
;;   {"v":1,"event":"vat-ready","vat":"goblins-onion","service-id":"<56 base32>"}
;;   {"v":1,"event":"cap-published","vat":"goblins-onion","name":"echo","swiss":"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"}
;;
;; The driver reads the service id out of the first line to build the `onion`
;; locator it dials, and the swiss-num out of the second to bootstrap-fetch.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/netlayer/onion
         racket/string)

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

(define args (current-command-line-arguments))
(when (< (vector-length args) 3)
  (eprintf "usage: goblins-onion-host.rkt <tor-control-socket> <tor-socks-socket> <work-dir>\n")
  (exit 2))
(define tor-control-path (string->path (vector-ref args 0)))
(define tor-socks-path (string->path (vector-ref args 1)))
;; Goblins keeps the sockets it asks Tor to forward in a directory of its own.
;; The driver names one inside the temporary tree it deletes, so this check
;; leaves nothing behind.
(define ocapn-socks-dir (string->path (vector-ref args 2)))

;; The OCapN conformance suite's canonical echo swiss-num, the same one
;; `goblins-host.rkt` publishes over TCP.
(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

;; Echo behavior: `(lambda args args)` answers with its arguments unchanged.
(define (^echo _bcom)
  (lambda args
    args))

(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

(define a-vat (make-vat))

(a-vat
 'run
 (lambda ()
   ;; Three values, not one: the netlayer, the key that restores this service,
   ;; and the service id. That is why nothing here asks the netlayer for its own
   ;; location afterwards.
   (define-values (netlayer _private-key service-id)
     (new-onion-netlayer #:tor-control-path tor-control-path
                         #:tor-socks-path tor-socks-path
                         #:tor-ocapn-socks-dir ocapn-socks-dir))
   (define mycapn (spawn-mycapn netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (define echo (spawn ^echo))
   ($ nonce-registry 'register echo ECHO-SWISS-NUM)
   (emit-ndjson
    `(("event" . "vat-ready")
      ("vat" . "goblins-onion")
      ("service-id" . ,service-id)))
   (emit-ndjson
    `(("event" . "cap-published")
      ("vat" . "goblins-onion")
      ("name" . "echo")
      ("swiss" . ,(bytes->string/latin-1 ECHO-SWISS-NUM))))))

(sync (make-semaphore))
