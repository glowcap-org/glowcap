//! One command admission stages its original source, intent and exact targets.
use super::super::{
	State,
	executor::Seat,
	records::{self, Field, References},
};
use super::{dispatch, refuse, values};
use glowcap::{
	Argument, Ref, Result,
	loam::{self, Call, Invocation},
};
use rooms_application::{
	content::session::{
		custody::{self, FieldKey, Held, Outcome},
		effects, local,
	},
	fields::{List, Text},
	session::command::Request,
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{num::NonZeroU64, rc::Rc};

pub(super) fn admit<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	mut record: records::Record,
) -> Result<Argument> {
	let declared = values(input.args);
	let request = Request::parse(&declared).map_err(|error| loam::refusal(error.to_string()))?;
	let operation = Text::new(request.id().into()).ok_or_else(|| refuse("invalid operation id"))?;
	let canonical = request.canonical().map_err(|_| refuse("invalid command intent"))?;
	let intent = Text::new(canonical.clone().into()).ok_or_else(|| refuse("effect intent exceeds receipt capacity"))?;
	if request.base() != input.content_revision {
		// This reply proves absence of admission: no receipt, continuation or
		// upstream effect was installed. Callers may prepare a new gesture only
		// after comparing its original selection with the current workspace.
		return Ok("conflict".into());
	}
	if local::recognizes(request.route()) {
		let retention = matches!(
			request.route(),
			rooms_application::session::command::Route::Checkpoint(
				rooms_application::session::checkpoint::commands::Command::ChooseHistoryRetention
			)
		);
		if retention && record.intent.history_erasure.is_some() {
			return Err(refuse(
				"history erasure is still pending; recover its original operation",
			));
		}
		local::apply(&request, &mut record.intent, &mut record.custody)
			.map_err(|_| refuse("invalid workspace gesture"))?;
		let erasing = retention && !record.intent.keep_history;
		if erasing && owner.recording.borrow().is_none() {
			return Err(refuse("session recording owner is not installed"));
		}
		if erasing {
			record.intent.history_erasure = Some(operation.clone());
		}
		let source = call.source()?;
		reserve(
			owner,
			&mut record,
			receipt(input, operation.clone(), intent.clone(), source.clone(), Vec::new())?,
		)?;
		if !erasing {
			effects::settle(
				&mut record.effects,
				&operation,
				&Field::Held(source),
				&intent,
				Outcome::Committed {
					result: Text::new("null".into()).expect("local acknowledgment"),
					retained: List::default(),
				},
			)
			.map_err(|_| refuse("workspace receipt settlement differs"))?;
		}
		records::replace(call, input, &mut record)?;
		return Ok(if erasing { "pending" } else { "committed" }.into());
	}
	if super::super::archive_sharing::recognizes(request.route()) {
		return super::super::archive_sharing::admit(owner, call, input, record, &request);
	}
	let dispatch = dispatch(input.args)?;
	let retiring_membership = dispatch.retires_membership();
	let retiring_publication = dispatch.retires_publication();
	let dependent_argument = dispatch.dependent_argument();
	let argument_position = dispatch.argument_position();
	let revocation = dispatch.revokes_selected();
	let coordinates = dispatch
		.targets(&record.intent)
		.map_err(|_| refuse("effect target is not selected in this workspace"))?;
	let (_, mutation) = dispatch
		.bind(&record.intent)
		.map_err(|_| refuse("effect target is not selected in this workspace"))?;
	let targets = coordinates
		.iter()
		.map(|coordinate| {
			let target = record
				.custody
				.get(*coordinate)
				.ok_or_else(|| refuse("effect target custody is absent"))?;
			records::reference(&target).resolve(call, input)
		})
		.collect::<Result<Vec<_>>>()?;
	let mut runtime_targets = targets.clone();
	if dependent_argument {
		let coordinate = coordinates.get(1).expect("declared callback");
		let target = record.custody.get(*coordinate).expect("resolved callback");
		let Field::Retained(location) = records::reference(&target) else {
			return Err(refuse("callback must be selected from retained custody"));
		};
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid callback page"))?;
		runtime_targets[1] = Ref::try_from(&call.disclose_page(page, location.field, true)?)
			.map_err(|_| refuse("callback capability required"))?;
	}
	let seat = Seat::reserve(owner, request.id())?;
	// Disclosure lends callback custody only through this call. The
	// continuation owns the facet before any commit or worker wait.
	let (reservation, pending) = call.reserve_continuation_copying(&runtime_targets)?;
	let mut args = Vec::with_capacity(mutation.args.len() + usize::from(coordinates.len() > 1));
	args.extend(mutation.args.into_iter().map(rooms_glowcap::effect_argument));
	if revocation {
		let field = record.custody.get(coordinates[1]).expect("selected revocation custody");
		let Field::Retained(location) = records::reference(&field) else {
			return Err(refuse("selected revocation custody is not stored"));
		};
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid revocation page"))?;
		let uri = call
			.page_saved_uri(page, location.field)?
			.ok_or_else(|| refuse("selected authority has no publication recipe"))?;
		let token = rooms_glowcap::routes::authority_token(uri)
			.map_err(|error| *error)?
			.ok_or_else(|| refuse("selected authority has no publication identity"))?;
		args.push(token.into());
	} else if coordinates.len() > 1 {
		let index = argument_position.unwrap_or(args.len());
		args.insert(index, Argument::Reference(reservation.target(1)?));
	}
	let source = reservation.source()?;
	let outgoing = if coordinates[0].role == custody::Role::DirectAccess
		&& mutation.reply == rooms_application::session::effect::Reply::Line
	{
		let arguments: Vec<_> = request.args().collect();
		let conversation = arguments[0];
		let text = arguments[1];
		let previews =
			rooms_application::open_graph::Selection::decode(text, arguments.get(2).copied().unwrap_or("[]"))
				.map_err(|_| refuse("invalid outgoing previews"))?;
		Some(super::super::outgoing::Capture::post(
			owner,
			&mut record,
			input,
			source.clone(),
			super::super::outgoing::Post {
				conversation,
				text,
				previews,
				files: &[],
			},
		)?)
	} else if coordinates[0].role == custody::Role::Line {
		let change = if mutation.verb == rooms_application::protocol_data::WITHDRAW {
			rooms_application::room::message::ChangeKind::Withdrawn
		} else {
			rooms_application::room::message::ChangeKind::Edited
		};
		super::super::outgoing::Capture::change(
			owner,
			&mut record,
			call,
			input,
			coordinates[0],
			super::super::outgoing::Edit {
				text: args.first().and_then(Argument::as_str).unwrap_or(""),
				change,
				keep: None,
				submitted: &[],
			},
		)?
	} else {
		None
	};
	if retiring_membership {
		let coordinate = coordinates[0];
		local::retire_membership(
			&mut record.intent,
			&mut record.custody,
			FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
		)
		.map_err(|_| refuse("selected membership has changed"))?;
	}
	if retiring_publication {
		let coordinate = coordinates[0];
		local::retire_publication(
			&mut record.intent,
			&mut record.custody,
			FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
		)
		.map_err(|_| refuse("selected publication has changed"))?;
	}
	let retained = coordinates
		.into_iter()
		.enumerate()
		.map(|(index, coordinate)| {
			// Receipts save the original checked fields. The runtime
			// callback facet is derived once from those exact inputs.
			records::restored(coordinate, Field::Held(targets[index].clone()))
		})
		.collect();
	let mut admitted = receipt(input, operation, intent, source.clone(), retained)?;
	if request.name() == "startDirect" {
		let mut args = request.args();
		let id = args.next().expect("admitted directory");
		let registration = args.nth(1).expect("admitted peer registration");
		let opening = args.next().expect("admitted opening");
		let directory = record
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id.text().as_str() == Some(id))
			.expect("admitted directory");
		if let (Some(name), Some(callback)) = (directory.name, directory.inbox) {
			admitted.introduction = Some(rooms_application::content::session::workspace::Introduction {
				access: directory.access,
				name,
				callback,
				registration: Text::new(registration.into()).expect("admitted registration"),
				opening: Text::new(opening.into()).expect("admitted opening"),
			});
		}
	}
	admitted.outgoing = outgoing.as_ref().map(super::super::outgoing::Capture::reservation);
	reserve(owner, &mut record, admitted)?;
	if retiring_membership || retiring_publication {
		records::replace(call, input, &mut record)?;
	} else {
		records::replace_effects(call, input, &record)?;
	}
	seat.start(
		pending,
		source,
		canonical,
		super::super::executor::CallIntent {
			reply: mutation.reply,
			verb: mutation.verb,
			args,
		},
		outgoing,
	)?;
	Ok(Argument::String("pending".into()))
}
pub(in crate::session::managed) fn receipt(
	input: Invocation<'_>,
	operation: rooms_application::session::state::OperationId,
	canonical_intent: Text<262144, true>,
	source: Ref,
	targets: Vec<custody::RetainedField<References>>,
) -> Result<custody::EffectReceipt<References>> {
	let generation =
		NonZeroU64::new(input.bound_resource.id.generation).ok_or_else(|| refuse("invalid resource incarnation"))?;
	Ok(custody::EffectReceipt {
		operation,
		adopted: false,
		outgoing: None,
		introduction: None,
		canonical_intent,
		resource_generation: generation,
		source: Held {
			key: FieldKey::new(NonZeroU64::new(1).expect("nonzero source slot"), generation),
			reference: Field::Held(source),
		},
		targets: List::new(targets).ok_or_else(|| refuse("too many declared effect targets"))?,
		outcome: Outcome::Unresolved,
	})
}
pub(in crate::session::managed) fn reserve<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	record: &mut records::Record,
	receipt: custody::EffectReceipt<References>,
) -> Result<()> {
	effects::reserve(&mut record.effects, receipt, |operation| {
		owner
			.jobs
			.borrow()
			.contains_key(operation.text().as_str().expect("operation text"))
	})
	.map_err(|_| refuse("effect receipts are full"))
}
