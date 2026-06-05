#lang racket/base
(require ffi/unsafe ffi/unsafe/define)

(printf "Probing libsodium...~n")
(define libsodium (ffi-lib "libsodium" '("23" "26" "")))
(printf "  ffi-lib result: ~v~n" libsodium)

(define-ffi-definer define-sodium libsodium)
(define-sodium sodium_init (_fun -> _int))
(printf "  sodium_init binding: ~v~n" sodium_init)
(printf "  procedure?: ~v~n" (procedure? sodium_init))

(printf "Probing libblake3...~n")
(define libblake3
  (or (ffi-lib "libblake3" '("0" "1" ""))
      (ffi-lib "libb3" '("0" ""))))
(printf "  ffi-lib result: ~v~n" libblake3)
