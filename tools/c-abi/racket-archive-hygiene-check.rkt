#lang racket/base

(require racket/port
         racket/system
         (submod "../../bindings/racket/private/lib-resolve.rkt"
                 archive-hygiene-test-support))

(define tar
  (or (find-executable-path "tar")
      (error 'archive-hygiene-check "tar executable not found on PATH")))

(define (violation path)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"LC_ALL" #"C")
  ;; Cleared for the same reason production clears it: a harness that stands
  ;; for a port must run the tar that port runs, not a tar the ambient
  ;; environment has added flags to.
  (environment-variables-set! env #"TAR_OPTIONS" #f)
  (define-values (sp stdout stdin stderr)
    (parameterize ([current-environment-variables env])
      (subprocess #f #f 'stdout tar "--numeric-owner" "-tvzf" path)))
  (define listing (port->string stdout))
  (close-input-port stdout)
  (close-output-port stdin)
  (subprocess-wait sp)
  (unless (zero? (subprocess-status sp))
    (error 'archive-hygiene-check "tar list failed"))
  (tar-listing-violation listing "lib"))

;; Usage: CHECK CLEAN TRAVERSAL HAVE-TRAVERSAL UNSAFE ...
(define args (vector->list (current-command-line-arguments)))
(unless (>= (length args) 4)
  (error 'archive-hygiene-check
         "expected clean and traversal archives, a traversal flag, and one or more unsafe archives"))
(when (violation (car args))
  (error 'archive-hygiene-check "clean archive refused"))
(when (equal? (list-ref args 2) "1")
  (unless (violation (list-ref args 1))
    (error 'archive-hygiene-check "unsafe archive accepted: ~a" (list-ref args 1))))
(for ([path (in-list (list-tail args 3))])
  (unless (violation path)
    (error 'archive-hygiene-check "unsafe archive accepted: ~a" path)))
