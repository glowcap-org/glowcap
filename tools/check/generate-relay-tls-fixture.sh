#!/usr/bin/env bash
# Generate a complete, test-only localhost TLS authority and leaf chain.

set -euo pipefail
umask 077

if [[ $# -ne 1 ]]; then
	printf '%s\n' "usage: generate-relay-tls-fixture.sh EMPTY_OUTPUT_DIRECTORY" >&2
	exit 2
fi

readonly OUTPUT=$1
if [[ -e ${OUTPUT} ]]; then
	printf 'relay TLS fixture output already exists: %s\n' "${OUTPUT}" >&2
	exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
	printf '%s\n' "relay TLS fixture generation requires openssl" >&2
	exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/glowcap-relay-tls-fixture.XXXXXX")
readonly scratch
trap 'rm -rf -- "${scratch}"' EXIT

openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
	-subj '/CN=glowcap TLS fixture root' \
	-addext 'basicConstraints=critical,CA:true,pathlen:0' \
	-addext 'keyUsage=critical,keyCertSign,cRLSign' \
	-keyout "${scratch}/root.key" \
	-out "${scratch}/tls_root.pem" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -sha256 \
	-subj '/CN=localhost' \
	-keyout "${scratch}/tls_server.key" \
	-out "${scratch}/server.csr" >/dev/null 2>&1
printf '%s\n' \
	'basicConstraints=critical,CA:false' \
	'keyUsage=critical,digitalSignature,keyEncipherment' \
	'extendedKeyUsage=serverAuth' \
	'subjectAltName=DNS:localhost' >"${scratch}/server.ext"
openssl x509 -req -sha256 -days 1825 \
	-in "${scratch}/server.csr" \
	-CA "${scratch}/tls_root.pem" \
	-CAkey "${scratch}/root.key" \
	-set_serial 1 \
	-extfile "${scratch}/server.ext" \
	-out "${scratch}/tls_server.pem" >/dev/null 2>&1

openssl verify -CAfile "${scratch}/tls_root.pem" \
	"${scratch}/tls_server.pem" >/dev/null
openssl x509 -checkhost localhost -noout \
	-in "${scratch}/tls_server.pem" >/dev/null
openssl x509 -checkend $((180 * 24 * 60 * 60)) -noout \
	-in "${scratch}/tls_server.pem" >/dev/null

mkdir -p -- "${OUTPUT}"
cp -- "${scratch}/tls_root.pem" "${OUTPUT}/tls_root.pem"
cp -- "${scratch}/tls_server.pem" "${OUTPUT}/tls_server.pem"
cp -- "${scratch}/tls_server.key" "${OUTPUT}/tls_server.key"
printf 'generated complete relay TLS fixture chain in %s\n' "${OUTPUT}"
