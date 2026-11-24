//! Original-source receipt inspection and private terminal settlement.
use super::*;
pub(in crate::session::managed) fn status<R: custody::References>(
	receipt: &custody::EffectReceipt<R>,
	live: bool,
) -> Argument {
	Argument::String(
		match receipt.outcome {
			Outcome::Unresolved if live => "pending",
			Outcome::Unresolved => "unknown",
			Outcome::Unknown { .. } => "unknown",
			Outcome::KnownAbsent | Outcome::Refused { .. } => "unsent",
			Outcome::Committed { .. } => "committed",
		}
		.into(),
	)
}
pub(super) fn location(
	record: &MetadataRecord,
	id: &rooms_application::session::state::OperationId,
) -> Result<records::Location> {
	record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == id)
		.map(|receipt| receipt.source.reference)
		.ok_or_else(|| refuse("unknown effect"))
}
pub(super) fn restore_source(receipt: &custody::EffectReceipt<records::Metadata>) -> Result<ReferenceRequest> {
	let held = receipt.source.reference;
	Ok(ReferenceRequest::RestorePage {
		page: held.page.checked_sub(1).ok_or_else(|| refuse("invalid source page"))?,
		field: held.field,
	})
}
pub(in crate::session::managed) fn authenticate(
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &MetadataRecord,
	id: &rooms_application::session::state::OperationId,
	source: &Ref,
) -> Result<()> {
	if !sent_by(call, input, record, id, source)? {
		return Err(refuse("original source capability required"));
	}
	Ok(())
}
/// Whether `source` is the capability that sent operation `id`, which the
/// receipt's location in the record names.
fn sent_by(
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &MetadataRecord,
	id: &rooms_application::session::state::OperationId,
	source: &Ref,
) -> Result<bool> {
	let held = location(record, id)?;
	let page = page_of(input, held, "invalid source page")?;
	Ok(call.page_reference(page, held.field)? == *source)
}
pub(super) fn effect_requirement(intent: &Argument, additional: &[Permission]) -> Result<Requirement> {
	let canonical = text(intent)?;
	effect_requirement_text(canonical, additional)
}
fn effect_requirement_text(canonical: &str, additional: &[Permission]) -> Result<Requirement> {
	if canonical.starts_with('{') {
		if rooms_application::content::session::bridge::Request::read(canonical).is_err() {
			uploads::Intent::read(canonical).map_err(|error| refuse(&error.to_string()))?;
		}
		let permissions = core::iter::once(Permission::InteractWorkspace)
			.chain(additional.iter().copied())
			.map(|permission| permission.key())
			.collect::<Vec<_>>();
		Requirement::new(&permissions, &[])
	} else {
		command_requirement(&original_text(canonical)?, additional)
	}
}

pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	match input.verb {
		"effect-inventory" => {
			if !input.args.is_empty() {
				return Err(refuse("effect inventory takes no arguments"));
			}
			Requirement::new(&[Permission::ResolvePending.key()], &[])
		}
		// Which of its own receipts still keep a place asks no more than the
		// access that sent them is entitled to, whatever its rights have become
		// since, so being attached is the whole requirement.
		"held-effects" => {
			if !input.args.is_empty() {
				return Err(refuse("held effects take no arguments"));
			}
			Requirement::new(&[], &[])
		}
		// Whose receipt an operation is asks no more than the access that holds
		// one is entitled to, whatever its rights have become since, so being
		// attached is the whole requirement.
		"effect-holder" => {
			let [id] = input.args else {
				return Err(refuse("invalid receipt inspection arguments"));
			};
			operation(id)?;
			Requirement::new(&[], &[])
		}
		"effect-status" | "effect-intent" | "effect-adopted" => {
			let id = match (input.verb, input.args) {
				("effect-status", [id, _]) | ("effect-intent" | "effect-adopted", [id]) => id,
				_ => return Err(refuse("invalid receipt inspection arguments")),
			};
			let id = operation(id)?;
			let record = records::metadata(input)?;
			let receipt = record.effects.as_slice().iter().find(|receipt| receipt.operation == id);
			let Some(receipt) = receipt else {
				// An absent receipt answers void and discloses only its absence,
				// which `effect-holder` answers any attached access.
				if input.verb == "effect-intent" {
					return Requirement::new(&[], &[]);
				}
				return Err(refuse("unknown effect"));
			};
			// Inspecting a receipt needs the rights its effect needs now, and the
			// answer goes only to the source that sent it (`authenticate`). A
			// source reads back the intent it wrote and can give the receipt up,
			// and a source whose rights were narrowed below its effect's since
			// sending is refused, as `release-effect` refuses it.
			// Listing receipts and resuming an executor also need `ResolvePending`.
			effect_requirement_text(text_of(&receipt.canonical_intent)?, &[])
		}
		"resume-effect" => {
			let [_, intent] = input.args else {
				return Err(refuse("effect recovery takes operation id and original intent"));
			};
			effect_requirement(intent, &[Permission::ResolvePending])
		}
		// Release gives back a receipt only the original source made. It never
		// deletes the receipt and never dispatches. What it forfeits, an
		// unadopted result, only that same source could adopt, so it needs the
		// rights the effect needs now and no more: a source whose rights were
		// narrowed below its effect's since sending is refused, as the
		// inspection verbs refuse it.
		"release-effect" => {
			let [_, intent] = input.args else {
				return Err(refuse("effect release takes operation id and original intent"));
			};
			effect_requirement(intent, &[])
		}
		_ => Err(refuse("unknown recovery method")),
	}
}
pub(super) fn text_of<const N: usize, const REQUIRED: bool>(text: &Text<N, REQUIRED>) -> Result<&str> {
	text.text().as_str().ok_or_else(|| refuse("receipt text is not scalar"))
}
/// The receipt a release names, who sent it, and the refusal for a mismatch.
pub(super) struct ReleaseRequest<'a> {
	pub(super) id: &'a rooms_application::session::state::OperationId,
	/// The capability that sent the operation.
	pub(super) source: &'a Ref,
	/// The operation's original intent, or none for the receipt's own, which
	/// the private root's sweep releases by.
	pub(super) intent: Option<&'a Text<262144, true>>,
	/// The refusal text when `source` or `intent` do not match the receipt.
	pub(super) mismatch: &'a str,
}
/// Give back the receipt `request` names to the access that sent it, whichever
/// verb asks, by `effects::release`. A receipt the session no longer holds
/// answers released, so a retry does too and discloses no more than
/// `effect-intent` already does, except for the source's own job still
/// confirming its commit (`release_unrecorded`). A running request keeps its receipt, and
/// the answer is running (`State::receipt_running`): an executor, or the
/// history erasure the record names as pending, which has no executor. A paused executor runs again only if that same
/// source resumes it, so its source's release is the explicit forfeit of
/// both: the session retires the executor, as a restart would, and settles
/// the receipt as released. The receipt stays until the replay window evicts
/// it.
///
/// Every fallible step of this callback runs before the retirement, and only
/// the commit after the callback returns can still fail. A failed commit
/// leaves the receipt unresolved and reading unknown, with no executor. The
/// retirement the executor owned is already settled as unknown, or as absent
/// when it had dispatched nothing (`retirement::Owner::forfeit`). A retried
/// release finds no executor running, settles the receipt, and commits, and
/// the retirement it repeats finds no paused executor and does nothing.
pub(super) fn release_receipt<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &MetadataRecord,
	request: ReleaseRequest<'_>,
) -> Result<Argument> {
	let ReleaseRequest {
		id,
		source,
		intent,
		mismatch,
	} = request;
	let Some(receipt) = record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == id)
	else {
		// No receipt holds nothing, unless the source's own job is still
		// confirming the commit that would write one.
		let answer = text_of(id)
			.map(|operation| super::super::executor::release_unrecorded(owner, operation, source))
			.unwrap_or(effects::Release::Released);
		return Ok(answer.wire().into());
	};
	let intent = intent.unwrap_or(&receipt.canonical_intent);
	// A settlement that committed before its worker saw the answer left its
	// job paused, so retiring that job publishes the line it captured.
	let committed = matches!(receipt.outcome, Outcome::Committed { .. });
	authenticate(call, input, record, id, source)?;
	let operation = text_of(id)?;
	let mut decoded = records::decode(input)?;
	let held = decoded
		.effects
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == id)
		.map(|receipt| receipt.source.reference.clone())
		.ok_or_else(|| refuse("unknown effect"))?;
	let released = effects::release(
		&mut decoded.effects,
		id,
		&held,
		intent,
		owner.receipt_running(operation, record),
	)
	.map_err(|_| refuse(mismatch))?;
	// Only a release that changed the receipt has anything to commit.
	if released == effects::Released::Now {
		records::replace_effects(call, input, &decoded)?;
		super::super::executor::retire(owner, operation, committed);
	}
	Ok(released.answer().wire().into())
}
impl<P: Tasks + Deadline + Clone + 'static> SessionContent<P> {
	pub(super) fn receipt(
		&self,
		call: &mut Call<'_>,
		input: Invocation<'_>,
		owner: &std::rc::Rc<State<P>>,
	) -> Result<Argument> {
		let record = records::metadata(input)?;
		match input.verb {
			"effect-inventory" => {
				let source = call.source()?;
				// The codec caps the complete receipt population at MAX_EFFECTS.
				// Restore only those source fields; identity data cannot replace
				// the actual invoking endpoint or disclose a sibling's operation.
				let mut rows = Vec::new();
				for receipt in record.effects.as_slice() {
					if Field::Retained(receipt.source.reference).resolve(call, input)? != source {
						continue;
					}
					let id = text_of(&receipt.operation)?;
					rows.push(serde_json::json!({
						"operation": id,
						"status": status(receipt, owner.receipt_running(id, &record)).as_str(),
						"resumable": owner.holds(id),
					}));
				}
				Ok(serde_json::to_string(&rows)
					.map_err(|_| refuse("invalid effect inventory"))?
					.into())
			}
			"held-effects" => {
				let source = call.source()?;
				// A read of the caller's own receipts that still keep a place: the
				// operations it sent and has neither settled for good nor given up.
				// It names no status, so a source whose rights were narrowed since
				// learns only that its own request still holds a place. The codec
				// caps the receipts, and so the list, at MAX_EFFECTS.
				let mut held = Vec::new();
				for receipt in record.effects.as_slice() {
					if !effects::keeps_place(receipt)
						|| Field::Retained(receipt.source.reference).resolve(call, input)? != source
					{
						continue;
					}
					held.push(text_of(&receipt.operation)?.into());
				}
				Ok(Argument::List(held))
			}
			"effect-holder" => {
				let id = operation(&input.args[0])?;
				// A read: it answers who sent the operation and changes nothing.
				// Any access may ask, because operation ids are random and an
				// access that guesses one learns only that it exists.
				if !record.effects.as_slice().iter().any(|receipt| receipt.operation == id) {
					return Ok(effects::Holder::Nobody.wire().into());
				}
				let source = call.source()?;
				let holder = if sent_by(call, input, &record, &id, &source)? {
					effects::Holder::Mine
				} else {
					effects::Holder::Another
				};
				Ok(holder.wire().into())
			}
			"effect-intent" | "effect-adopted" | "resume-effect" => {
				let id = operation(&input.args[0])?;
				// Completed receipts can leave the replay window between inventory
				// and recovery. Absence is read-only and never admits a dispatch.
				if input.verb == "effect-intent"
					&& !record.effects.as_slice().iter().any(|receipt| receipt.operation == id)
				{
					return Ok(Argument::Void);
				}
				let source = call.source()?;
				authenticate(call, input, &record, &id, &source)?;
				let receipt = effects::recover(&record.effects, &id, &location(&record, &id)?)
					.map_err(|_| refuse("effect witness does not match"))?;
				let canonical = text_of(&receipt.canonical_intent)?;
				if input.verb == "effect-adopted" {
					return Ok((receipt.disposition == custody::Disposition::Adopted).into());
				}
				// An adopted or released receipt has nothing left to recover.
				if input.verb == "effect-intent" {
					return Ok(if receipt.disposition == custody::Disposition::Held {
						canonical.into()
					} else {
						Argument::Void
					});
				}
				if text(&input.args[1])? != canonical {
					return Err(refuse("effect recovery requires the original intent"));
				}
				let retained = owner.holds(text_of(&id)?);
				if !retained && matches!(receipt.outcome, Outcome::Unknown { .. }) {
					return Err(refuse("the original terminal observation cannot resume"));
				}
				if retained || matches!(receipt.outcome, Outcome::Unresolved) {
					// Only a retained executor can resume. A cold unknown receipt
					// never creates a new dispatch or infers an outcome.
					// Settlement can commit before its worker observes the reply.
					// Continue that exact owner even when the receipt is terminal.
					super::super::executor::resume(owner, text_of(&id)?)?;
				}
				Ok(status(receipt, owner.receipt_running(text_of(&id)?, &record)))
			}
			"release-effect" => {
				let [id, intent] = input.args else {
					return Err(refuse("effect release takes operation id and original intent"));
				};
				let id = operation(id)?;
				let intent = Text::new(text(intent)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
				let source = call.source()?;
				release_receipt(
					owner,
					call,
					input,
					&record,
					ReleaseRequest {
						id: &id,
						source: &source,
						intent: Some(&intent),
						mismatch: "effect release requires the original source and intent",
					},
				)
			}
			"effect-status" => {
				let [id, witness] = input.args else {
					return Err(refuse(
						"effect-status takes operation id and original source capability",
					));
				};
				let id = operation(id)?;
				let source = Ref::try_from(witness).map_err(|_| refuse("original source capability required"))?;
				authenticate(call, input, &record, &id, &source)?;
				let receipt = effects::recover(&record.effects, &id, &location(&record, &id)?)
					.map_err(|_| refuse("effect witness does not match"))?;
				Ok(status(receipt, owner.receipt_running(text(&input.args[0])?, &record)))
			}
			"effect-result" => {
				let [id, intent] = input.args else {
					return Err(refuse("effect-result takes operation id and original intent"));
				};
				let id = operation(id)?;
				let intent = Text::new(text(intent)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
				let source = call.source()?;
				authenticate(call, input, &record, &id, &source)?;
				let receipt = effects::inspect(&record.effects, &id, &location(&record, &id)?, &intent)
					.map_err(|_| refuse("original source and intent required"))?
					.ok_or_else(|| refuse("unknown effect"))?;
				let running = text(&input.args[0])?;
				Ok(results::disclose(&receipt.outcome, call, input)?
					.unwrap_or_else(|| status(receipt, owner.receipt_running(running, &record))))
			}
			"settle-effect" => {
				if call.source()? != owner.writer.root()? {
					return Err(refuse("private session root required"));
				}
				let [id, source, intent, outcome, provenance] = input.args else {
					return Err(refuse("invalid private settlement"));
				};
				let mut revoked = None;
				let reply = if text(intent)?.starts_with('{') {
					if rooms_application::content::session::bridge::Request::read(text(intent)?).is_ok() {
						rooms_application::session::effect::Reply::Acknowledgment
					} else {
						uploads::Intent::read(text(intent)?).map_err(|error| refuse(&error.to_string()))?;
						rooms_application::session::effect::Reply::Upload
					}
				} else {
					let args = original(intent)?;
					let declared = values(&args);
					let request = Request::parse(&declared).map_err(|error| refuse(&error.to_string()))?;
					let reply = super::super::command_reply(&request)
						.ok_or_else(|| refuse("session effect is invalid or not registered"))?;
					revoked = Dispatch::parse(&request)
						.ok()
						.and_then(|dispatch| dispatch.revoked_authority());
					reply
				};
				let id = operation(id)?;
				let source = Ref::try_from(source).map_err(|_| refuse("original source required"))?;
				let intent = Text::new(text(intent)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
				authenticate(call, input, &record, &id, &source)?;
				let mut record = records::decode(input)?;
				let receipt = record
					.effects
					.as_mut_slice()
					.iter_mut()
					.find(|receipt| receipt.operation == id)
					.ok_or_else(|| refuse("unknown effect"))?;
				results::restore(&mut receipt.outcome, call, input)?;
				let outcome = results::outcome(outcome, reply, &source, &receipt.outcome, call)?;
				let source_location = receipt.source.reference.clone();
				let changed = effects::settle(&mut record.effects, &id, &source_location, &intent, outcome)
					.map_err(|_| refuse("effect settlement differs"))?;
				if changed {
					if let Some(key) = revoked
						&& record.effects.as_slice().iter().any(|receipt| {
							receipt.operation == id && matches!(receipt.outcome, Outcome::Committed { .. })
						}) {
						local::retire_authority(&mut record.intent, &mut record.custody, key);
						records::replace(call, input, &mut record)?;
						return Ok(Argument::Void);
					}
					if rooms_application::content::session::bridge::Request::read(
						intent
							.text()
							.as_str()
							.ok_or_else(|| refuse("effect intent is not scalar text"))?,
					)
					.is_ok()
					{
						let applied = record
							.effects
							.as_slice()
							.iter()
							.find(|receipt| receipt.operation == id)
							.is_some_and(|receipt| matches!(receipt.outcome, Outcome::Committed { .. }));
						for witness in record
							.bridges
							.as_mut_slice()
							.iter_mut()
							.filter(|witness| witness.operation == id)
						{
							witness.applied = applied;
						}
						records::replace(call, input, &mut record)?;
						return Ok(Argument::Void);
					}
					if !matches!(provenance, Argument::Void) {
						super::super::outgoing::adopt(&mut record, &id, provenance)?;
						records::replace(call, input, &mut record)?;
						return Ok(Argument::Void);
					}
					let receipt = effects::recover(&record.effects, &id, &source_location)
						.map_err(|_| refuse("unknown effect"))?;
					records::settle_effect(call, input, &record, receipt)?;
				}
				Ok(Argument::Void)
			}
			_ => Err(refuse("unknown receipt method")),
		}
	}
}
