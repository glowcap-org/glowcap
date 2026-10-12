//! The production session callback and worker own actual Loam receipts.
mod activity;
mod activity_archives;
mod activity_direct;
mod activity_offers;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod admission;
mod archive_readers;
mod authority_retirement;
mod bridge;
#[cfg(target_arch = "wasm32")]
mod browser;
#[cfg(target_arch = "wasm32")]
mod browser_bootstrap;
mod bundle_imports;
mod cases;
mod connection_results;
mod creation_results;
mod direct_callbacks;
mod direct_files;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod direct_lifetime;
mod direct_openings;
mod direct_restart;
mod direct_results;
mod direct_routes;
mod directory_coordination;
mod directory_ingress;
mod discovery;
mod discovery_watch;
mod environment;
mod execution;
use execution::run;
mod failure;
mod gate;
mod invitation_results;
mod live_results;
mod local_commands;
mod management;
mod membership_coordination;
mod membership_results;
mod membership_standing;
mod membership_supervision;
mod observation;
mod opening;
mod operations_bundle;
mod operations_selection;
mod presence;
mod publication_results;
mod realization;
mod recovery;
mod registration_results;
mod requests;
mod result_acquisition;
mod result_imports;
mod results;
mod retained_controls;
mod retention;
mod retirement;
mod sharing_results;
mod signaling;
mod source_lending;
mod submission;
mod upload_interruption;
mod uploads;
mod workspace_supervision;
use cases::Case;
use environment::{Database, Platform};
use failure::AbortAfterAdmission;
use glowcap::{
	Argument, Host, PendingWork, Ref, Result,
	loam::{self, Call, Content, ControlPowers, Invocation, Method, Registration, Requirement, Retry, Schema},
};
use rooms_application::{
	content::session::{self, custody, workspace::Intent},
	fields::List,
};
use rooms_runtime::session::managed;
use std::{cell::Cell, num::NonZeroU64, rc::Rc};
mod target;
mod terminal_observation;
use target::{TARGET, target_registration, target_registration_with_token};

fn unknown_reason(value: &Argument) -> &str {
	let Some([status, reason]) = value.as_list() else {
		panic!("unknown diagnostic contains no capability fields")
	};
	assert_eq!(status.as_str(), Some("unknown"));
	let reason = reason.as_str().expect("scalar observation reason");
	assert!(!reason.is_empty() && reason.encode_utf16().count() <= custody::MAX_OBSERVATION_REASON_UNITS);
	reason
}

fn key<K>() -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap())
}
async fn mutate(host: &Host, source: &Ref, verb: &str, args: &[Argument]) -> Result<Argument> {
	let sequence = host.send(source, "mutation-sequence", &[]).await?;
	let mut request = vec![sequence, Argument::String(verb.into())];
	request.extend_from_slice(args);
	host.send(source, "mutate", &request).await
}
async fn finished(host: &Host, access: &Ref, id: &str, source: &Ref) -> Argument {
	loop {
		let status = host
			.send(
				access,
				"effect-status",
				&[id.into(), Argument::Reference(source.clone())],
			)
			.await
			.unwrap_or_else(|error| panic!("effect {id} status: {error:?}"));
		if status.as_str() != Some("pending") {
			return status;
		}
		environment::yield_turn().await;
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn production_receipt_executor_checks_source_recovers_without_resending_and_settles_privately() {
	run(Case::operator()).await;
}
