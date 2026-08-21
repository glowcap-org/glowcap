#lang racket/base
;; Private facade for the iroh companion.
;;
;; The public `../pancake-iroh.rkt` barrel consumes this stable surface. Raw
;; endpoint/readiness ownership lives in `iroh/runtime.rkt`; application-facing
;; provider, connector, and server composition lives in `iroh/surface.rkt`.

(require "iroh/runtime.rkt"
         "iroh/surface.rkt")

(provide (all-from-out "iroh/runtime.rkt")
         (all-from-out "iroh/surface.rkt"))
