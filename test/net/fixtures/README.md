# TLS fixtures

These test-only certificates prove glowcap's TLS carrier against a real
certificate chain. `tls_root.pem` is the private fixture authority.
`tls_server.pem` is valid only for `localhost`, and `tls_server.key` is its
non-production private key.

`zig build native-tls-build` verifies the chain and refuses to run when the
server certificate has less than 180 days remaining. Regenerate the complete
fixture chain before then, so a leaf replacement alone cannot change its
authority or name constraints. The same gate generates
short-lived independent authorities under its temporary directory for unknown
CA and expired-leaf refusal. Those keys and certificates are never committed.

Generate a candidate without overwriting the current evidence:

```sh
tools/check/generate-native-tls-fixture.sh /tmp/glowcap-tls-fixture
openssl x509 -in /tmp/glowcap-tls-fixture/tls_root.pem \
  -noout -subject -issuer -dates -ext basicConstraints -ext keyUsage
openssl x509 -in /tmp/glowcap-tls-fixture/tls_server.pem \
  -noout -subject -issuer -dates -ext subjectAltName -ext extendedKeyUsage
```

Review and replace `tls_root.pem`, `tls_server.pem`, and `tls_server.key`
together, then run `zig build native-tls-build`. The generator does not retain
the root private key, so a renewal creates a new authority and a leaf refresh
alone cannot continue the old trust.
