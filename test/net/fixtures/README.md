# Native TLS fixtures

These test-only certificates prove Glowcap's native TLS carrier against a real
certificate chain. `tls_root.pem` is the private fixture authority;
`tls_server.pem` is valid only for `localhost`, and `tls_server.key` is its
non-production private key.

`zig build native-tls-build` verifies the chain and refuses to run when the
server certificate has less than 180 days remaining. Regenerate the complete
fixture chain before that gate expires so an isolated leaf replacement cannot
silently change its authority or name constraints. The same gate generates
short-lived independent authorities under its temporary directory for unknown
CA and expired-leaf refusal; those private keys and certificates never become
project fixtures.

Generate a candidate without overwriting the current evidence:

```sh
tools/check/generate-native-tls-fixture.sh /tmp/glowcap-tls-fixture
openssl x509 -in /tmp/glowcap-tls-fixture/tls_root.pem \
  -noout -subject -issuer -dates -ext basicConstraints -ext keyUsage
openssl x509 -in /tmp/glowcap-tls-fixture/tls_server.pem \
  -noout -subject -issuer -dates -ext subjectAltName -ext extendedKeyUsage
```

Review and replace `tls_root.pem`, `tls_server.pem`, and `tls_server.key`
together, then run `zig build native-tls-build`. The generator deliberately
does not retain the root private key: a future renewal creates a new authority,
which prevents an isolated leaf refresh from becoming an undocumented trust
continuation.
