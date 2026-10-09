//! Consumer adapter over the application codec's graph order and field roles.
use glowcap::{
	Ref, Result,
	loam::{Call, GraphField, GraphPage, Invocation, PageSchema},
};
use rooms_application::content::session::{custody, records};

pub(crate) fn replace<R: custody::References>(
	call: &mut Call<'_>,
	encoded: &records::Encoded<'_, R, ()>,
	reference: impl Fn(&custody::Retained<'_, R>) -> Ref,
) -> Result<usize> {
	let pages: Vec<_> = encoded
		.workspace
		.iter()
		.skip(1)
		.map(|payload| (records::WORKSPACE, payload.as_slice(), Vec::new()))
		.chain(encoded.custody.iter().map(|page| {
			(
				records::CUSTODY,
				page.payload.as_slice(),
				page.fields
					.iter()
					.map(|field| GraphField::Held(reference(field)))
					.collect(),
			)
		}))
		.chain(encoded.effects.iter().flatten().map(|page| {
			(
				records::EFFECT,
				page.payload.as_slice(),
				page.fields
					.iter()
					.map(|field| GraphField::Held(reference(field)))
					.collect(),
			)
		}))
		.collect();
	let candidate: Vec<_> = pages
		.iter()
		.map(|(schema, payload, fields)| GraphPage::Write {
			schema: PageSchema {
				id: schema.id,
				version: schema.version,
			},
			payload,
			fields,
		})
		.collect();
	call.replace_graph(&encoded.workspace[0], &candidate)?;
	Ok(candidate.len())
}

/// Rebuild page records from exact prepared fields without restoring targets.
/// The same callback is exercised while the foreign exporter is disconnected.
pub(crate) fn retain(call: &mut Call<'_>, input: Invocation<'_>) -> Result<()> {
	let pages = input.graph.expect("prepared graph");
	let fields: Vec<Vec<_>> = pages
		.iter()
		.map(|page| {
			(0..page.field_count())
				.map(|index| GraphField::Retained { page, index })
				.collect()
		})
		.collect();
	let candidate: Vec<_> = pages
		.iter()
		.zip(&fields)
		.map(|(page, fields)| GraphPage::Write {
			schema: page.schema(),
			payload: page.payload(),
			fields,
		})
		.collect();
	call.replace_graph(input.payload, &candidate)
}
