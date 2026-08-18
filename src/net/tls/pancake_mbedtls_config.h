#ifndef PANCAKE_MBEDTLS_CONFIG_H
#define PANCAKE_MBEDTLS_CONFIG_H

/* Pancake's client-only, stream-only TLS surface. Network I/O, scheduling,
 * entropy ownership, and close policy remain in Zig. */
#define MBEDTLS_CONFIG_VERSION 0x04000000

#define MBEDTLS_ERROR_C
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
#define MBEDTLS_SSL_ALL_ALERT_MESSAGES
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_EXTENDED_MASTER_SECRET
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_PROTO_TLS1_3
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_X509_RSASSA_PSS_SUPPORT
#define MBEDTLS_X509_USE_C

/* The protocol maximum is also the explicit per-direction plaintext record
 * budget. The carrier adds no second whole-message staging buffer. */
#define MBEDTLS_SSL_IN_CONTENT_LEN 16384
#define MBEDTLS_SSL_OUT_CONTENT_LEN 16384

#include "pancake_mbedtls_probe_config.h"

#endif /* PANCAKE_MBEDTLS_CONFIG_H */
