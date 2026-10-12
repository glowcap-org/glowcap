//! Viewer admission stays in Loam. Activity actors retain and check the
//! original callback. No capability is recreated from a presentation token.
use super::*;
use glowcap::loam::{ReadInterface, ReadMethod};

pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	let permissions = match input.verb {
		"acquire-activity" | "activity-recipe" | "retain-incoming" => {
			&[Permission::ManageCustody, Permission::ReplaceWorkspace][..]
		}
		"activity-reader" if input.args.is_empty() => &[Permission::ObserveWorkspace][..],
		"activity-file" => {
			file(input.args)?;
			&[Permission::ReadFile][..]
		}
		_ => return Err(refuse("invalid session activity request")),
	};
	Requirement::new(
		&permissions
			.iter()
			.map(|permission| permission.key())
			.collect::<Vec<_>>(),
		&[],
	)
}

struct Ingress<P: Tasks> {
	event: std::rc::Rc<super::super::activity::Event<P>>,
	admission: [Argument; 2],
	acquisition: [Argument; 4],
}
impl<P: Tasks + Deadline + Clone + 'static> Ingress<P> {
	fn read(owner: &std::rc::Rc<State<P>>, input: Invocation<'_>) -> Result<Self> {
		let [
			Argument::String(token),
			destination,
			source,
			expected,
			Argument::List(releases),
			intent,
		] = input.args
		else {
			return Err(refuse(
				"acquire-activity takes token, destination, optional source, revision, releases and intent",
			));
		};
		let event = owner.activity.event(owner.activity.parse_token(token)?)?;
		if !event.origin.is_open() {
			return Err(refuse("original incoming callback has retired"));
		}
		let incoming = event
			.incoming
			.as_ref()
			.ok_or_else(|| refuse("event carries no incoming authority"))?;
		let destination =
			custody::Coordinate::decode(text(destination)?).map_err(|_| refuse("invalid incoming destination"))?;
		if incoming.role() != destination.role {
			return Err(refuse("incoming destination must preserve its role"));
		}
		let (selected, inbox) = event
			.origin
			.installed()
			.ok_or_else(|| refuse("incoming requires an installed callback"))?;
		let admission = [
			serde_json::to_string(selected)
				.map_err(|_| refuse("invalid incoming origin"))?
				.into(),
			inbox.clone().into(),
		];
		let (reference, uri) = match incoming {
			super::super::activity::Incoming::Hand(_, reference) => (reference.clone(), Argument::Void),
			super::super::activity::Incoming::Offer(_, uri, resolved) => (
				resolved
					.borrow()
					.as_ref()
					.cloned()
					.ok_or_else(|| refuse("original offered capability has not been retained"))?,
				uri.as_str().into(),
			),
		};
		let mut entries = vec![Argument::List(vec![
			serde_json::to_string(&destination)
				.map_err(|_| refuse("invalid incoming destination"))?
				.into(),
			reference.into(),
			uri,
		])];
		if !matches!(source, Argument::Void) {
			let source =
				custody::Coordinate::decode(text(source)?).map_err(|_| refuse("invalid incoming source coordinate"))?;
			if source.role != custody::Role::SessionAccess {
				return Err(refuse("incoming source requires session access custody"));
			}
			entries.push(Argument::List(vec![
				serde_json::to_string(&source)
					.map_err(|_| refuse("invalid incoming source"))?
					.into(),
				event.origin.source().clone().into(),
				Argument::Void,
			]));
		}
		Ok(Self {
			event,
			admission,
			acquisition: [
				expected.clone(),
				Argument::List(entries),
				Argument::List(releases.clone()),
				intent.clone(),
			],
		})
	}
}
pub(super) fn references<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	input: Invocation<'_>,
	record: &MetadataRecord,
) -> Result<Vec<ReferenceRequest>> {
	if matches!(input.verb, "activity-recipe" | "retain-incoming") {
		let Some(Argument::String(token)) = input.args.first() else {
			return Err(refuse("incoming preparation requires an original token"));
		};
		let event = owner.activity.event(owner.activity.parse_token(token)?)?;
		if !event.origin.is_open() {
			return Err(refuse("original incoming callback has retired"));
		}
		let (selected, inbox) = event
			.origin
			.installed()
			.ok_or_else(|| refuse("incoming requires an installed callback"))?;
		let args = [
			serde_json::to_string(selected)
				.map_err(|_| refuse("invalid incoming origin"))?
				.into(),
			inbox.clone().into(),
		];
		let mut references = inbox::references(
			Invocation {
				verb: "check-inbox",
				args: &args,
				..input
			},
			record,
		)?;
		if input.verb == "retain-incoming" {
			let [_, Argument::Reference(reference)] = input.args else {
				return Err(refuse("incoming retention requires one held capability"));
			};
			let Some(super::super::activity::Incoming::Offer(_, uri, _)) = event.incoming.as_ref() else {
				return Err(refuse("original event carries no offered recipe"));
			};
			references.push(ReferenceRequest::Save {
				reference: reference.clone(),
				uri: Some(uri.clone()),
			});
		} else if input.args.len() != 1 {
			return Err(refuse("activity recipe takes one original token"));
		}
		return Ok(references);
	}
	let request = Ingress::read(owner, input)?;
	let mut references = inbox::references(
		Invocation {
			verb: "check-inbox",
			args: &request.admission,
			..input
		},
		record,
	)?;
	references.extend(acquisition::references_from(
		Invocation {
			verb: "acquire-workspace",
			args: &request.acquisition,
			..input
		},
		record,
		Some(request.event.origin.source()),
	)?);
	Ok(references)
}
pub(super) fn acquire<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let request = Ingress::read(owner, input)?;
	if call.source()? != *request.event.origin.source() {
		return Err(refuse("original incoming source capability required"));
	}
	inbox::invoke(
		call,
		Invocation {
			verb: "check-inbox",
			args: &request.admission,
			..input
		},
	)?;
	acquisition::invoke_from(
		call,
		Invocation {
			verb: "acquire-workspace",
			args: &request.acquisition,
			..input
		},
		Some(request.event.origin.source()),
	)
}
fn file(args: &[Argument]) -> Result<(&str, usize)> {
	let [Argument::String(token), Argument::Integer(index)] = args else {
		return Err(refuse("activity-file takes an event token and file index"));
	};
	Ok((
		token.as_str(),
		usize::try_from(*index).map_err(|_| refuse("invalid file index"))?,
	))
}
pub(super) fn invoke<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	if matches!(input.verb, "activity-recipe" | "retain-incoming") {
		let Some(Argument::String(token)) = input.args.first() else {
			return Err(refuse("incoming preparation requires an original token"));
		};
		let event = owner.activity.event(owner.activity.parse_token(token)?)?;
		if !event.origin.is_open() || call.source()? != *event.origin.source() {
			return Err(refuse("original incoming source capability required"));
		}
		let (selected, inbox) = event
			.origin
			.installed()
			.ok_or_else(|| refuse("incoming requires an installed callback"))?;
		let args = [
			serde_json::to_string(selected)
				.map_err(|_| refuse("invalid incoming origin"))?
				.into(),
			inbox.clone().into(),
		];
		inbox::invoke(
			call,
			Invocation {
				verb: "check-inbox",
				args: &args,
				..input
			},
		)?;
		if input.verb == "retain-incoming" {
			let [_, Argument::Reference(reference)] = input.args else {
				return Err(refuse("incoming retention requires one held capability"));
			};
			let Some(super::super::activity::Incoming::Offer(_, _, resolved)) = event.incoming.as_ref() else {
				return Err(refuse("original event carries no offered recipe"));
			};
			let mut held = resolved.borrow_mut();
			if held.as_ref().is_some_and(|prior| prior != reference) {
				return Err(refuse("original offered capability cannot be replaced"));
			}
			if held.is_none() {
				*held = Some(call.retain_prepared_reference(reference)?);
			}
			return Ok(Argument::Void);
		}
		return Ok(match event.incoming.as_ref() {
			Some(super::super::activity::Incoming::Offer(_, uri, resolved)) => {
				if resolved.borrow().is_some() {
					Argument::Void
				} else {
					uri.as_str().into()
				}
			}
			Some(super::super::activity::Incoming::Hand(_, _)) => Argument::Void,
			None => return Err(refuse("event carries no incoming authority")),
		});
	}
	let actor = match input.verb {
		"activity-reader" => owner.activity.read_actor()?,
		"activity-file" => {
			let (token, index) = file(input.args)?;
			owner.activity.file(owner.activity.parse_token(token)?, index)?
		}
		_ => return Err(refuse("unknown session activity method")),
	};
	let methods = [ReadMethod {
		verb: rooms_application::protocol_data::READ,
		results: &[],
	}];
	call.disclose_reads_copying(&actor, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
