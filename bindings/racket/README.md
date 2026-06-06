# bindings/racket

A Racket consumer of the Zig `libpancake` C ABI. See [`../README.md`](../README.md)
for the shipped C ABI surface and how the bindings are gated.

## The API

[`pancake.rkt`](pancake.rkt) is the idiomatic Racket API over the C ABI. The raw
`ffi/unsafe` layer is private; what you use is a `peer` you create and release,
native Racket values as arguments, and event structs out of `peer-poll`:

```racket
(define p (make-peer))
(peer-register-import! p 5)
(peer-send-deliver! p (far 5) (list 42 #"hi") #:answer 9)   ; native int, bytes
(peer-step! p)
(peer-take-outbound p)
;; ...and (peer-poll p) returns deliver-event / resolve-event / other-event
```

[`zig-smoke.rkt`](zig-smoke.rkt) is the consumer `zig build bindings` runs: it
drives a real OCapN round-trip through that API. Racket must be on `PATH`
(provided by [`../../.devcontainer/`](../../.devcontainer/)); the build step
resolves the shared library relative to `zig-out/`.

```sh
zig build bindings        # builds libpancake, runs every binding consumer
```
