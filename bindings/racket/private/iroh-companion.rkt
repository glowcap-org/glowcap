#lang racket/base
;; Where the iroh transport lives, and the only way the binding reaches into it.
;;
;; Two files used to spell out the location and the load, which made it two
;; facts that could drift. It is one fact, and it lives here; `dial.rkt` and
;; `../relay.rkt` both come through this module.
;;
;; The transport is loaded on demand rather than required, so a program that
;; never dials an iroh locator never opens the iroh library. Loading on demand
;; and running threads together needs care. `dynamic-require` does not hold a
;; lock across a module's body, and this module's body opens the sidecar's FFI
;; library, so it can block partway through, which leaves a window where a second
;; thread asking for the same module could see it half-built. `delay/sync` closes
;; that window: the first thread to ask runs the load, every other thread waits
;; for it, and they all continue against the finished module. Concurrent first
;; dials are then as safe as sequential ones.
(require racket/promise
         racket/runtime-path)

(provide iroh-ref)

;; `private/iroh.rkt`, not `../pancake-iroh.rkt`: the barrel re-exports only the
;; application surface, and the dial needs `connect-iroh/node` beside it. Loading
;; the implementation directly also keeps this a plain module load. Racket's
;; compile manager does not manage submodule requests, so a program running
;; against compiled bytecode answers one by expanding the enclosing module again,
;; and expanding this one loads the generated FFI table for syntax, which fails.
;;
;; A module is known by its resolved path, so the path used here has to be the
;; one a plain `require` would produce. `define-runtime-path` hands the path back
;; as spelled, and that is not always equal to the simplified path, so using it
;; as written risks naming a second module. A program that requires the barrel
;; and also dials an iroh locator would then be at risk of loading two copies,
;; each with its own FFI state. Simplifying here keeps one, no matter which way a
;; program arrives at it.
(define-runtime-path iroh-spelling "iroh.rkt")
(define iroh-path (simplify-path (cleanse-path iroh-spelling)))

;; Every name the binding reads out of the transport, fetched once, together,
;; under the promise.
;;
;; Forcing the module in and then asking for a name afterwards is not enough:
;; the second step re-enters the module system, and two threads dialing at once
;; enter it together. That is a real race rather than a theoretical one. Racket
;; expands the module on that first request, and two threads expanding it at the
;; same time leave one of them looking at a half-built module, which it reports
;; as an uninitialized variable in a Racket collection. Anything that gets one
;; dial to finish first hides it, so it shows up as a program that works the
;; first time and fails the second.
;;
;; Asking for the names inside the promise puts every entry into the module
;; system under the same lock. After that a lookup here touches a hash table and
;; nothing else.
(define iroh-bindings
  (delay/sync
   (hasheq 'connect-iroh/node (dynamic-require iroh-path 'connect-iroh/node)
           'IROH-REACH-DIRECT (dynamic-require iroh-path 'IROH-REACH-DIRECT)
           'dial-locator-for-relay (dynamic-require iroh-path 'dial-locator-for-relay))))

;; Read a binding out of the iroh transport, loading it exactly once.
(define (iroh-ref name)
  (hash-ref (force iroh-bindings) name
            (lambda () (error 'iroh-ref "no such iroh binding: ~a" name))))
