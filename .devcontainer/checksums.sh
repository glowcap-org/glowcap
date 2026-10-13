# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's glowcap_pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through image/zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026" ;;
        Linux-aarch64) echo "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8" ;;
        Darwin-arm64) echo "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a" ;;
        Darwin-x86_64) echo "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    glowcap_pick_by_arch deno_sha256 \
        "c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490" \
        "c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf"
}

node_sha256() {
    glowcap_pick_by_arch node_sha256 \
        "3883bfc73f9a680ca4eab04b196068aaaab1373ffa77d8fc1a4408222495b651" \
        "0945e2cde6aa0f54d980f03874dfe5cf3a549ce714c7fb9019e591ce0accf282"
}

bun_sha256() {
    glowcap_pick_by_arch bun_sha256 \
        "3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18" \
        "efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    glowcap_pick_by_arch rustup_init_sha256 \
        "dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71" \
        "15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433"
}

opencode_sha256() {
    glowcap_pick_by_arch opencode_sha256 \
        "7bb9e61ad6feacf2e89c10a6a2c1840e3de4220bb50ba1fc7110f31806076aec" \
        "e9841d43d3e1a8f36ed2691592d3b8b4fb097e606c8b559a277a1b845840e26b"
}

cursor_agent_sha256() {
    glowcap_pick_by_arch cursor_agent_sha256 \
        "a79726c6e644520e993970be4c45775a6889802b67abe461a677a53219ae28e8" \
        "785c5f6bf2a60eb1121e27ed8c14f5ee07ed1b5b6692324f2d9a997238245eb5"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "1468ebd5a5541121837c5a2817b9972ba6090fa6caa3d142620850a47fb75154" \
        "3ccfb6af6e242433eb552f7d9676abd5412c6595c497e990d9c8cb7b5bd4d2c3"
}

racket_tarball_and_sha256() {
    case "$(uname -m)" in
        x86_64)
            echo "racket-minimal-${RACKET_VERSION}-x86_64-linux-buster-cs.tgz"
            echo "8f469b7e93645fc876594470d884775aafff7688f530fd38be873fb44c71ca6a"
            ;;
        aarch64)
            echo "racket-minimal-${RACKET_VERSION}-aarch64-linux-buster-cs.tgz"
            echo "221a1f77ba11ab090ec5ff77c5a95abfe1f72d3b8b879d694fc5d807567015be"
            ;;
        *)
            echo "racket_tarball_and_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
