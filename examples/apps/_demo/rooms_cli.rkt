#lang racket/base
;; Shared rooms CLI helpers mirrored from deno/lib/errors.ts.

(provide NO-SUCH-ROOM
         ROOM-EXISTS
         error-code
         enter-or-open)

(define NO-SUCH-ROOM "no-such-room")
(define ROOM-EXISTS "room-exists")

;; The typed code a room error carries. The binding wraps a broken vow as
;; "<verb> broke: <reason>", and the room's reason is "<code>: <detail>".
(define (error-code e)
  (define m (regexp-match #rx"broke: ([^:]+): " (exn-message e)))
  (if m (cadr m) ""))

;; Get a reference to the named room, opening it if it does not exist yet.
(define (enter-or-open enter open name)
  (with-handlers ([exn? (lambda (e)
                          (cond
                            [(string=? (error-code e) NO-SUCH-ROOM)
                             (with-handlers ([exn? (lambda (e2)
                                                     (cond
                                                       [(string=? (error-code e2) ROOM-EXISTS)
                                                        (enter name)]
                                                       [else (raise e2)]))])
                               (open name))]
                            [else (raise e)]))])
    (enter name)))
