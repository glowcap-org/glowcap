//! The runtime projects typed held fields into the application's record codec.
use glowcap::{
	Ref, Result,
	loam::{self, BoundResource, Call, GraphField, GraphPage, Invocation, PageSchema},
};
use rooms_application::content::session::{custody, records, workspace};
use rooms_application::failure::FailureCode;

pub struct References;
pub struct Metadata;
/// Candidates distinguish newly held authority from an unchanged committed
/// occurrence. Only dispatch restores retained authority. Staging copies edges.
#[derive(Clone, PartialEq, Eq)]
pub enum Field {
	Held(Ref),
	Retained(Location),
}
impl Field {
	fn graph<'a>(&self, input: Invocation<'a>) -> Result<GraphField<'a>> {
		Ok(match self {
			Self::Held(reference) => GraphField::Held(reference.clone()),
			Self::Retained(location) => GraphField::Retained {
				page: input
					.graph
					.and_then(|pages| pages.get(location.page.checked_sub(1)?))
					.ok_or_else(|| loam::refusal("invalid retained field page"))?,
				index: location.field,
			},
		})
	}
	pub fn resolve(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Ref> {
		match self.graph(input)? {
			GraphField::Held(reference) => Ok(reference),
			GraphField::Retained { page, index } => call.page_reference(page, index),
		}
	}
}
/// A descriptive occurrence inside this prepared graph, never held authority.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Location {
	pub page: usize,
	pub field: usize,
}
macro_rules! roles {
	($($role:ident),*) => {
		impl custody::References for References { $(type $role = Field;)* }
		impl custody::References for Metadata { $(type $role = Location;)* }
		fn located(coordinate: custody::Coordinate, location: Location) -> custody::RetainedField<Metadata> {
			match coordinate.role { $(custody::Role::$role => custody::RetainedField::$role(custody::Held {
				key: coordinate.key.retag(), reference: location,
			}),)* }
		}
		pub fn reference<'a>(field: &custody::Retained<'a, References>) -> &'a Field {
			match field { $(custody::Retained::$role(held) => &held.reference,)* }
		}
		pub fn location(field: &custody::Retained<'_, Metadata>) -> Location {
			match field { $(custody::Retained::$role(held) => held.reference,)* }
		}
		pub fn restored(coordinate: custody::Coordinate, reference: Field) -> custody::RetainedField<References> {
			match coordinate.role { $(custody::Role::$role => custody::RetainedField::$role(custody::Held {
				key: coordinate.key.retag(), reference,
			}),)* }
		}
	};
}
roles!(
	SessionAccess,
	SessionControl,
	RoomAccess,
	DirectoryAccess,
	DirectAccess,
	DirectInbox,
	ArchiveAccess,
	Operator,
	Operations,
	IrcConnection,
	Offer,
	AcceptedAccess,
	RoomControl,
	ArchiveControl,
	CreationReceipt,
	PublicationLease,
	RoomSeat,
	RoomSubject,
	RoomInbox,
	RoomFiles,
	Line,
	DirectoryName,
	DirectoryInbox,
	SourceBlob
);

pub type Record = workspace::Record<References, BoundResource>;

/// Decode candidate locations without acquiring upstream capabilities. The
/// prepared graph owns exact committed edge custody until atomic replacement.
pub fn decode(input: Invocation<'_>) -> Result<Record> {
	decode_with(input, unreadable, |page, coordinate, field| {
		Ok(restored(coordinate, Field::Retained(Location { page, field })))
	})
}
/// Decode and validate bounded payloads without restoring capability fields.
/// Only selected occurrences are subsequently requested from shared hosting.
/// The walk covers at most MAX_PAGES and MAX_AUTHORITY_BYTES. Rust owns the
/// decoded intent and field-location spines through this callback. Loam owns
/// prepared page bytes. Neither decode nor its locations grant invocation.
pub fn metadata(input: Invocation<'_>) -> Result<workspace::Record<Metadata, BoundResource>> {
	decode_with(input, unreadable, |page, coordinate, field| {
		Ok(located(coordinate, Location { page, field }))
	})
}
/// Decode the saved graph as the session opens. Only here is a body the
/// codec cannot parse refused as saved data in another stored form, because
/// only an open reads data an earlier version may have written. The open
/// that reaches this has already called `start_live` (`opening.rs`), which
/// proposes a new lifetime marker to the store's write lane, and the private
/// call carrying this decode drives that lane. A refused open can therefore
/// leave the new marker committed in place of the prior one. The marker
/// carries no capability, and nothing of the session's records changes.
pub fn opened(input: Invocation<'_>) -> Result<()> {
	decode_with(input, unreadable_at_open, |page, coordinate, field| {
		Ok(located(coordinate, Location { page, field }))
	})
	.map(drop)
}
fn decode_with<R: custody::References>(
	input: Invocation<'_>,
	refused: fn(records::Error) -> glowcap::Error,
	restore: impl FnMut(
		usize,
		custody::Coordinate,
		usize,
	) -> core::result::Result<custody::RetainedField<R>, records::Error>,
) -> Result<workspace::Record<R, BoundResource>> {
	let pages = input
		.graph
		.ok_or_else(|| loam::refusal("session graph is not prepared"))?;
	let graph: Vec<_> = core::iter::once(records::GraphPage {
		schema: records::WORKSPACE.id,
		version: records::WORKSPACE.version,
		payload: input.payload,
		field_count: input.field_count,
	})
	.chain(pages.iter().map(|page| records::GraphPage {
		schema: page.schema().id,
		version: page.schema().version,
		payload: page.payload(),
		field_count: page.field_count(),
	}))
	.collect();
	records::decode_graph(
		custody::ResourceBinding {
			resource: input.bound_resource,
		},
		&graph,
		restore,
	)
	.map_err(refused)
}
/// A saved graph the codec refused as the session opens, as the refusal the
/// session answers with. Loam checked each record's checksum before the codec
/// read it, so a body the codec cannot parse was written whole in another
/// stored form.
fn unreadable_at_open(error: records::Error) -> glowcap::Error {
	match error {
		records::Error::Json(_) => loam::refusal(FailureCode::SessionStateUnreadable.line(OTHER_FORM)),
		error => unreadable(error),
	}
}
/// A saved graph the codec refused once the session is open. The open read
/// every body, so one that does not parse now was written by this run, and
/// the refusal says so without naming another stored form.
fn unreadable(error: records::Error) -> glowcap::Error {
	match error {
		records::Error::Json(_) => loam::refusal("a saved record this session wrote does not decode"),
		records::Error::Capacity | records::Error::Format | records::Error::Fields => {
			loam::refusal("invalid session graph")
		}
	}
}
/// The detail of a saved record in a stored form this codec does not read.
pub const OTHER_FORM: &str = "a saved record is in another stored form";

/// The codec owns page ordering and the intent fence, which advances only when
/// this write changes the intent. These temporary spines borrow its payloads
/// through one shared staging call. Only Loam's candidate survives the callback.
pub fn replace(call: &mut Call<'_>, input: Invocation<'_>, record: &mut Record) -> Result<()> {
	rooms_application::content::session::bridge::retire(record);
	rooms_application::content::session::outgoing::retire(record);
	let stored: Vec<_> = core::iter::once(input.payload)
		.chain(
			input
				.graph
				.ok_or_else(|| loam::refusal("session graph is not prepared"))?
				.iter()
				.take_while(|page| page.schema().id == records::WORKSPACE.id)
				.map(|page| page.payload()),
		)
		.collect();
	let encoded = records::encode_replacement(record, &stored, input.content_revision)
		.map_err(|_| loam::refusal("session record exceeds its profile"))?;
	let pages: Vec<_> = encoded
		.workspace
		.iter()
		.skip(1)
		.map(|payload| Ok((records::WORKSPACE, payload.as_slice(), Vec::new())))
		.chain(encoded.custody.iter().map(|page| {
			Ok((
				records::CUSTODY,
				page.payload.as_slice(),
				page.fields
					.iter()
					.map(|field| reference(field).graph(input))
					.collect::<Result<_>>()?,
			))
		}))
		.chain(
			encoded
				.provenance
				.iter()
				.map(|payload| Ok((records::PROVENANCE, payload.as_slice(), Vec::new()))),
		)
		.chain(encoded.effects.iter().flatten().map(|page| {
			Ok((
				records::EFFECT,
				page.payload.as_slice(),
				page.fields
					.iter()
					.map(|field| reference(field).graph(input))
					.collect::<Result<_>>()?,
			))
		}))
		.collect::<Result<_>>()?;
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
	call.replace_graph(&encoded.workspace[0], &candidate)
}

/// Receipt changes preserve every workspace and custody page. Re-encode only
/// the bounded receipt window. Shared staging keeps the untouched physical rows.
pub fn replace_effects(call: &mut Call<'_>, input: Invocation<'_>, record: &Record) -> Result<()> {
	let pages = input
		.graph
		.ok_or_else(|| loam::refusal("session graph is not prepared"))?;
	let kept: Vec<_> = pages
		.iter()
		.take_while(|page| page.schema().id != records::EFFECT.id)
		.collect();
	let effects: Vec<_> = record
		.effects
		.as_slice()
		.iter()
		.map(records::encode_effect)
		.collect::<core::result::Result<_, _>>()
		.map_err(|_| loam::refusal("effect receipt exceeds its profile"))?;
	let sequence_page = kept
		.iter()
		.position(|page| page.schema().id == records::CUSTODY.id)
		.ok_or_else(|| loam::refusal("custody sequence page is absent"))?;
	let sequence = records::advance_identity_sequence(kept[sequence_page].payload(), record.custody.next_identity())
		.map_err(|_| loam::refusal("invalid custody line sequence"))?;
	let sequence_fields: Vec<_> = if sequence.is_some() {
		(0..kept[sequence_page].field_count())
			.map(|index| GraphField::Retained {
				page: kept[sequence_page],
				index,
			})
			.collect()
	} else {
		Vec::new()
	};
	let payloads = || {
		core::iter::once(input.payload)
			.chain(kept.iter().enumerate().map(|(at, page)| {
				if at == sequence_page {
					sequence.as_deref().unwrap_or_else(|| page.payload())
				} else {
					page.payload()
				}
			}))
			.chain(effects.iter().flatten().map(|page| page.payload.as_slice()))
	};
	records::check_budget(payloads()).map_err(|_| loam::refusal("session record exceeds its profile"))?;
	records::check_reservations(record, payloads())
		.map_err(|_| loam::refusal("outgoing settlement exceeds available session capacity"))?;
	let fields: Vec<Vec<GraphField<'_>>> = effects
		.iter()
		.flatten()
		.map(|page| {
			page.fields
				.iter()
				.map(|field| reference(field).graph(input))
				.collect::<Result<_>>()
		})
		.collect::<Result<_>>()?;
	let candidate: Vec<_> = kept
		.iter()
		.copied()
		.enumerate()
		.map(|(at, page)| match sequence.as_deref() {
			Some(payload) if at == sequence_page => GraphPage::Write {
				schema: page.schema(),
				payload,
				fields: &sequence_fields,
			},
			_ => GraphPage::Keep(page),
		})
		.chain(
			effects
				.iter()
				.flatten()
				.zip(&fields)
				.map(|(page, fields)| GraphPage::Write {
					schema: PageSchema {
						id: records::EFFECT.id,
						version: records::EFFECT.version,
					},
					payload: &page.payload,
					fields,
				}),
		)
		.collect();
	call.replace_graph(input.payload, &candidate)
}

/// Rewrite the selected receipt with its retained original source and targets
/// and newly held result fields. Unrelated receipt and workspace pages stay put.
pub fn settle_effect(
	call: &mut Call<'_>,
	input: Invocation<'_>,
	record: &Record,
	receipt: &custody::EffectReceipt<References>,
) -> Result<()> {
	let pages = input
		.graph
		.ok_or_else(|| loam::refusal("session graph is not prepared"))?;
	let start_of = |receipt: &custody::EffectReceipt<References>| -> Result<usize> {
		let Field::Retained(location) = receipt.source.reference else {
			return Err(loam::refusal("settlement requires a saved source"));
		};
		location
			.page
			.checked_sub(1)
			.ok_or_else(|| loam::refusal("invalid receipt page"))
	};
	let start = start_of(receipt)?;
	let mut end = pages.len();
	for other in record.effects.as_slice() {
		let page = start_of(other)?;
		if page > start {
			end = page;
			break;
		}
	}
	let encoded = records::encode_effect(receipt).map_err(|_| loam::refusal("effect receipt exceeds its profile"))?;
	let fields: Vec<Vec<_>> = encoded
		.iter()
		.map(|page| {
			page.fields
				.iter()
				.map(|field| reference(field).graph(input))
				.collect::<Result<_>>()
		})
		.collect::<Result<_>>()?;
	let candidate: Vec<_> = pages
		.iter()
		.take(start)
		.map(GraphPage::Keep)
		.chain(encoded.iter().zip(&fields).map(|(page, fields)| GraphPage::Write {
			schema: PageSchema {
				id: records::EFFECT.id,
				version: records::EFFECT.version,
			},
			payload: &page.payload,
			fields,
		}))
		.chain(pages.iter().skip(end).map(GraphPage::Keep))
		.collect();
	call.replace_graph(input.payload, &candidate)
}

#[cfg(test)]
mod tests {
	use super::{OTHER_FORM, records, unreadable, unreadable_at_open};
	use rooms_application::failure::{Failure, FailureCode};

	/// Only a body in another form, read as the session opens, names the
	/// code. A graph whose pages parse but do not fit together is a different
	/// cause, and so is a body that does not parse once the session is open.
	#[test]
	fn only_a_body_in_another_form_is_refused_as_unreadable_saved_data() {
		let other_form = || records::Error::Json(serde_json::from_str::<u8>("{}").unwrap_err());
		assert_eq!(
			unreadable_at_open(other_form()).message(),
			Some(FailureCode::SessionStateUnreadable.line(OTHER_FORM).as_str())
		);
		let refused = unreadable(other_form());
		assert_eq!(Failure::parse(refused.message().unwrap()), None, "{refused}");
		let others: [fn() -> records::Error; 3] = [
			|| records::Error::Capacity,
			|| records::Error::Format,
			|| records::Error::Fields,
		];
		for error in others {
			for refused in [unreadable(error()), unreadable_at_open(error())] {
				assert_eq!(Failure::parse(refused.message().unwrap()), None, "{refused}");
			}
		}
	}
}
