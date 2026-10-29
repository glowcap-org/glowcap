//! The diagnostic capability: `snapshot` answers what this server publishes
//! and who is here, as `[kind, name, note]` rows, and nothing that acts.
use super::super::state::Shared;
use glowcap::Argument;
use rooms_application::server::operations::inspect::{self, SessionFace, View};

const SNAPSHOT: &str = rooms_application::protocol_data::SNAPSHOT;

pub(super) fn behavior(shared: Shared) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if super::carries_capability(args) {
			return Err(format!("diagnostics {verb} does not take capability arguments"));
		}
		if verb != SNAPSHOT {
			return Err(format!("diagnostics has no method {verb}"));
		}
		if !args.is_empty() {
			return Err("snapshot takes no arguments".into());
		}
		snapshot(&shared)
	}
}

pub(super) fn snapshot(shared: &Shared) -> Result<Argument, String> {
	let state = shared.borrow();
	let sessions = state
		.session_faces()
		.map(|face| SessionFace {
			transport: face.transport,
			nick: face.nick,
		})
		.collect();
	let irc = super::super::irc::operator::faces(&state)?;
	let journal = state.journal.borrow();
	let view = View {
		rooms: &state.rooms,
		directory: &state.policy,
		authority: &state.authority,
		sessions,
		journal: &journal,
		irc: &irc,
	};
	let mut rows = inspect::snapshot(&view, |name| state.steward_link(name));
	let (retained, counters) = state.admission.statistics();
	rows.push(rooms_application::server::operations::inspect::Row {
		kind: "admission",
		name: "process-local work budgets".into(),
		note: format!(
			"{}; retained {retained}; admitted {}; refused {}; coalesced {}; capacity {}",
			state.admission.settings.summary(),
			counters.admitted,
			counters.refused,
			counters.coalesced,
			counters.capacity
		),
	});
	for class in rooms_application::admission::CLASSES {
		let counts = counters.classes[class as usize];
		rows.push(rooms_application::server::operations::inspect::Row {
			kind: "admission",
			name: class.name().into(),
			note: format!(
				"admitted {}; refused {}; coalesced {}",
				counts.admitted, counts.refused, counts.coalesced
			),
		});
	}
	Ok(Argument::List(
		rows.into_iter()
			.map(|row| {
				Argument::List(vec![
					Argument::String(row.kind.into()),
					Argument::String(row.name),
					Argument::String(row.note),
				])
			})
			.collect(),
	))
}
