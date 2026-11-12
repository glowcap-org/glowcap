#lang racket/base
;; The Racket binding's test suite. Each required module is independently
;; loadable and owns one scenario family; this root preserves their execution
;; order and the single teardown boundary used by `zig build racket-test`.

(require "scenarios/support.rkt"
         "scenarios/diagnostics.rkt"
         "scenarios/host-options.rkt"
         "scenarios/actors-and-sessions.rkt"
         "scenarios/framing-and-gc.rkt"
         "scenarios/reference-ownership.rkt"
         "scenarios/host-actors.rkt"
         "scenarios/promises.rkt"
         "scenarios/listeners.rkt"
         "scenarios/released-owners.rkt"
         "scenarios/proxies.rkt"
         "scenarios/lifecycle.rkt"
         "scenarios/close-input.rkt"
         "scenarios/callbacks-and-redeem.rkt"
         "scenarios/transports.rkt"
         "scenarios/backpressure.rkt")

(close-test-runtimes!)
(printf "racket test OK: the onion transport reached a fake Tor and reported its service\n")
