#lang racket/base
;; Internal loader for libpancake_net_transport_relay. The archive exposes one
;; provider package for both keyed-relay and noise-relay; multiplexed execution is
;; owned by the native driver after registration.
(require "ffi-shared.rkt"
         "ffi-relay-gen.rkt")
(provide (except-out (all-from-out "ffi-relay-gen.rkt")
                     pancake_relay_runtime_release*)
         pancake_relay_runtime_release)

(define (pancake_relay_runtime_release runtime)
  (call/without-diagnostic pancake_relay_runtime_release* runtime))
