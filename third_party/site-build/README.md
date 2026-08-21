# Site build forks

The documentation site uses Zine. While pancake is pinned to Zig
0.17.0-dev.1818+7051f8e73, Zine's current transitive pins do not all compile
with that compiler, so the root build passes these two package forks with
`--fork`:

- `translate-c`, from `https://codeberg.org/ziglang/translate-c` at
  `3da873cacdd7e9190fe1cf40372ddf5387c970ea`.
- `superhtml`, from `https://github.com/kristoff-it/superhtml` at
  `23ef2f44ca0df2d2e05a0be3874370553c5b591d`, with `ArrayList.getLast` replaced
  in `src/template.zig` for Zig 0.17.

These forks are site-build inputs only. Remove them when the pinned Zine release
depends on Zig 0.17-ready packages.
