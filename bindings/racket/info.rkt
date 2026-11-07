#lang info

;; Source package for the glowcap collection. Keep private/c-abi-resolve.json
;; in the archive: loaders locate it with define-runtime-path. source-omit-files
;; controls archive contents; compile-omit-paths controls setup compilation.
(define collection "glowcap")
(define version "0.1.5")
(define license 'Apache-2.0)
(define deps '("base" "rfc6455"))
(define build-deps '())
;; The test tree only: do not omit private/c-abi-resolve.json.
(define compile-omit-paths '("test"))
(define source-omit-files '("test"))
