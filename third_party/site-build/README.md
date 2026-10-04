# Site build forks

The documentation site uses Zine. The pinned Zine release's transitive pins
do not all compile with the Zig version `.devcontainer/pins.sh` pins, so the
root build passes these two package forks with `--fork`:

- `translate-c`, from `https://codeberg.org/ziglang/translate-c` at
  `0944784e197e419433a21d4b28bfc65e48e7d514`, copied verbatim over the paths
  its `build.zig.zon` packages.
- `superhtml`, from `https://github.com/kristoff-it/superhtml` at
  `23ef2f44ca0df2d2e05a0be3874370553c5b591d`, with `ArrayList.getLast` replaced
  in `src/template.zig` for Zig 0.17. Its known-folders dependency is updated
  to `6da0d0c41b78b9ed2d34fa364fcb81b5ebece6c4`.

These forks are site-build inputs only, and the site build is a sibling of
`zig build check` rather than a member, so a Zig pin bump does not exercise
them. After raising `ZIG_VERSION`, run `zig build site` and refresh whichever
fork stops compiling, usually by moving `translate-c` to the upstream commit
that names the new Zig. Remove the forks when the pinned Zine release depends
on Zig 0.17-ready packages.
