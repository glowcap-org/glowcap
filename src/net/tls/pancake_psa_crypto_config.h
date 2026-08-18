#ifndef PANCAKE_PSA_CRYPTO_CONFIG_H
#define PANCAKE_PSA_CRYPTO_CONFIG_H

#define TF_PSA_CRYPTO_CONFIG_VERSION 0x01000000

/* TLS 1.2 and 1.3 key schedules and authenticated record ciphers. */
#define PSA_WANT_ALG_CHACHA20_POLY1305 1
#define PSA_WANT_ALG_ECDH 1
#define PSA_WANT_ALG_ECDSA 1
#define PSA_WANT_ALG_GCM 1
#define PSA_WANT_ALG_HKDF 1
#define PSA_WANT_ALG_HKDF_EXTRACT 1
#define PSA_WANT_ALG_HKDF_EXPAND 1
#define PSA_WANT_ALG_HMAC 1
#define PSA_WANT_ALG_RSA_PKCS1V15_SIGN 1
#define PSA_WANT_ALG_RSA_OAEP 1
#define PSA_WANT_ALG_RSA_PSS 1
#define PSA_WANT_ALG_SHA_256 1
#define PSA_WANT_ALG_SHA_384 1
#define PSA_WANT_ALG_SHA_512 1
#define PSA_WANT_ALG_STREAM_CIPHER 1
#define PSA_WANT_ALG_TLS12_PRF 1

/* Public Web PKI needs RSA and ECDSA certificate verification. Ephemeral key
 * agreement needs generated/derived EC key pairs but no private cert keys. */
#define PSA_WANT_ECC_MONTGOMERY_255 1
#define PSA_WANT_ECC_SECP_R1_256 1
#define PSA_WANT_ECC_SECP_R1_384 1
#define PSA_WANT_KEY_TYPE_AES 1
#define PSA_WANT_KEY_TYPE_CHACHA20 1
#define PSA_WANT_KEY_TYPE_ECC_PUBLIC_KEY 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_BASIC 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_GENERATE 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_DERIVE 1
#define PSA_WANT_KEY_TYPE_RSA_PUBLIC_KEY 1
#define PSA_WANT_KEY_TYPE_RSA_KEY_PAIR_BASIC 1

/* Certificate and copied-PEM trust parsing. */
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_BASE64_C
#define MBEDTLS_CTR_DRBG_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_PSA_BUILTIN_GET_ENTROPY
#define MBEDTLS_PSA_CRYPTO_C
/* Native certificate verification uses the platform wall clock. Without both
 * features Mbed TLS deliberately omits notBefore/notAfter enforcement. */
#define MBEDTLS_HAVE_TIME
#define MBEDTLS_HAVE_TIME_DATE

#if defined(__aarch64__) || defined(_M_ARM64)
#define MBEDTLS_AESCE_C
#endif
#if defined(__x86_64__) || defined(_M_X64)
#define MBEDTLS_AESNI_C
#endif
#define MBEDTLS_HAVE_ASM

#include "pancake_mbedtls_probe_config.h"

#endif /* PANCAKE_PSA_CRYPTO_CONFIG_H */
