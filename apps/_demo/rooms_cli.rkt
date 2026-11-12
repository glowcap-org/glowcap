#lang racket/base
;; Shared Rooms CLI helpers. The codes come from rooms_codes.rkt, which
;; browser_metadata generates from the Rust FailureCode table.

(require "bindings.rkt" "rooms_codes.rkt")

(provide NO-SUCH-ROOM
         ROOM-EXISTS
         error-code
         enter-or-open)

;; The first segment of an application refusal's reason, which is where a
;; Rooms refusal puts its code. A caller compares it against the codes it
;; handles, so nested diagnostics cannot change the operation.
(define (error-code e)
  (define reason (glowcap-application-message e))
  (define head (and reason (regexp-match #rx"^([^:]+): " reason)))
  (if head (cadr head) ""))

;; Get a reference to the named room, opening it if it does not exist yet.
(define (enter-or-open enter open name)
  (with-handlers ([exn:fail:glowcap?
                   (lambda (e)
                     (cond
                       [(string=? (error-code e) NO-SUCH-ROOM)
                        (with-handlers ([exn:fail:glowcap?
                                         (lambda (e2)
                                           (cond
                                             [(string=? (error-code e2) ROOM-EXISTS)
                                              (enter name)]
                                             [else (raise e2)]))])
                          (open name))]
                       [else (raise e)]))])
    (enter name)))
