//! The Rooms bot as a process: the real `rooms-bot` executable and the
//! scripted harness serve a bot directory against a directory that stands in
//! for the session. Every trigger must end with exactly one reply line, whatever
//! the bot or harness does in between.
#![cfg(test)]
#[path = "bot_process/captp.rs"]
mod captp;
#[path = "bot_process/captp_access.rs"]
mod captp_access;
#[path = "bot_process/captp_action_receipts.rs"]
mod captp_action_receipts;
#[path = "bot_process/captp_actions.rs"]
mod captp_actions;
#[path = "bot_process/captp_ask.rs"]
mod captp_ask;
#[path = "bot_process/captp_budget.rs"]
mod captp_budget;
#[path = "bot_process/captp_conflict.rs"]
mod captp_conflict;
#[path = "bot_process/captp_crashes.rs"]
mod captp_crashes;
#[path = "bot_process/captp_dead_verbs.rs"]
mod captp_dead_verbs;
#[path = "bot_process/captp_dial_errors.rs"]
mod captp_dial_errors;
#[path = "bot_process/captp_direct.rs"]
mod captp_direct;
#[path = "bot_process/captp_full.rs"]
mod captp_full;
#[path = "bot_process/captp_late_actions.rs"]
mod captp_late_actions;
#[path = "bot_process/captp_notes.rs"]
mod captp_notes;
#[path = "bot_process/captp_opening.rs"]
mod captp_opening;
#[path = "bot_process/captp_owners.rs"]
mod captp_owners;
#[path = "bot_process/captp_paused.rs"]
mod captp_paused;
#[path = "bot_process/captp_pending.rs"]
mod captp_pending;
#[path = "bot_process/captp_recovery.rs"]
mod captp_recovery;
#[path = "bot_process/captp_refusal.rs"]
mod captp_refusal;
#[path = "bot_process/captp_reminders.rs"]
mod captp_reminders;
#[path = "bot_process/captp_replace_actions.rs"]
mod captp_replace_actions;
#[path = "bot_process/captp_replace_ask.rs"]
mod captp_replace_ask;
#[path = "bot_process/captp_replace_settle.rs"]
mod captp_replace_settle;
#[path = "bot_process/captp_rooms.rs"]
mod captp_rooms;
#[path = "bot_process/captp_route.rs"]
mod captp_route;
#[path = "bot_process/captp_send_wait.rs"]
mod captp_send_wait;
#[path = "bot_process/captp_session.rs"]
mod captp_session;
#[path = "bot_process/control.rs"]
mod control;
#[path = "bot_process/crashes.rs"]
mod crashes;
#[path = "bot_process/gating.rs"]
mod gating;
#[path = "bot_process/home.rs"]
mod home;
#[path = "bot_process/kills.rs"]
mod kills;
#[path = "bot_process/leaks.rs"]
mod leaks;
#[path = "bot_process/lease.rs"]
mod lease;
#[path = "bot_process/opens.rs"]
mod opens;
#[path = "bot_process/rig.rs"]
mod rig;
#[path = "bot_process/sending.rs"]
mod sending;
#[path = "bot_process/session.rs"]
mod session;
#[path = "session_rig/mod.rs"]
mod session_rig;
#[path = "bot_process/start.rs"]
mod start;
#[path = "bot_process/turns.rs"]
mod turns;
#[path = "bot_process/waiting.rs"]
mod waiting;
#[path = "../src/bin/rooms-bot/words.rs"]
mod words;
