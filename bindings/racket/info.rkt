#lang info

;; Packaging metadata for the Racket binding tree. The dogfood uses relative
;; requires today; this file names what a catalog package of this tree must
;; ship so the ADR-0077 resolve contract (`private/c-abi-resolve.json`) stays
;; loadable via define-runtime-path. Collection packages ship every file under
;; the tree that is not listed in compile-omit-paths / conditional-omit-paths;
;; keep that contract path out of those omit lists.
(define collection 'multi)
(define license 'Apache-2.0)
(define deps '("base" "rfc6455"))
(define build-deps '())
;; Dogfood entries only: do not omit private/c-abi-resolve.json.
(define compile-omit-paths '("zig-smoke.rkt" "test"))
(define source-omit-files '("zig-smoke.rkt" "zig-smoke-fake-tor.rkt" "test"))
