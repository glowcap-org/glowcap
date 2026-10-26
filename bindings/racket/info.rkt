#lang info

;; Source package for the glowcap collection. Keep private/c-abi-resolve.json
;; in the archive: loaders locate it with define-runtime-path. source-omit-files
;; controls archive contents; compile-omit-paths controls setup compilation.
(define collection "glowcap")
(define version "0.1.0")
(define license 'Apache-2.0)
(define deps '("base" "rfc6455"))
(define build-deps '())
;; Dogfood entries only: do not omit private/c-abi-resolve.json.
(define compile-omit-paths '("zig-smoke.rkt" "test"))
(define source-omit-files '("zig-smoke.rkt" "zig-smoke-fake-tor.rkt" "test"))
