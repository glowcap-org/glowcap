#lang racket/base
(require racket/runtime-path)
;; Bench server entrypoint: racket server.rkt <backend> <suite> <host> <port>.
;; Loads the requested app and backend, then serves the app's root on that
;; substrate over loopback TCP, printing one NDJSON readiness line and then
;; serving until interrupted. The glowcap backend closes its server on the
;; interrupt; the Goblins backend has nothing to drain, so its break ends the
;; process here.
(file-stream-buffer-mode (current-output-port) 'line)

(define-runtime-path here ".")
(define args (current-command-line-arguments))
(define backend-name (vector-ref args 0)) ; "goblins" | "glowcap"
(define suite (vector-ref args 1))
(define host (vector-ref args 2))
(define port (string->number (vector-ref args 3)))

(define app-path
  (build-path here "apps" (format "~a.rkt" suite)))
(define backend-path
  (build-path here (format "backend-~a.rkt" backend-name)))

(define server-build (dynamic-require app-path 'server-build))
(define server-run (dynamic-require backend-path 'server-run))

;; build-root is the app's server-build (mint-cap -> root-ctor); the backend's
;; server-run supplies the connection-appropriate mint-cap.
(with-handlers ([exn:break? void])
  (server-run "root" host port server-build))
