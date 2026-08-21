# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's pancake_pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through image/zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "5e4c8acea6b9eea329480b500ad3ce28aff546e89cd37276b6306142cf7ee7d2" ;;
        Linux-aarch64) echo "6f3610278d3289b69599f69a927e4f61c504e05551515dee1d0c5d1e1187fa7c" ;;
        Darwin-arm64) echo "b26315d833480ccf5d6f5cacfbe88aa38a78fbbb014ee1768602c4e7b466f2ba" ;;
        Darwin-x86_64) echo "6a097b4455d1ae8cedf5489dece3837561d616bd5210272e5f8025b74141970c" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    pancake_pick_by_arch deno_sha256 \
        "8b010a3b1a4a0188a67cdb8a7a27348b2a501af78aec7fc74f2ace167368d530" \
        "6b7cae3a8fc4385a59dea3146fcb8bad7fea4230e0ad36a8c692afacbc254be0"
}

node_sha256() {
    pancake_pick_by_arch node_sha256 \
        "982aa24dd8be4c889c6a8ab337ddff3b0896645b20f4239356e80552c16277ee" \
        "afc7a004018485092ac8985b817b0d5684472bd9472e0b57d2ab88737e50090d"
}

bun_sha256() {
    pancake_pick_by_arch bun_sha256 \
        "951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f" \
        "a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    pancake_pick_by_arch rustup_init_sha256 \
        "4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10" \
        "9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792"
}

opencode_sha256() {
    pancake_pick_by_arch opencode_sha256 \
        "0cddc222418b8553669905a8980c0cda7088f00da24d83d6ac76b01c9fdb2aaf" \
        "dcb1b5ec5687b43f87749560021f9203f3809e0ce5ae44ff9be8ae17083fe4ba"
}

cursor_agent_sha256() {
    pancake_pick_by_arch cursor_agent_sha256 \
        "bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a" \
        "ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed"
}

uv_sha256() {
    pancake_pick_by_arch uv_sha256 \
        "c8c60f47e6f88d18dbf6f33d7279fb1fbf7ae76631768152cf5578c3d65729b4" \
        "49d881b3403187e1f1789720881e77e4251ad4259d86c4844862657d2a35d13f"
}

racket_tarball_and_sha256() {
    case "$(uname -m)" in
        x86_64)
            echo "racket-minimal-${RACKET_VERSION}-x86_64-linux-buster-cs.tgz"
            echo "84d2c34c0ba7b4f206b5b4f0ce9e8127c153a55f65b0dbd2bdd9b1e2091b6822"
            ;;
        aarch64)
            echo "racket-minimal-${RACKET_VERSION}-aarch64-linux-buster-cs.tgz"
            echo "0e572088e3d5e1b51b198d602bd25380e176a03921e22a02828ad3df71bdd1ce"
            ;;
        *)
            echo "racket_tarball_and_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
