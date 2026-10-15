#lang racket/base
;; Internal loader for libglowcap_net_transport_relay. The archive exposes one
;; provider package for both keyed-relay and noise-relay; multiplexed execution is
;; owned by the FFI driver after registration.
(require "ffi-shared.rkt"
         "ffi-relay-gen.rkt")
(provide (except-out (all-from-out "ffi-relay-gen.rkt")
                     glowcap_relay_runtime_release*)
         glowcap_relay_runtime_release)

(define (glowcap_relay_runtime_release runtime)
  (call/without-diagnostic glowcap_relay_runtime_release* runtime))
