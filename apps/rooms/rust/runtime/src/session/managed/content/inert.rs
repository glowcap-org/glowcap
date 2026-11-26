//! Private root verbs over receipts that hold their place in the replay window
//! until their source acts, which `revoked_receipts.rs` explains.
//! `inert-effects` names each one (`effects::holds_place`) with its source,
//! and `release-inert-effect` releases one without asking about its access,
//! retiring its paused executor as the source's own release does. A released
//! receipt holds no place, so a second sweep names it no more. A receipt
//! whose request runs, an executor or a history erasure, is never named,
//! because that request may still settle it, and a release that meets one started since the listing answers running
//! and keeps the receipt. The revoked receipt owner calls both through the
//! private root and releases only after it reads that the source's access is
//! revoked.
use super::*;

/// Both verbs take the private root as their first argument.
pub(super) fn requirement(input: Invocation<'_>, root: &Ref) -> Result<Requirement> {
	super::super::retained::authorize(input, root)?;
	Requirement::new(&[Permission::ManageCustody.key()], &[])
}

/// The operation `release-inert-effect` names.
fn selected(input: Invocation<'_>) -> Result<rooms_application::session::state::OperationId> {
	let [_, id, _] = input.args else {
		return Err(refuse(
			"release-inert-effect takes the root, an operation id, and its source",
		));
	};
	operation(id)
}

pub(super) fn references(input: Invocation<'_>, root: &Ref, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	super::super::retained::authorize(input, root)?;
	match input.verb {
		"inert-effects" => record
			.effects
			.as_slice()
			.iter()
			.filter(|receipt| effects::holds_place(receipt, false))
			.map(restore_source)
			.collect(),
		_ => {
			let id = selected(input)?;
			record
				.effects
				.as_slice()
				.iter()
				.find(|receipt| receipt.operation == id)
				.map(restore_source)
				.transpose()
				.map(|request| request.into_iter().collect())
		}
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
	if input.verb == "inert-effects" {
		list(owner, call, input, &record)
	} else {
		release(owner, call, input, &record)
	}
}

/// The receipts that hold their place until their source acts, each with its
/// source.
fn list<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &MetadataRecord,
) -> Result<Argument> {
	let mut rows = Vec::new();
	for receipt in record.effects.as_slice() {
		let id = text_of(&receipt.operation)?;
		// A running request can still settle its receipt, so it is not inert.
		// `release_receipt` asks the same `receipt_running`, so a release that
		// meets one started since this listing answers running as well.
		if !effects::holds_place(receipt, owner.receipt_running(id, record)) {
			continue;
		}
		let held = receipt.source.reference;
		let page = page_of(input, held, "invalid source page")?;
		rows.push(Argument::List(vec![
			id.into(),
			call.disclose_page(page, held.field, false)?,
		]));
	}
	Ok(Argument::List(rows))
}

/// Release the receipt the call names, once its source is the one given.
fn release<P: Tasks + Deadline + Clone + 'static>(
	owner: &std::rc::Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &MetadataRecord,
) -> Result<Argument> {
	let id = selected(input)?;
	let source = Ref::try_from(&input.args[2]).map_err(|_| refuse("original source capability required"))?;
	// An executor that started after the listing keeps its receipt, and its
	// settlement wakes the next sweep.
	release_receipt(
		owner,
		call,
		input,
		record,
		ReleaseRequest {
			id: &id,
			source: &source,
			intent: None,
			mismatch: "the receipt does not match its source and intent",
		},
	)
}
