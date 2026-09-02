#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
	echo "usage: native-tls-relay-live.sh CLIENT" >&2
	exit 2
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
server_pid=
cleanup() {
	if [[ -n ${server_pid} ]]; then
		kill "${server_pid}" 2>/dev/null || true
		wait "${server_pid}" 2>/dev/null || true
	fi
	rm -rf "${scratch}"
}
trap cleanup EXIT

openssl verify \
	-CAfile "${root}/test/net/fixtures/tls_root.pem" \
	"${root}/test/net/fixtures/tls_server.pem"
openssl x509 \
	-checkend $((180 * 24 * 60 * 60)) \
	-noout \
	-in "${root}/test/net/fixtures/tls_server.pem"

generate_chain() {
	local name=$1
	local expired=$2
	local dir="${scratch}/${name}"
	mkdir -p "${dir}/certs"
	printf '01\n' >"${dir}/serial"
	: >"${dir}/index"
	printf '%s\n' \
		'[ ca ]' \
		'default_ca = test_ca' \
		'[ test_ca ]' \
		"database = ${dir}/index" \
		"serial = ${dir}/serial" \
		"new_certs_dir = ${dir}/certs" \
		'default_md = sha256' \
		'policy = policy' \
		'[ policy ]' \
		'commonName = supplied' \
		'[ server ]' \
		'basicConstraints = CA:false' \
		'keyUsage = digitalSignature,keyEncipherment' \
		'extendedKeyUsage = serverAuth' \
		'subjectAltName = DNS:localhost,IP:127.0.0.1' >"${dir}/ca.cnf"
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-subj "/CN=glowcap-${name}-ca" \
		-keyout "${dir}/ca.key" -out "${dir}/ca.pem" >/dev/null 2>&1
	openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
		-keyout "${dir}/server.key" -out "${dir}/server.csr" >/dev/null 2>&1
	if [[ ${expired} == true ]]; then
		openssl ca -batch -config "${dir}/ca.cnf" \
			-cert "${dir}/ca.pem" -keyfile "${dir}/ca.key" \
			-extensions server -startdate 20200101000000Z -enddate 20210101000000Z \
			-in "${dir}/server.csr" -out "${dir}/server.pem" >/dev/null 2>&1
	else
		openssl ca -batch -config "${dir}/ca.cnf" \
			-cert "${dir}/ca.pem" -keyfile "${dir}/ca.key" \
			-extensions server -days 365 \
			-in "${dir}/server.csr" -out "${dir}/server.pem" >/dev/null 2>&1
	fi
}

start_server() {
	local name=$1
	shift
	local port_file="${scratch}/${name}.port"
	python3 "${root}/tools/check/native_tls_relay_server.py" \
		--port-file "${port_file}" "$@" &
	server_pid=$!
	for _ in {1..100}; do
		[[ -s ${port_file} ]] && break
		if ! kill -0 "${server_pid}" 2>/dev/null; then
			wait "${server_pid}"
			exit 1
		fi
		sleep 0.05
	done
	[[ -s ${port_file} ]] || {
		echo "native TLS relay fixture ${name} did not publish its port" >&2
		exit 1
	}
	port=$(<"${port_file}")
}

finish_server() {
	wait "${server_pid}"
	server_pid=
}

run_case() {
	local backend=$1
	local name=$2
	local expectation=$3
	local trust=$4
	local host=$5
	shift 5
	printf 'native TLS relay case: %s/%s\n' "${backend}" "${name}"
	start_server "${backend}-${name}" "$@"
	"${client}" "${backend}" "${expectation}" "${trust}" "wss://${host}:${port}/relay"
	finish_server
}

client=$1
root_ca="${root}/test/net/fixtures/tls_root.pem"
root_cert="${root}/test/net/fixtures/tls_server.pem"
root_key="${root}/test/net/fixtures/tls_server.key"
generate_chain valid false
generate_chain alien false
generate_chain expired true

run_case pollable success success "${root_ca}" localhost \
	--mode upgrade --cert "${root_cert}" --key "${root_key}"
run_case pollable wrong-host certificate_name_mismatch "${root_ca}" 127.0.0.1 \
	--mode tls-refusal --cert "${root_cert}" --key "${root_key}"
run_case pollable unknown-ca certificate_untrusted "${root_ca}" localhost \
	--mode tls-refusal --cert "${scratch}/alien/server.pem" --key "${scratch}/alien/server.key"
run_case pollable expired certificate_expired "${scratch}/expired/ca.pem" localhost \
	--mode tls-refusal --cert "${scratch}/expired/server.pem" --key "${scratch}/expired/server.key"
run_case pollable wrong-sni sni_alert "${root_ca}" localhost \
	--mode sni-refusal --cert "${root_cert}" --key "${root_key}"
run_case pollable peer-alert peer_alert "${root_ca}" localhost \
	--mode peer-alert --cert "${root_cert}" --key "${root_key}"
run_case pollable malformed malformed_tls "${root_ca}" localhost --mode malformed
run_case pollable truncated truncated "${root_ca}" localhost \
	--mode abrupt --cert "${root_cert}" --key "${root_key}"

# The completion carrier resolves asynchronously and races the returned
# addresses while retaining `localhost` as the TLS identity.
run_case completion success success "${scratch}/valid/ca.pem" localhost \
	--mode clean-close --cert "${scratch}/valid/server.pem" --key "${scratch}/valid/server.key"
run_case completion wrong-host certificate_name_mismatch "${root_ca}" 127.0.0.1 \
	--mode tls-refusal --cert "${root_cert}" --key "${root_key}"
run_case completion unknown-ca certificate_untrusted "${root_ca}" 127.0.0.1 \
	--mode tls-refusal --cert "${scratch}/alien/server.pem" --key "${scratch}/alien/server.key"
run_case completion expired certificate_expired "${scratch}/expired/ca.pem" 127.0.0.1 \
	--mode tls-refusal --cert "${scratch}/expired/server.pem" --key "${scratch}/expired/server.key"
run_case completion wrong-sni sni_alert "${scratch}/valid/ca.pem" 127.0.0.1 \
	--mode sni-refusal --cert "${scratch}/valid/server.pem" --key "${scratch}/valid/server.key"
run_case completion peer-alert peer_alert "${scratch}/valid/ca.pem" 127.0.0.1 \
	--mode peer-alert --cert "${scratch}/valid/server.pem" --key "${scratch}/valid/server.key"
run_case completion malformed malformed_tls "${scratch}/valid/ca.pem" 127.0.0.1 --mode malformed
run_case completion truncated truncated "${scratch}/valid/ca.pem" 127.0.0.1 \
	--mode abrupt --cert "${scratch}/valid/server.pem" --key "${scratch}/valid/server.key"
