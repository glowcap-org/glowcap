#lang racket/base

;; The transport-neutral byte-channel shape a relay pumps over: `read` returns the
;; next chunk of bytes or `eof`, `write` sends a chunk (blocking under the far
;; leg's backpressure), and `close!` tears the channel down. The relay's TCP and
;; iroh legs both present this shape, so one pump serves either.
;;
;; It lives here, not in the iroh binding, so a TCP-only relay never loads the iroh
;; module: the TCP leg builds a `relay-channel` over a raw socket with no iroh in
;; sight, and only the iroh leg reaches for `pancake-iroh.rkt`.

(provide (struct-out relay-channel))

(struct relay-channel (read write close!))
