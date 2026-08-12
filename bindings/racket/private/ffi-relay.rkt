#lang racket/base
;; Internal loader for libpancake_net_transport_relay. The archive exposes one
;; provider package for both keyed-relay and noise-relay; multiplexed execution is
;; owned by the native driver after registration.
(require "ffi-relay-gen.rkt")
(provide (all-from-out "ffi-relay-gen.rkt"))
