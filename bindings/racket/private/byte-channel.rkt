#lang racket/base

;; The transport-neutral byte-channel shape a relay pumps over: `read` returns the
;; next chunk of bytes or `eof`, `write` sends a chunk (blocking under the far
;; leg's backpressure), and `close!` tears the channel down. The relay's TCP and
;; iroh legs both present this shape, so one pump serves either.
;;
;; `verified-remote` is the fourth field and the one that is not about moving
;; bytes: it is the peer name the code that opened this channel proved, or #f
;; when it proved none. What authenticated a partner is a property of the
;; connection rather than of its transport's name (ADR-0105), so the fact rides
;; on the channel, beside the bytes it was proved about. An iroh channel carries
;; the endpoint id QUIC verified during the TLS handshake, in the lowercase-hex
;; spelling an `iroh` locator's designator uses. A TCP channel carries #f,
;; because a socket address proves nothing about who answered at it. A consumer
;; that attributes a session compares this against the name its partner claims
;; and believes the claim only when the two are equal.
;;
;; It lives here, not in the iroh binding, so a TCP-only relay never loads the iroh
;; module: the TCP leg builds a `byte-channel` over a raw socket with no iroh in
;; sight, and only the iroh leg reaches for `pancake-iroh.rkt`.

(provide (struct-out byte-channel))

(struct byte-channel (read write close! verified-remote))
