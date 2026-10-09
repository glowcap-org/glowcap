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
			Outcome::KnownAbsent => "unsent",
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
	let held = location(record, id)?;
	let page = input
		.graph
		.and_then(|pages| pages.get(held.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid source page"))?;
	if call.page_reference(page, held.field)? != *source {
		return Err(refuse("original source capability required"));
	}
	Ok(())
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
		"effect-intent" | "effect-adopted" => {
			let [id] = input.args else {
				return Err(refuse("effect intent takes one operation id"));
			};
			let id = operation(id)?;
			let record = records::metadata(input)?;
			let receipt = record.effects.as_slice().iter().find(|receipt| receipt.operation == id);
			let Some(receipt) = receipt else {
				if input.verb == "effect-intent" {
					return Requirement::new(&[Permission::ResolvePending.key()], &[]);
				}
				return Err(refuse("unknown effect"));
			};
			effect_requirement_text(text_of(&receipt.canonical_intent)?, &[Permission::ResolvePending])
		}
		"resume-effect" | "release-effect" => {
			let [_, intent] = input.args else {
				return Err(refuse("effect recovery takes operation id and original intent"));
			};
			effect_requirement(intent, &[Permission::ResolvePending])
		}
		_ => Err(refuse("unknown recovery method")),
	}
}
fn text_of<const N: usize, const REQUIRED: bool>(text: &Text<N, REQUIRED>) -> Result<&str> {
	text.text().as_str().ok_or_else(|| refuse("receipt text is not scalar"))
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
						"status": status(receipt, owner.receipt_running(id, record.intent.history_erasure.as_ref())).as_str(),
						"resumable": owner.jobs.borrow().contains_key(id),
					}));
				}
				Ok(serde_json::to_string(&rows)
					.map_err(|_| refuse("invalid effect inventory"))?
					.into())
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
					return Ok(receipt.adopted.into());
				}
				if input.verb == "effect-intent" {
					return Ok(if receipt.adopted {
						Argument::Void
					} else {
						canonical.into()
					});
				}
				if text(&input.args[1])? != canonical {
					return Err(refuse("effect recovery requires the original intent"));
				}
				if matches!(receipt.outcome, Outcome::Unknown { .. }) {
					return Err(refuse("the original terminal observation cannot resume"));
				}
				if matches!(receipt.outcome, Outcome::Unresolved) {
					// Only a retained executor can resume. A cold unknown receipt
					// never creates a new dispatch or infers an outcome.
					super::super::executor::resume(owner, text_of(&id)?)?;
				}
				Ok(status(
					receipt,
					owner.receipt_running(text_of(&id)?, record.intent.history_erasure.as_ref()),
				))
			}
			"release-effect" => {
				let [id, intent] = input.args else {
					return Err(refuse("effect release takes operation id and original intent"));
				};
				let id = operation(id)?;
				let intent = Text::new(text(intent)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
				// Absence is the released state, so a retry answers done and
				// discloses no more than effect-intent already does.
				if !record.effects.as_slice().iter().any(|receipt| receipt.operation == id) {
					return Ok(Argument::Void);
				}
				let source = call.source()?;
				authenticate(call, input, &record, &id, &source)?;
				// A paused executor retains the same admitted continuation and
				// can resume during recovery. Its receipt must survive as long
				// as that owner, including across observation deadlines.
				let retained = owner.jobs.borrow().contains_key(text_of(&id)?);
				let mut record = records::decode(input)?;
				let held = record
					.effects
					.as_slice()
					.iter()
					.find(|receipt| receipt.operation == id)
					.map(|receipt| receipt.source.reference.clone())
					.ok_or_else(|| refuse("unknown effect"))?;
				effects::release(&mut record.effects, &id, &held, &intent, retained).map_err(|error| {
					refuse(match error {
						effects::Refusal::Unresolved => {
							"the original executor remains retained; recover it before releasing"
						}
						_ => "effect release requires the original source and intent",
					})
				})?;
				records::replace_effects(call, input, &record)?;
				Ok(Argument::Void)
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
				Ok(status(
					receipt,
					owner.receipt_running(text(&input.args[0])?, record.intent.history_erasure.as_ref()),
				))
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
				Ok(results::disclose(&receipt.outcome, call, input)?.unwrap_or_else(|| {
					status(
						receipt,
						owner.receipt_running(
							text(&input.args[0]).expect("checked id"),
							record.intent.history_erasure.as_ref(),
						),
					)
				}))
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
					if super::super::archive_sharing::recognizes(request.route()) {
						if request.route()
							== rooms_application::session::command::Route::Effect(
								rooms_application::session::command::Effect::RevokeIssuedArchiveShare,
							) {
							rooms_application::session::effect::Reply::Boolean
						} else {
							rooms_application::session::effect::Reply::Acknowledgment
						}
					} else {
						let dispatch = dispatch(&args)?;
						revoked = dispatch.revoked_authority();
						dispatch.mutation.reply
					}
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
						intent.text().as_str().expect("scalar intent"),
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
