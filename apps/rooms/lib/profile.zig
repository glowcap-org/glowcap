//! The wire profile every rooms peer speaks, for the two peers written in
//! Zig: the chat client and `pancake app rooms-peer`.
//!
//! Every peer in a room is a pancake peer, so a room does not run on the
//! interop floor. It speaks pancake's own CapTP version, `pancake-next`, over
//! the word-aligned Cap'n Proto codec. The two are named together because
//! they are one decision for a room rather than two knobs: a peer offers a
//! profile, and both ends agree on it out of band by reading the same
//! configuration (ADR-0003). Naming only half of it does not fail loudly. The
//! two axes negotiate independently, so the disagreeing one settles back to
//! the interop baseline and the room quietly runs on Syrup or on OCapN 1.0
//! (ADR-0103).
//!
//! These are enum literals rather than `model` values so this file stays a
//! leaf every rooms peer can import without dragging the library along. Each
//! use site coerces them to `model.CaptpVersion` and `model.CodecId`.
//!
//! `apps/rooms/lib/protocol.ts` carries the same pair for the peers written
//! in TypeScript, Python, Racket, and Rust, and `zig build meta-check` holds
//! the two spellings in lockstep.

pub const captp_version = .next;
pub const codec = .capnp;
