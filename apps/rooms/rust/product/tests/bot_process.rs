//! The Rooms bot as a process: the real `rooms-bot` executable and the
//! scripted harness serve a bot directory against a directory that stands in
//! for the session. Every trigger must end with exactly one reply line, whatever
//! the bot or harness does in between.
#![cfg(test)]
#[path = "bot_process/captp.rs"]
mod captp;
#[path = "bot_process/captp_actions.rs"]
mod captp_actions;
#[path = "bot_process/captp_crashes.rs"]
mod captp_crashes;
#[path = "bot_process/captp_direct.rs"]
mod captp_direct;
#[path = "bot_process/captp_handover.rs"]
mod captp_handover;
#[path = "bot_process/captp_recovery.rs"]
mod captp_recovery;
#[path = "bot_process/captp_session.rs"]
mod captp_session;
#[path = "bot_process/crashes.rs"]
mod crashes;
#[path = "bot_process/gating.rs"]
mod gating;
#[path = "bot_process/home.rs"]
mod home;
#[path = "bot_process/rig.rs"]
mod rig;
#[path = "bot_process/sending.rs"]
mod sending;
#[path = "bot_process/session.rs"]
mod session;
#[path = "session_rig/mod.rs"]
mod session_rig;
#[path = "bot_process/turns.rs"]
mod turns;
