//! Each lifecycle scenario once per engine. An in-memory store ends at close,
//! so the scenarios that reopen or restart a store do not run over it.
use super::*;

#[cfg(feature = "tcp")]
#[tokio::test]
async fn lmdb_create_share_edit_restart_and_cold_reopen() {
	create_share_edit_restart_and_cold_reopen(lmdb_engine).await;
}
#[cfg(feature = "tcp")]
#[tokio::test]
async fn sqlite_create_share_edit_restart_and_cold_reopen() {
	create_share_edit_restart_and_cold_reopen(sqlite_engine).await;
}
#[tokio::test]
async fn lmdb_refused_registration_and_host_close_release_callback_custody() {
	refused_registration_and_host_close_release_callback_custody(lmdb_engine).await;
}
#[tokio::test]
async fn sqlite_refused_registration_and_host_close_release_callback_custody() {
	refused_registration_and_host_close_release_callback_custody(sqlite_engine).await;
}
#[test]
fn lmdb_physical_map_budget_refuses_writes_without_losing_the_store() {
	physical_map_budget_refuses_writes_without_losing_the_store(lmdb_engine);
}
#[test]
fn sqlite_physical_map_budget_refuses_writes_without_losing_the_store() {
	physical_map_budget_refuses_writes_without_losing_the_store(sqlite_engine);
}
#[test]
fn lmdb_collect_runs_bounded_steps_until_the_cycle_ends() {
	collect_runs_bounded_steps_until_the_cycle_ends(lmdb_engine);
}
#[test]
fn sqlite_collect_runs_bounded_steps_until_the_cycle_ends() {
	collect_runs_bounded_steps_until_the_cycle_ends(sqlite_engine);
}
#[test]
fn lmdb_collect_refuses_while_a_creation_is_staged_and_leaves_it_intact() {
	collect_refuses_while_a_creation_is_staged_and_leaves_it_intact(lmdb_engine);
}
#[test]
fn sqlite_collect_refuses_while_a_creation_is_staged_and_leaves_it_intact() {
	collect_refuses_while_a_creation_is_staged_and_leaves_it_intact(sqlite_engine);
}
#[tokio::test]
async fn volatile_refused_registration_and_host_close_release_callback_custody() {
	refused_registration_and_host_close_release_callback_custody(volatile_engine).await;
}
#[test]
fn volatile_collect_runs_bounded_steps_until_the_cycle_ends() {
	collect_runs_bounded_steps_until_the_cycle_ends(volatile_engine);
}
#[test]
fn volatile_collect_refuses_while_a_creation_is_staged_and_leaves_it_intact() {
	collect_refuses_while_a_creation_is_staged_and_leaves_it_intact(volatile_engine);
}
