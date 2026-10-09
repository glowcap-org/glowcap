//! Private selected archive observation discloses no capability or session.
use super::*;
use std::rc::Rc;

pub(super) fn requirement(input: Invocation<'_>, root: &Ref) -> Result<Requirement> {
	super::super::retained::authorize(input, root)?;
	if input.args.len() != 1 {
		return Err(refuse("archive observation takes the private owner"));
	}
	Requirement::new(&[Permission::ReadArchive.key()], &[])
}
fn selected(record: &MetadataRecord) -> Result<Option<records::Location>> {
	record
		.intent
		.archive
		.map(|key| {
			record
				.custody
				.get(custody::Coordinate {
					role: custody::Role::ArchiveAccess,
					key: custody::FieldKey::new(key.slot(), key.generation()),
				})
				.map(|field| records::location(&field))
				.ok_or_else(|| refuse("selected archive custody absent"))
		})
		.transpose()
}
pub(super) fn references(record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	selected(record)?
		.map(|location| {
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid archive page"))?,
				field: location.field,
			})
		})
		.transpose()
		.map(|request| request.into_iter().collect())
}
pub(super) fn invoke<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	requirement(input, &owner.writer.root()?)?;
	if call.source()? != owner.writer.root()? {
		return Err(refuse("private session root required"));
	}
	let record = records::metadata(input)?;
	let session = match selected(&record)? {
		Some(location) => {
			let page = input
				.graph
				.and_then(|pages| pages.get(location.page.checked_sub(1)?))
				.ok_or_else(|| refuse("invalid archive page"))?;
			let facet = call.page_reference(page, location.field)?;
			match owner.writer.host.reference_session(&facet)? {
				Some(session) => Some(session.borrowed()),
				None => call.live_dependent_exporter(&facet)?,
			}
		}
		None => None,
	};
	owner
		.recording
		.borrow()
		.as_ref()
		.ok_or_else(|| refuse("archive supervisor is absent"))?
		.observe_archive(record.intent.archive, session);
	Ok(Argument::Void)
}
