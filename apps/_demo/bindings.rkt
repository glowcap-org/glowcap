#lang racket/base
;; Re-export the glowcap Racket binding from a stable path for demo clients.

(require "../../bindings/racket/glowcap.rkt")

(provide (all-from-out "../../bindings/racket/glowcap.rkt"))
