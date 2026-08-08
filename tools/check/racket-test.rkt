#lang racket/base
;; racket-test.rkt — run the repository's Racket unit tests so a failure is a
;; failure.
;;
;; Two things a plain `racket <file>` does not do, and both of them make a red
;; test look green:
;;
;;   - A rackunit check that fails outside a test suite prints FAILURE and
;;     returns. The process still exits 0, so a build step that shells out to
;;     `racket <file>` reports success over a failing test. This runner makes a
;;     failed check raise, which is what gives the exit code its meaning.
;;   - A `(module+ test ...)` submodule does not run when its file is run. A
;;     library's tests belong there — top-level checks would run on every
;;     import — so this runner requires the submodule as well as the module.
;;
;; `raco test` would do both, but it is not in this repository's Racket image.
;;
;; Usage: `racket -y tools/check/racket-test.rkt <file> ...`

(require racket/cmdline
         racket/list
         rackunit)

;; A check that fails ends the run. Without this the exit code says nothing.
(current-check-handler raise)

(define files (vector->list (current-command-line-arguments)))
(when (empty? files)
  (eprintf "racket-test: name at least one Racket file to run~n")
  (exit 2))

(for ([file (in-list files)])
  (define path (path->complete-path file))
  (define main-module `(file ,(path->string path)))
  (define test-module `(submod ,main-module test))
  ;; The module itself, for a file whose checks are at its top level, and its
  ;; `test` submodule when it declares one. A file with neither runs and passes,
  ;; which is what a file with no tests should do.
  (dynamic-require main-module #f)
  (when (module-declared? test-module #t)
    (dynamic-require test-module #f))
  (printf "racket-test: ~a~n" file))
