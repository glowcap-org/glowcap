#lang racket/base
;; Internal: the OCapN locator URI grammar. `parse-locator` and
;; `format-peer-uri` render through libglowcap_ocapn's `glowcap_uri_*` /
;; `glowcap_locator_*` surface, so this binding hand-rolls no percent codec, and
;; copy every borrowed view into Racket strings before releasing the handle.
;; `glowcap.rkt` re-provides these on the public surface.

(require ffi/unsafe
         "constants.rkt"
         "abi-value.rkt"
         "ffi-ocapn.rkt"
         "errors.rkt")

(provide (all-defined-out))

;; ── OCapN locator URIs ───────────────────────────────────────────────────────
;; The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
;; vocabulary, defined once in libglowcap_ocapn's `glowcap_uri_*` / `glowcap_locator_*`
;; surface, so this binding hand-rolls no percent codec. `parse-locator` copies
;; every borrowed view into Racket strings before releasing the handle;
;; `format-peer-uri` renders through the same grammar.

;; A parsed OCapN peer locator. `hints` is a string→typed-value hash. Transport
;; packages interpret their own designator and hint policy; apps that need a
;; bare host:port split use `designator-host-port`. Hint values are strings, bytes, booleans, or exact
;; signed 64-bit integers; `hint-wire-form` is 'map or 'boolean-false.
(struct locator (transport designator hints hint-wire-form) #:transparent)

;; A peer locator paired with its opaque authority-bearing swissnum.
(struct sturdyref (locator swissnum) #:transparent)

;; Read a borrowed (pointer, length) view an accessor filled into a Racket string.
(define (locator-field accessor loc)
  (define-values (rc ptr len) (accessor loc))
  (check rc)
  (if (or (not ptr) (= len 0)) "" (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))

;; Parse an `ocapn://` peer URI into a `locator` through the core grammar.
(define (parse-locator uri)
  (define ub (string->bytes/utf-8 uri))
  (define sbuf (pin-immobile ub))
  (define-values (rc loc) (glowcap_uri_parse_peer sbuf (bytes-length ub)))
  (check rc)
  (call-with-owned-locator-handle loc owned-locator->locator))

;; Parse an `ocapn://.../s/<swiss>` sturdyref without collapsing it into a
;; peer locator and dropping authority.
(define (parse-sturdyref uri #:captp-version captp-version)
  (define ub (string->bytes/utf-8 uri))
  (define-values (rc handle)
    (glowcap_uri_parse_sturdyref
     (captp-version-id captp-version)
     (pin-immobile ub)
     (bytes-length ub)))
  (check rc)
  (dynamic-wind
   void
   (lambda ()
     (define-values (locator-rc view) (glowcap_sturdyref_borrow_locator handle))
     (check locator-rc)
     (define-values (swiss-rc ptr len) (glowcap_sturdyref_swissnum handle))
     (check swiss-rc)
     (sturdyref (clone-locator-view view)
                (if (or (not ptr) (= len 0)) #"" (bytes<-c ptr len))))
   (lambda () (glowcap_sturdyref_release handle))))

;; ── Owned OCapN locators ────────────────────────────────────────────────────

(define (locator-wire-form form)
  (case form
    [(map) HINTS-MAP]
    [(boolean-false) HINTS-BOOLEAN-FALSE]
    [else (raise-argument-error 'locator "(or/c 'map 'boolean-false)" form)]))

;; Borrow one OCapN-owned locator handle for `proc`. This is the only Racket
;; path that maps the language's hint variants into FFI construction verbs.
(define (call-with-owned-locator value proc)
  (define loc (if (string? value) (parse-locator value) value))
  (unless (locator? loc) (raise-argument-error 'call-with-owned-locator "(or/c locator? string?)" value))
  (define transport (string->bytes/utf-8 (locator-transport loc)))
  (define designator (string->bytes/utf-8 (locator-designator loc)))
  (define-values (rc handle)
    (glowcap_locator_new
     (pin-immobile transport) (bytes-length transport)
     (pin-immobile designator) (bytes-length designator)
     (locator-wire-form (locator-hint-wire-form loc))))
  (check rc)
  (dynamic-wind
   void
   (lambda ()
     (for ([(name value) (in-hash (locator-hints loc))])
       (define name-bytes (string->bytes/utf-8 name))
       (define name-ptr (pin-immobile name-bytes))
       (define name-len (bytes-length name-bytes))
       (define hint-rc
         (cond
           [(string? value)
            (define bytes (string->bytes/utf-8 value))
            (glowcap_locator_add_string handle name-ptr name-len
                                        (pin-immobile bytes) (bytes-length bytes))]
           [(bytes? value)
            (glowcap_locator_add_bytes handle name-ptr name-len
                                       (pin-immobile value) (bytes-length value))]
           [(boolean? value)
            (glowcap_locator_add_boolean handle name-ptr name-len (if value 1 0))]
           [(and (exact-integer? value) (<= (- (expt 2 63)) value (sub1 (expt 2 63))))
            (glowcap_locator_add_integer handle name-ptr name-len value)]
           [else
            (raise-arguments-error 'call-with-owned-locator
                                   "unsupported locator hint value"
                                   "name" name "value" value)]))
       (check hint-rc))
     (proc handle))
   (lambda () (glowcap_locator_release handle))))

(define (call-with-owned-locator-handle handle proc)
  (dynamic-wind void (lambda () (proc handle))
                (lambda () (glowcap_locator_release handle))))

(define (call-with-locator-view value proc)
  (call-with-owned-locator
   value
   (lambda (handle)
     (define-values (rc view) (glowcap_locator_borrow_view handle))
     (check rc)
     (proc view))))

(define (clone-locator-view view)
  (define-values (rc handle) (glowcap_locator_clone view))
  (check rc)
  (call-with-owned-locator-handle handle owned-locator->locator))

;; Copy an owned OCapN handle into an ordinary Racket locator. The caller
;; retains and releases the handle; this function retains no FFI views.
(define (owned-locator->locator handle)
  (define-values (count-rc count) (glowcap_locator_hint_count handle))
  (check count-rc)
  (define hints
    (for/hash ([index (in-range count)])
      (define hint (make-GlowcapLocatorHintView #f 0 0 #f 0 0 0))
      (check (glowcap_locator_hint_at handle index hint))
      (define name
        (bytes->string/utf-8
         (bytes<-c (GlowcapLocatorHintView-name hint)
                   (GlowcapLocatorHintView-name-len hint)) #\uFFFD))
      (define value
        (case (GlowcapLocatorHintView-kind hint)
          [(1) (bytes->string/utf-8
                (bytes<-c (GlowcapLocatorHintView-bytes hint)
                          (GlowcapLocatorHintView-bytes-len hint)) #\uFFFD)]
          [(2) (bytes<-c (GlowcapLocatorHintView-bytes hint)
                         (GlowcapLocatorHintView-bytes-len hint))]
          [(3) (not (zero? (GlowcapLocatorHintView-boolean-value hint)))]
          [(4) (GlowcapLocatorHintView-integer-value hint)]
          [else (raise-glowcap 'owned-locator->locator ERR-INVALID-ARGUMENT
                               "OCapN returned an unknown locator hint kind")]))
      (values name value)))
  (define-values (wire-rc wire) (glowcap_locator_hint_wire_form handle))
  (check wire-rc)
  (locator
   (locator-field glowcap_locator_transport handle)
   (locator-field glowcap_locator_designator handle)
   hints
   (case wire
     [(0) 'map]
     [(1) 'boolean-false]
     [else (raise-glowcap 'owned-locator->locator ERR-INVALID-ARGUMENT
                          "OCapN returned an unknown locator hint wire form")])))

(define (format-locator-uri loc)
  (define hints
    (for/hash ([(name value) (in-hash (locator-hints loc))])
      (unless (string? value)
        (raise-arguments-error 'format-locator-uri
                               "locator hint has no lossless URI spelling"
                               "name" name "value" value))
      (values name value)))
  (format-peer-uri (locator-transport loc) (locator-designator loc) hints))

;; Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
;; through the core grammar. `hints` is a string→string hash.
(define (format-peer-uri transport designator [hints (hash)])
  (format-uri transport designator #f hints))

;; Add opaque swiss authority to a typed locator and render a sturdyref.
(define (format-sturdyref loc swissnum #:captp-version captp-version)
  (unless (bytes? swissnum)
    (raise-argument-error 'format-sturdyref "bytes?" swissnum))
  (define hints
    (for/hash ([(name value) (in-hash (locator-hints loc))])
      (unless (string? value)
        (raise-arguments-error 'format-sturdyref
                               "locator hint has no lossless URI spelling"
                               "name" name "value" value))
      (values name value)))
  (format-uri (locator-transport loc) (locator-designator loc) swissnum hints captp-version))

(define (format-uri transport designator swissnum hints [captp-version #f])
  (define pairs (hash->list hints))
  (define n (length pairs))
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define tbuf (pin-immobile tb))
  (define dbuf (pin-immobile db))
  ;; Pin each key/value; keep the (ptr len) pairs live until the call returns.
  (define keys (for/list ([p (in-list pairs)])
                 (let ([b (string->bytes/utf-8 (car p))])
                   (list (pin-immobile b) (bytes-length b)))))
  (define vals (for/list ([p (in-list pairs)])
                 (let ([b (string->bytes/utf-8 (cdr p))])
                   (list (pin-immobile b) (bytes-length b)))))
  (define key-ptrs (and (> n 0) (list->cblock (map car keys) _pointer)))
  (define key-lens (and (> n 0) (list->cblock (map cadr keys) _size)))
  (define val-ptrs (and (> n 0) (list->cblock (map car vals) _pointer)))
  (define val-lens (and (> n 0) (list->cblock (map cadr vals) _size)))
  (define (call-format buf cap)
    (begin0
      (if swissnum
          (let ([sbuf (pin-immobile swissnum)])
            (glowcap_uri_format_sturdyref
             (captp-version-id captp-version)
             tbuf (bytes-length tb) dbuf (bytes-length db)
             sbuf (bytes-length swissnum)
             key-ptrs key-lens val-ptrs val-lens n buf cap))
          (glowcap_uri_format_peer tbuf (bytes-length tb) dbuf (bytes-length db)
                                   key-ptrs key-lens val-ptrs val-lens n
                                   buf cap))
      ;; The cblocks carry only the pinned hint buffers' raw addresses, which
      ;; the collector cannot see; referencing the pin lists here keeps every
      ;; buffer live for each format call.
      (void/reference-sink keys vals)))
  (define-values (probe-rc probe-len) (call-format #f 0))
  (define (read-uri cap)
    (let loop ([cap cap])
      (define buf (make-bytes cap))
      (define-values (rc out-len) (call-format buf cap))
      (cond
        [(and (= rc ERR-BUFFER-TOO-SMALL) (> out-len cap)) (loop out-len)]
        [else (check rc) (bytes->string/utf-8 (subbytes buf 0 out-len))])))
  (cond
    [(= probe-rc ERR-BUFFER-TOO-SMALL) (read-uri probe-len)]
    [else
     (check probe-rc)
     (if (zero? probe-len) "" (read-uri probe-len))]))

;; Encode a complete typed locator as the canonical signed handoff record.
(define (encode-peer-locator loc)
  (call-with-locator-view
   loc
   (lambda (view)
     (define-values (rc ptr len) (glowcap_locator_record_encode view))
     (check rc)
     (define out (bytes<-c ptr len))
     (glowcap_locator_record_bytes_release ptr len)
     out)))

;; Split a bare designator as host:port through the core grammar
;; (`glowcap_designator_host_port`). Prefer this over minting a peer URI
;; just to call `parse-locator`.
(define (designator-host-port designator)
  (define db (string->bytes/utf-8 designator))
  (define dbuf (pin-immobile db))
  (define-values (rc hptr hlen hport)
    (glowcap_designator_host_port dbuf (bytes-length db)))
  (check rc)
  (values (if (or (not hptr) (= hlen 0))
              ""
              (bytes->string/utf-8 (bytes<-c hptr hlen) #\uFFFD))
          hport))
