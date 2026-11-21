# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's glowcap_pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: CI installs the same
# pinned Zig on macOS runners through image/zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a" ;;
        Linux-aarch64) echo "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795" ;;
        Darwin-arm64) echo "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d" ;;
        Darwin-x86_64) echo "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

bend_sha256() {
    glowcap_pick_by_arch bend_sha256 \
        "c9ff8d67bd903fb6ad9a26b43d8a62c01021de82a44d55ce4a3dcd4732113d6b" \
        "2f42a6fa34ecdaa71ae105e5fa734f9a07e129d333e45448ab6d2ff03a837570"
}

lean_sha256() {
    glowcap_pick_by_arch lean_sha256 \
        "caaa98356098c85dc0fcbbd28e1ec66f39eb6551829972b752ff20e1286b646b" \
        "40b04fdb7fb849d3c80e10c3bbeebc7b7354b6d3f07450b9168c2149b40d2a82"
}

deno_sha256() {
    glowcap_pick_by_arch deno_sha256 \
        "e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609" \
        "d49596c20b9788cf8f5d8ddf644103d4bde56ed239753f0bdb92ba9361d51905"
}

node_sha256() {
    glowcap_pick_by_arch node_sha256 \
        "5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864" \
        "89e1853138db51e8b82d3e98ba9c0d3f2956a28e5e55ea1b7e12d25aae92d5dd"
}

bun_sha256() {
    glowcap_pick_by_arch bun_sha256 \
        "94559b3b528995a49452f9f2404cec74f2efd7d06e0a000a8cd214b02c3666eb" \
        "18656a3bf0ea5641f5796ae4213b75255579a70a0fded2f337933785568cdf84"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    glowcap_pick_by_arch rustup_init_sha256 \
        "b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55" \
        "9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282"
}

opencode_sha256() {
    glowcap_pick_by_arch opencode_sha256 \
        "47734e08968b30cc22a0bffb6d9feeed76ad4aa743213a12122040392d09a057" \
        "5b68c1f4c5e75b4134e664cc8f36d634d64208d4fcfe5bcf3b48bab699c2dbac"
}

cursor_agent_sha256() {
    glowcap_pick_by_arch cursor_agent_sha256 \
        "a25986eaf0c9330aeeec599a139711cb9f267c64562d073a72b751edf5161695" \
        "5ff05be0d7c0b7754574dbcd677c35254a3ff190ed6457e71bbee0f276237e29"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5" \
        "0797542018e541a9288855df555c8077eed06f7a47d206362030480e8ecc9f3d"
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
