---
description: "Shapes the Rooms Rust crates and the Rust binding settled: lifecycle enums, validated replies, and coded refusal lines."
globs: apps/rooms/rust/**/*.rs, bindings/rust/**/*.rs
paths:
  - "apps/rooms/rust/**/*.rs"
  - "bindings/rust/**/*.rs"
---

# glowcap — Rust Shapes

Clippy holds the floors (no bare `unwrap` or `expect` outside tests, every
`unsafe` block commented, `unsafe_code` forbidden in Rooms). These are the
shapes a lint cannot see.

- A lifecycle held as parallel `Option` fields on one struct is an enum whose
  variants carry the phase's data (`Phase` in the runtime's
  `uploads/transfer.rs`, `Watch` in `watching.rs`), so no method reads a
  field another method is trusted to have set. A new struct with two or more
  `Option` fields that are set and cleared together is the same shape.
- A value a constructor validated and a method re-reads lives in a newtype
  with a private field and one validating constructor (`validated_reply!` in
  the Rooms glowcap client's `access.rs`), so the re-read cannot fail and
  nothing else can build the type.
- A refusal line that carries a wire code is written by `FailureCode::line`
  and read by `Failure::parse` (`application/src/failure.rs`). A validator
  returns its module's `Invalid` enum, whose `Display` is the exact line,
  with `From<Invalid> for String` so callers keep `?`. A `String` error is
  right only where an operator reads the line and nothing matches on it.
