//! Private supervision observes one exact installed direct route. Metadata
//! stays in the bounded membership registry, never in a public reply or store.
use super::*;
use std::rc::Rc;

fn callback(input: Invocation<'_>) -> Result<Invocation<'_>> {
	if input.args.len() != 4 {
		return Err(refuse("direct observation takes owner, selection, callback and worker"));
	}
	Ok(Invocation {
		args: &input.args[1..3],
		..input
	})
}
fn target(input: Invocation<'_>, record: &MetadataRecord) -> Result<Option<records::Location>> {
	let workspace::InboxSelection::Direct { id, .. } = inbox::selection(callback(input)?)? else {
		return Err(refuse("direct observation requires a direct callback"));
	};
	let row = record
		.intent
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			workspace::Conversation::Direct(row) if row.id == id => Some(row),
			_ => None,
		})
		.ok_or_else(|| refuse("direct conversation retired"))?;
	row.access
		.map(|key| {
			record
				.custody
				.get(custody::Coordinate {
					role: custody::Role::DirectAccess,
					key: custody::FieldKey::new(key.slot(), key.generation()),
				})
				.map(|field| records::location(&field))
				.ok_or_else(|| refuse("direct route custody absent"))
		})
		.transpose()
}
pub(super) fn requirement(input: Invocation<'_>, root: &Ref) -> Result<Requirement> {
	super::super::retained::authorize(input, root)?;
	inbox::selection(callback(input)?)?;
	Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let mut references = inbox::references(callback(input)?, record)?;
	if let Some(location) = target(input, record)? {
		references.push(ReferenceRequest::RestorePage {
			page: location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid direct route page"))?,
			field: location.field,
		});
	}
	Ok(references)
}
pub(super) fn invoke<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	super::super::retained::authorize(input, &owner.writer.root()?)?;
	inbox::invoke(call, callback(input)?)?;
	let retirement = owner
		.memberships
		.worker_retirement(text(&input.args[3])?)
		.ok_or_else(|| refuse("direct worker retired"))?;
	if let Some(location) = target(input, &records::metadata(input)?)? {
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid direct route page"))?;
		let facet = call.page_reference(page, location.field)?;
		let session = match owner.writer.host.reference_session(&facet)? {
			Some(session) => Some(session.borrowed()),
			None => call.live_dependent_exporter(&facet)?,
		};
		retirement.observe(session)?;
	}
	Ok(Argument::Void)
}
