# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through install-zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
        Linux-aarch64) echo "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
        Darwin-arm64) echo "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489" ;;
        Darwin-x86_64) echo "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

zls_sha256() {
    pick_by_arch zls_sha256 \
        "ded6d562a0b86ee878b1ddf70ffab2797ce3cdca3b02d6077548f9d56dff96b6" \
        "430cd293d201eb70ae2519dbc96c854bf8791b8df7fc9392e8d2dc9680a2bed7"
}

deno_sha256() {
    pick_by_arch deno_sha256 \
        "8b010a3b1a4a0188a67cdb8a7a27348b2a501af78aec7fc74f2ace167368d530" \
        "6b7cae3a8fc4385a59dea3146fcb8bad7fea4230e0ad36a8c692afacbc254be0"
}

node_sha256() {
    pick_by_arch node_sha256 \
        "982aa24dd8be4c889c6a8ab337ddff3b0896645b20f4239356e80552c16277ee" \
        "afc7a004018485092ac8985b817b0d5684472bd9472e0b57d2ab88737e50090d"
}

bun_sha256() {
    pick_by_arch bun_sha256 \
        "951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f" \
        "a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    pick_by_arch rustup_init_sha256 \
        "4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10" \
        "9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792"
}

opencode_sha256() {
    pick_by_arch opencode_sha256 \
        "0cddc222418b8553669905a8980c0cda7088f00da24d83d6ac76b01c9fdb2aaf" \
        "dcb1b5ec5687b43f87749560021f9203f3809e0ce5ae44ff9be8ae17083fe4ba"
}

uv_sha256() {
    pick_by_arch uv_sha256 \
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
