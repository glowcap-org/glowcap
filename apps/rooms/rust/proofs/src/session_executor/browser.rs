//! One inventory names complete scenarios, their groups, and their execution.
//! The browser gives each scenario an independent deadline.
use super::*;
use std::{future::Future, pin::Pin};
use wasm_bindgen::prelude::*;

struct Scenario {
	group: u8,
	name: &'static str,
	run: fn() -> Pin<Box<dyn Future<Output = ()>>>,
}
macro_rules! scenario {
	($group:literal, $run:path) => {
		Scenario {
			group: $group,
			name: stringify!($run),
			run: || Box::pin($run()),
		}
	};
}
const SCENARIOS: &[Scenario] = &[
	scenario!(1, submission::run),
	scenario!(1, results::run),
	scenario!(1, live_results::run),
	scenario!(1, membership_results::run),
	scenario!(1, membership_supervision::run),
	scenario!(1, invitation_results::run),
	scenario!(1, publication_results::run),
	scenario!(1, sharing_results::run),
	scenario!(1, creation_results::run),
	scenario!(1, connection_results::run),
	scenario!(1, direct_results::run),
	scenario!(2, bundle_imports::run),
	scenario!(2, operations_bundle::run),
	scenario!(2, registration_results::realization),
	scenario!(2, registration_results::run),
	scenario!(2, source_lending::run),
	scenario!(2, uploads::run),
	scenario!(2, retirement::run),
	scenario!(2, authority_retirement::run),
	scenario!(2, local_commands::run),
	scenario!(3, terminal_observation::run),
	scenario!(3, bridge::run),
	scenario!(3, bridge::physical_recovery),
	scenario!(3, retention::run),
	scenario!(3, discovery_watch::run),
	scenario!(3, presence::run),
	scenario!(3, signaling::run),
	scenario!(3, archive_readers::run),
	scenario!(3, management::run),
	scenario!(3, observation::run),
	scenario!(3, opening::run),
	scenario!(3, direct_restart::run),
	scenario!(3, retained_controls::run),
];

#[wasm_bindgen]
pub fn rooms_session_executor_scenarios(group: u8) -> Vec<String> {
	if group == 0 {
		return dispatch_cases().map(|(name, _)| name).collect();
	}
	SCENARIOS
		.iter()
		.filter(|scenario| scenario.group == group)
		.map(|scenario| scenario.name.into())
		.collect()
}

#[wasm_bindgen]
pub async fn rooms_session_executor_scenario_contract(name: String) -> std::result::Result<(), JsValue> {
	crate::async_host::install_panic_hook();
	if name.starts_with("dispatch/") {
		let (_, case) = dispatch_cases()
			.find(|(candidate, _)| *candidate == name)
			.ok_or_else(|| JsValue::from_str("unknown dispatch scenario"))?;
		run(case).await;
		return Ok(());
	}
	let scenario = SCENARIOS
		.iter()
		.find(|scenario| scenario.name == name)
		.ok_or_else(|| JsValue::from_str("unknown session executor scenario"))?;
	(scenario.run)().await;
	Ok(())
}

fn dispatch_cases() -> impl Iterator<Item = (String, Case)> {
	[
		Case::operator(),
		Case::operations(),
		Case::kick(),
		Case::revoke("room"),
		Case::revoke("steward"),
		Case::policy(false),
		Case::policy(true),
		Case::subject(),
		Case::away(),
		Case::line(false),
		Case::line(true),
	]
	.into_iter()
	.chain(Case::other_operations())
	.enumerate()
	.map(|(index, case)| (format!("dispatch/{index}/{}", case.verb), case))
}
