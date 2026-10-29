#lang racket/base
;; Complete Racket dogfood aggregate. Each required module is independently
;; loadable and owns one scenario family; this root preserves their execution
;; order and the single teardown boundary used by `zig build racket-dogfood`.

(require "test/zig-smoke/support.rkt"
         "test/zig-smoke/diagnostics.rkt"
         "test/zig-smoke/actors-and-sessions.rkt"
         "test/zig-smoke/framing-and-gc.rkt"
         "test/zig-smoke/promises.rkt"
         "test/zig-smoke/listeners.rkt"
         "test/zig-smoke/proxies.rkt"
         "test/zig-smoke/lifecycle.rkt"
         "test/zig-smoke/close-input.rkt"
         "test/zig-smoke/callbacks-and-redeem.rkt"
         "test/zig-smoke/transports.rkt"
         "test/zig-smoke/backpressure.rkt")

(close-test-runtimes!)
(printf "racket zig-smoke OK: the onion transport reached a fake Tor and reported its service\n")
