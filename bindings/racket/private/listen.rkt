#lang racket/base
;; Native listener surfaces. The driver owns provider sockets, admission,
;; handshakes, events, and session release. This binding supplies only locator
;; policy and the public server views.

(require racket/lazy-require
         racket/random
         racket/string
         "constants.rkt"
         "errors.rkt"
         "locator.rkt"
         "host.rkt")

(lazy-require
 ["loop.rkt"
 (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   loop-listen!
   loop-listener-locator
   loop-listener-advertise!
   loop-listener-select!
   loop-listener-close!
   make-loop-server
   loop-server?
   loop-server-designator
   loop-server-host
   loop-server-accept
   loop-server-close!)]
 ["tcp-provider.rkt" (driver-loop-add-tcp!)])

(provide server?
         server-host
         keyed-tcp-server?
         keyed-tcp-server-host
         keyed-tcp-server-designator
         noise-tcp-server?
         noise-tcp-server-host
         noise-tcp-server-designator
         listen
         listen-keyed-tcp
         listen-noise-tcp
         server-port
         server-close!
         accept
         keyed-tcp-server-port
         keyed-tcp-server-uri
         keyed-tcp-server-accept
         keyed-tcp-server-close!
         noise-tcp-server-port
         noise-tcp-server-uri
         noise-tcp-server-accept
         noise-tcp-server-close!)

(define (wildcard-address? host)
  (define bare
    (if (and (string-prefix? host "[") (string-suffix? host "]"))
        (substring host 1 (sub1 (string-length host)))
        host))
  (or (string=? bare "0.0.0.0")
      (and (string-contains? bare ":")
           (for/and ([part (in-list (string-split bare ":" #:trim? #f))])
             (or (string=? part "") (regexp-match? #px"^0+$" part))))))

(define (split-designator who designator)
  (define match (regexp-match #px"^(.*):([0-9]+)$" designator))
  (unless match
    (raise-pancake who ERR-INVALID-ARGUMENT
                   "listener designator is not host:port: ~a" designator))
  (values (cadr match) (string->number (caddr match))))

(define (listen-via-loop bind-host port codec captp-version features advertised-host
                          time-travel? shared-host)
  (when (and shared-host codec (not (eq? codec (host-codec shared-host))))
    (raise-pancake 'listen ERR-INVALID-ARGUMENT
                   "the supplied Host codec conflicts with #:codec"))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values
         (open-driver-loop #:host shared-host
                           #:codec (or codec (and shared-host (host-codec shared-host)) 'syrup)
                           #:captp-version (or captp-version 'v1_0)
                           #:features (or features 'full))
         #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when owns-loop? (driver-loop-abort! lp))
                     (raise e))])
    (driver-loop-add-tcp! lp)
    (set! listener
          (loop-listen! lp TRANSPORT-TCP (format "~a:~a" bind-host port)))
    (define bound (locator-designator (loop-listener-locator lp listener)))
    (define-values (bound-host bound-port) (split-designator 'listen bound))
    (when (and (wildcard-address? bound-host) (not advertised-host))
      (raise-pancake 'listen ERR-INVALID-ARGUMENT
                     "a wildcard bind has no dialable address; provide #:advertised-host"))
    (define designator
      (if advertised-host (socket-addr-designator advertised-host bound-port) bound))
    (when advertised-host
      (loop-listener-advertise! lp listener
                                 (format-peer-uri TRANSPORT-TCP designator)))
    (loop-listener-select! lp listener)
    (driver-loop-start! lp)
    (make-loop-server lp listener designator time-travel? (not shared-host))))

(define (listen bind-host [port 0] #:codec [codec #f]
                #:captp-version [captp-version 'v1_0]
                #:features [features 'full]
                #:advertised-host [advertised-host #f]
                #:time-travel? [time-travel? #f]
                #:host [shared-host #f])
  (listen-via-loop bind-host port codec captp-version features advertised-host
                   time-travel? shared-host))

(struct keyed-tcp-server (inner designator advertised-host advertised-address)
  #:transparent)

(define (listen-keyed-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version 'v1_0]
                          #:features [features 'full]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f])
  (when (and seed shared-host (not (bytes=? seed (host-seed shared-host))))
    (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define durable (or seed (and shared-host (host-seed shared-host))
                      (crypto-random-bytes 32)))
  (unless (= (bytes-length durable) 32)
    (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values
         (open-driver-loop #:host shared-host #:seed durable
                           #:codec (or codec (and shared-host (host-codec shared-host)) 'syrup)
                           #:captp-version captp-version #:features features)
         #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when owns-loop? (driver-loop-abort! lp))
                     (raise e))])
    (driver-loop-add-tcp! lp)
    (set! listener
          (loop-listen! lp TRANSPORT-KEYED-TCP (format "~a:~a" bind-host port)))
    (define loc (loop-listener-locator lp listener))
    (define designator (locator-designator loc))
    (define direct
      (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES
                (lambda ()
                  (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT
                                 "listener locator has no direct-addresses hint"))))
    (define-values (bound-host bound-port)
      (split-designator 'listen-keyed-tcp direct))
    (when (and (wildcard-address? bound-host) (not advertised-host))
      (raise-pancake 'listen-keyed-tcp ERR-INVALID-ARGUMENT
                     "a wildcard bind has no dialable address; provide #:advertised-host"))
    (define direct*
      (if advertised-host (socket-addr-designator advertised-host bound-port) direct))
    (unless (equal? direct direct*)
      (loop-listener-advertise!
       lp listener
       (format-peer-uri TRANSPORT-KEYED-TCP designator
                        (hash HINT-DIRECT-ADDRESSES direct*))))
    (loop-listener-select! lp listener)
    (define-values (public-host _public-port)
      (split-designator 'listen-keyed-tcp direct*))
    (driver-loop-start! lp)
    (keyed-tcp-server (make-loop-server lp listener direct* time-travel? (not shared-host))
                      designator public-host direct*)))

(define (keyed-tcp-server-host s)
  (loop-server-host (keyed-tcp-server-inner s)))

(define (keyed-tcp-server-port s)
  (define-values (_host port)
    (split-designator 'keyed-tcp-server-port
                      (keyed-tcp-server-advertised-address s)))
  port)

(define (keyed-tcp-server-uri s)
  (keyed-tcp-locator (keyed-tcp-server-designator s)
                     (keyed-tcp-server-advertised-host s)
                     (keyed-tcp-server-port s)))


(struct noise-tcp-server (inner designator direct-address) #:transparent)

(define (listen-noise-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version 'v1_0]
                          #:features [features 'full]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f])
  (when (and seed shared-host (not (bytes=? seed (host-seed shared-host))))
    (raise-pancake 'listen-noise-tcp ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define durable (or seed (and shared-host (host-seed shared-host))
                      (crypto-random-bytes 32)))
  (unless (= (bytes-length durable) 32)
    (raise-pancake 'listen-noise-tcp ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values
         (open-driver-loop #:host shared-host #:seed durable
                           #:codec (or codec (and shared-host (host-codec shared-host)) 'syrup)
                           #:captp-version captp-version #:features features)
         #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when owns-loop? (driver-loop-abort! lp))
                     (raise e))])
    (driver-loop-add-tcp! lp)
    (set! listener
          (loop-listen! lp TRANSPORT-NOISE-TCP (format "~a:~a" bind-host port)))
    (define loc (loop-listener-locator lp listener))
    (define designator (locator-designator loc))
    (define direct
      (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES
                (lambda ()
                  (raise-pancake 'listen-noise-tcp ERR-INVALID-ARGUMENT
                                 "listener locator has no direct-addresses hint"))))
    (define-values (bound-host bound-port)
      (split-designator 'listen-noise-tcp direct))
    (when (and (wildcard-address? bound-host) (not advertised-host))
      (raise-pancake 'listen-noise-tcp ERR-INVALID-ARGUMENT
                     "a wildcard bind has no dialable address; provide #:advertised-host"))
    (define direct*
      (if advertised-host (socket-addr-designator advertised-host bound-port) direct))
    (unless (equal? direct direct*)
      (loop-listener-advertise!
       lp listener
       (format-peer-uri TRANSPORT-NOISE-TCP designator
                        (hash HINT-DIRECT-ADDRESSES direct*))))
    (loop-listener-select! lp listener)
    (driver-loop-start! lp)
    (noise-tcp-server (make-loop-server lp listener direct* time-travel? (not shared-host))
                      designator direct*)))

(define (noise-tcp-server-host s)
  (loop-server-host (noise-tcp-server-inner s)))
(define (noise-tcp-server-port s)
  (define-values (_host port)
    (split-designator 'noise-tcp-server-port (noise-tcp-server-direct-address s)))
  port)
(define (noise-tcp-server-uri s)
  (define-values (host port)
    (split-designator 'noise-tcp-server-uri (noise-tcp-server-direct-address s)))
  (noise-tcp-locator (noise-tcp-server-designator s) host port))
(define (noise-tcp-server-accept s)
  (loop-server-accept (noise-tcp-server-inner s)))
(define (noise-tcp-server-close! s)
  (loop-server-close! (noise-tcp-server-inner s)))

(define (server? s)
  (or (loop-server? s) (keyed-tcp-server? s) (noise-tcp-server? s)))
(define (server-host s)
  (cond [(loop-server? s) (loop-server-host s)]
        [(keyed-tcp-server? s) (keyed-tcp-server-host s)]
        [else (noise-tcp-server-host s)]))
(define (server-port s)
  (cond
    [(loop-server? s)
     (define-values (_host port)
       (split-designator 'server-port (loop-server-designator s)))
     port]
    [(keyed-tcp-server? s) (keyed-tcp-server-port s)]
    [else (noise-tcp-server-port s)]))
(define (accept s)
  (cond
    [(loop-server? s) (loop-server-accept s)]
    [(keyed-tcp-server? s) (loop-server-accept (keyed-tcp-server-inner s))]
    [else (noise-tcp-server-accept s)]))
(define (server-close! s)
  (cond
    [(loop-server? s) (loop-server-close! s)]
    [(keyed-tcp-server? s) (loop-server-close! (keyed-tcp-server-inner s))]
    [else (noise-tcp-server-close! s)]))
(define (keyed-tcp-server-accept s)
  (loop-server-accept (keyed-tcp-server-inner s)))
(define (keyed-tcp-server-close! s)
  (loop-server-close! (keyed-tcp-server-inner s)))
