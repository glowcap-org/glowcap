#lang racket/base
;; Internal: the OCapN locator URI grammar. `parse-locator` and
;; `format-peer-uri` render through libpancake_ocapn's `pancake_uri_*` /
;; `pancake_locator_*` surface, so this binding hand-rolls no percent codec, and
;; copy every borrowed view into Racket strings before releasing the handle.
;; `pancake.rkt` re-provides these on the public surface.

(require ffi/unsafe
         racket/string
         "constants.rkt"
         "ffi-ocapn.rkt"
         "errors.rkt")

(provide (all-defined-out))

;; ── OCapN locator URIs ───────────────────────────────────────────────────────
;; The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
;; vocabulary, defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*`
;; surface, so this binding hand-rolls no percent codec. `parse-locator` copies
;; every borrowed view into Racket strings before releasing the handle;
;; `format-peer-uri` renders through the same grammar.

;; A parsed OCapN locator: `swissnum` is "" for a peer URI, the swiss bytes for a
;; sturdyref; `hints` is a string→string hash. Dial resolves host:port through
;; `pancake_host_plan_dial`; apps that need a bare designator split use
;; `designator-host-port`.
(struct locator (transport designator swissnum hints) #:transparent)

;; Read a borrowed (pointer, length) view an accessor filled into a Racket string.
(define (locator-field accessor loc)
  (define-values (rc ptr len) (accessor loc))
  (check rc)
  (if (or (not ptr) (= len 0)) "" (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))

(define (read-locator-hints loc)
  (define-values (rc count) (pancake_locator_hint_count loc))
  (check rc)
  (for/hash ([i (in-range count)])
    (define-values (r2 kptr klen vptr vlen) (pancake_locator_hint_at loc i))
    (check r2)
    (values (bytes->string/utf-8 (bytes<-c kptr klen) #\uFFFD)
            (bytes->string/utf-8 (bytes<-c vptr vlen) #\uFFFD))))

;; Parse an `ocapn://` URI into a `locator` through the core grammar.
;; `#:sturdyref?` selects the `/s/<swiss>` form. Raises for a malformed URI.
(define (parse-locator uri #:sturdyref? [sturdyref? #f])
  (define ub (string->bytes/utf-8 uri))
  (define sbuf (pin-immobile ub))
  (define-values (rc loc)
    (if sturdyref?
        (pancake_uri_parse_sturdyref sbuf (bytes-length ub))
        (pancake_uri_parse_peer sbuf (bytes-length ub))))
  (check rc)
  (dynamic-wind
   void
   (lambda ()
     (locator (locator-field pancake_locator_transport loc)
              (locator-field pancake_locator_designator loc)
              (locator-field pancake_locator_swissnum loc)
              (read-locator-hints loc)))
   (lambda () (pancake_locator_release loc))))

;; Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
;; through the core grammar. `hints` is a string→string hash.
(define (format-peer-uri transport designator [hints (hash)])
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
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc out-len)
      (pancake_uri_format_peer tbuf (bytes-length tb) dbuf (bytes-length db)
                               key-ptrs key-lens val-ptrs val-lens n
                               buf cap))
    (cond
      [(and (= rc ERR-BUFFER-TOO-SMALL) (> out-len cap)) (loop out-len)]
      [else (check rc) (bytes->string/utf-8 (subbytes buf 0 out-len))])))

;; Build the verbatim exporter location-record bytes a gifter embeds in a give
;; when the exporter is reachable only by a dial hint (ADR-0009), for an
;; exporter whose own session record carries no hint. `transport`/`designator`
;; name the exporter; a non-empty `direct-addresses` (comma-separated socket
;; addresses) adds a `direct-addresses` hint so a cross-process recipient dials it
;; directly with no discovery service (an iroh exporter reachable only by
;; address). The result feeds `session-set-exporter-locator!`. An empty
;; `direct-addresses` yields a hint-less location identical to the exporter's own
;; signed record, so a TCP or discovery-reachable exporter needs no override.
(define (encode-peer-locator transport designator [direct-addresses ""])
  (define t (string->bytes/utf-8 transport))
  (define d (string->bytes/utf-8 designator))
  (define a (string->bytes/utf-8 direct-addresses))
  (define-values (rc ptr len)
    (pancake_encode_peer_locator
     (pin-immobile t) (bytes-length t)
     (pin-immobile d) (bytes-length d)
     (pin-immobile a) (bytes-length a)))
  (check rc)
  (define out (bytes<-c ptr len))
  (pancake_peer_locator_bytes_release ptr len)
  out)

;; Render host:port as a tcp designator; bracket IPv6 for the core grammar.
(define (socket-addr-designator host port)
  (if (and (string-contains? host ":")
           (not (and (string-prefix? host "[") (string-suffix? host "]"))))
      (format "[~a]:~a" host port)
      (format "~a:~a" host port)))

;; Split a bare designator as host:port through the core grammar
;; (`pancake_designator_host_port`). Prefer this over minting a peer URI
;; just to call `parse-locator`.
(define (designator-host-port designator)
  (define db (string->bytes/utf-8 designator))
  (define dbuf (pin-immobile db))
  (define-values (rc hptr hlen hport)
    (pancake_designator_host_port dbuf (bytes-length db)))
  (check rc)
  (values (if (or (not hptr) (= hlen 0))
              ""
              (bytes->string/utf-8 (bytes<-c hptr hlen) #\uFFFD))
          hport))

;; Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
;; rendered through the core grammar. The convenience for the common case, a
;; caller holding a host and port passes `(connect (tcp-locator host port))`
;; instead of hand-formatting the URI. `host:port` is not a dial of its own; it
;; is a locator like any other.
(define (tcp-locator host port)
  (format-peer-uri TRANSPORT-TCP (socket-addr-designator host port)))

;; Build a `keyed-tcp` locator: the designator is the listener's Ed25519 public
;; key in canonical hex, and host/port ride the `direct-addresses` hint
;; (ADR-0075).
(define (keyed-tcp-locator designator host port)
  (format-peer-uri TRANSPORT-KEYED-TCP designator
                   (hash HINT-DIRECT-ADDRESSES (socket-addr-designator host port))))
