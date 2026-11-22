//! Private root verbs over committed receipts nobody adopted. Only a receipt's
//! original source can adopt or release one, so a source whose access is
//! revoked leaves it holding a receipt place for good. `unadopted-effects`
//! names each such receipt with its source, and `release-unadopted-effect`
//! drops one without asking about its access. The session's revoked receipt
//! owner (`revoked_receipts.rs`) calls both through the private root and
//! releases only after it reads that the source's access is revoked.
use super::*;

/// Both verbs take the private root as their first argument.
pub(super) fn requirement(input: Invocation<'_>, root: &Ref) -> Result<Requirement> {
	super::super::retained::authorize(input, root)?;
	Requirement::new(&[Permission::ManageCustody.key()], &[])
}

/// The receipt `release-unadopted-effect` names, when the session still holds it.
fn selected<'a>(
	input: Invocation<'_>,
	record: &'a MetadataRecord,
) -> Result<Option<&'a custody::EffectReceipt<records::Metadata>>> {
	let [_, id, _] = input.args else {
		return Err(refuse(
			"release-unadopted-effect takes the root, an operation id, and its source",
		));
	};
	let id = operation(id)?;
	Ok(record.effects.as_slice().iter().find(|receipt| receipt.operation == id))
}

pub(super) fn references(input: Invocation<'_>, root: &Ref, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	super::super::retained::authorize(input, root)?;
	match input.verb {
		"unadopted-effects" => record
			.effects
			.as_slice()
			.iter()
			.filter(|receipt| effects::awaits_adoption(*receipt))
			.map(restore_source)
			.collect(),
		_ => selected(input, record)?
			.map(restore_source)
			.transpose()
			.map(|request| request.into_iter().collect()),
	}
}

pub(super) fn invoke<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let root = owner.writer.root()?;
	super::super::retained::authorize(input, &root)?;
	if call.source()? != root {
		return Err(refuse("private session root required"));
	}
	let record = records::metadata(input)?;
	if input.verb == "unadopted-effects" {
		let mut rows = Vec::new();
		for receipt in record.effects.as_slice() {
			let id = receipt
				.operation
				.text()
				.as_str()
				.ok_or_else(|| refuse("receipt text is not scalar"))?;
			// A retained executor can still settle its receipt, so it is not left.
			if !effects::awaits_adoption(receipt) || owner.jobs.borrow().contains_key(id) {
				continue;
			}
			let held = receipt.source.reference;
			let page = input
				.graph
				.and_then(|pages| pages.get(held.page.checked_sub(1)?))
				.ok_or_else(|| refuse("invalid source page"))?;
			rows.push(Argument::List(vec![
				id.into(),
				call.disclose_page(page, held.field, false)?,
			]));
		}
		return Ok(Argument::List(rows));
	}
	let Some(receipt) = selected(input, &record)? else {
		// Absence is the released state, so a retry answers done.
		return Ok(Argument::Void);
	};
	let id = receipt.operation.clone();
	let source = Ref::try_from(&input.args[2]).map_err(|_| refuse("original source capability required"))?;
	authenticate(call, input, &record, &id, &source)?;
	if !effects::awaits_adoption(receipt) {
		return Err(refuse("the receipt does not hold an unadopted result"));
	}
	let retained = owner.jobs.borrow().contains_key(text_of(&id)?);
	let intent = receipt.canonical_intent.clone();
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
			effects::Refusal::Unresolved => "the original executor remains retained",
			_ => "the receipt does not match its source and intent",
		})
	})?;
	records::replace_effects(call, input, &record)?;
	Ok(Argument::Void)
}

fn text_of(id: &rooms_application::session::state::OperationId) -> Result<&str> {
	id.text().as_str().ok_or_else(|| refuse("receipt text is not scalar"))
}
