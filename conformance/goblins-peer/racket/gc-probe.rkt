#lang racket/base
;; A Goblins-owned object must become collectible while its client session
;; remains open. Keeping either its export or its call answer alive prevents
;; collection, so the weak reference observes both halves of distributed GC.

(require goblins goblins/actor-lib/methods)
(provide register-gc-probe!)

(define (^leaf _bcom)
  (lambda (_verb) "still held"))

(define (^probe _bcom)
  (define leaf-box #f)
  (methods
   [(make)
    (when leaf-box (error 'gc-probe "one object per probe"))
    (define leaf (spawn ^leaf))
    (set! leaf-box (make-weak-box leaf))
    ;; Two independently owned wire occurrences of the same object.
    (list leaf leaf)]
   [(collected?)
    (unless leaf-box (error 'gc-probe "no object was made"))
    (collect-garbage)
    (not (weak-box-value leaf-box))]))

(define (register-gc-probe! registry)
  ($ registry 'register (spawn ^probe) #"glowcapGcProbeSwissnumABCDEF1234"))
