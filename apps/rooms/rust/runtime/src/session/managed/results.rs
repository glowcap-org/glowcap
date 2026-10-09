//! Result acquisition retains the exact returned recipe until it can be saved.
//! Bearer text is transient execution state, never receipt or workspace data.
mod creation;
mod direct;
mod invitation;
mod manager;
mod membership;
mod moderator;
mod operations;
mod publication;
mod reason;
mod registration;
use super::records::{self, Field, References};
use glowcap::{
	Argument, Host, Ref, Result,
	loam::{self, Call, Invocation, ReferenceRequest},
};
use rooms_application::{
	content::session::{
		custody::{self, Coordinate, FieldKey, Outcome},
		results::{PostedLine, RoomLink, RoomPolicyUpdate, Stewardship},
	},
	fields::{List, Nullable, Text},
	room::authority,
	server::operations::operator::view,
	session::effect::Reply,
};
use std::num::NonZeroU64;

pub(super) enum Prepared {
	Complete(Settlement),
	Capability(Acquisition),
}
/// The bounded job owns typed data and transient publication acquisition.
/// Room-link, moderator and stewardship replies hold one URI; creation retains both
/// bootstrap roles. Only these replies allocate an acquisition Rc and future.
/// Plain acknowledgments go directly to settlement.
pub(super) struct Acquisition {
	data: String,
	lookup: Lookup,
}
enum Lookup {
	Publication {
		coordinate: Coordinate,
		uri: String,
	},
	Manager {
		coordinate: Coordinate,
		uri: String,
		identity: String,
	},
	Creation(creation::Acquisition),
}
pub(super) struct Settlement(pub Argument);
impl Settlement {
	/// One bounded diagnostic string survives observation and settlement retry.
	/// Formatting stops at 4096 UTF-16 units; ordinary String growth retains at
	/// most twice the 12 KiB UTF-8 bound, even if the peer's failure was larger.
	/// The original receipt owns it through cold restoration; it grants no replay.
	pub(super) fn unknown(error: &glowcap::Error) -> Self {
		Self(Argument::List(vec!["unknown".into(), reason::format(error).into()]))
	}
	pub(super) fn retirement_target(&self, reply: Reply) -> Result<Option<Ref>> {
		let role = match reply {
			Reply::Membership => custody::Role::RoomSeat,
			Reply::DirectoryRegistration => custody::Role::DirectoryName,
			_ => return Ok(None),
		};
		let Some((_, fields)) = parts(&self.0)? else {
			return Ok(None);
		};
		for value in fields {
			let (coordinate, reference, _) = field(value)?;
			if coordinate.role == role {
				return Ok(Some(reference));
			}
		}
		Err(loam::refusal("membership result has no retirement target"))
	}
	fn data(data: String) -> Self {
		Self(Argument::List(vec![data.into(), Argument::List(Vec::new())]))
	}
	pub fn absent() -> Self {
		Self(Argument::Void)
	}
}
impl Prepared {
	pub fn negative(reply: Reply, error: &glowcap::Error) -> Option<Settlement> {
		if matches!(reply, Reply::DirectAccess) {
			direct::pending(error)
		} else {
			None
		}
	}
	pub fn read(reply: Reply, value: &Argument, intent: &str) -> Result<Self> {
		match (reply, value) {
			(Reply::RoomManager, value) => manager::read(value, intent).map(Self::Capability),
			(Reply::RoomModerator, value) => moderator::read(value).map(Self::Capability),
			(Reply::DirectoryRegistration, value) => registration::read(value, intent).map(Self::Complete),
			(Reply::DirectAccess, value) => direct::read(value).map(Self::Complete),
			(Reply::IrcConnection, value) => operations::connection(value).map(Self::Complete),
			(Reply::Text | Reply::Listener | Reply::RetireBatch, value) => {
				operations::read(reply, value).map(Self::Complete)
			}
			(Reply::AcceptedAccess, value) => invitation::read(value).map(Self::Complete),
			(Reply::PublicationLease, value) => publication::read(value).map(Self::Complete),
			(Reply::ManagedRoom, value) => creation::prepare(value).map(Self::Capability),
			(Reply::Membership, value) => membership::read(value).map(Self::Complete),
			(Reply::Line, value) => {
				let (reference, id) = rooms_glowcap::client::posted_line::reply(value)?;
				let reference = reference.cloned();
				let key = FieldKey::new(
					NonZeroU64::new(1).expect("result slot"),
					NonZeroU64::new(1).expect("result generation"),
				);
				let data = serde_json::to_string(&PostedLine {
					line: reference.as_ref().map(|_| key),
					id: id.map(|id| {
						rooms_application::fields::SafeInteger::new(id.get()).expect("bounded line identity")
					}),
					history: None,
				})
				.map_err(|_| loam::refusal("invalid posted line data"))?;
				let fields = reference
					.map(|reference| {
						Ok::<_, glowcap::Error>(Argument::List(vec![
							serde_json::to_string(&Coordinate {
								role: custody::Role::Line,
								key: FieldKey::new(key.slot(), key.generation()),
							})
							.map_err(|_| loam::refusal("invalid line coordinate"))?
							.into(),
							Argument::Reference(reference),
							Argument::List(vec!["live".into()]),
						]))
					})
					.transpose()?
					.into_iter()
					.collect();
				Ok(Self::Complete(Settlement(Argument::List(vec![
					data.into(),
					Argument::List(fields),
				]))))
			}
			(Reply::Acknowledgment, Argument::Void) => Ok(Self::Complete(Settlement::data("null".into()))),
			(Reply::Boolean, Argument::Boolean(value)) => Ok(Self::Complete(Settlement::data(value.to_string()))),
			(Reply::RoomLink, value) => {
				let value = rooms_glowcap::Value(value);
				let uri = authority::room_link(&value).map_err(|_| loam::refusal("invalid room link result"))?;
				let key = FieldKey::new(
					NonZeroU64::new(1).expect("result slot"),
					NonZeroU64::new(1).expect("result generation"),
				);
				let data = serde_json::to_string(&RoomLink { room: key })
					.map_err(|_| loam::refusal("invalid room link data"))?;
				Ok(Self::Capability(Acquisition {
					data,
					lookup: Lookup::Publication {
						coordinate: Coordinate {
							role: custody::Role::RoomAccess,
							key: FieldKey::new(key.slot(), key.generation()),
						},
						uri: uri.into(),
					},
				}))
			}
			(Reply::RoomPolicy, value) => {
				let value = rooms_glowcap::Value(value);
				let update =
					authority::policy_update(&value).map_err(|_| loam::refusal("invalid room policy result"))?;
				let name = Text::new(update.name.into()).ok_or_else(|| loam::refusal("invalid room name"))?;
				let data = serde_json::to_string(&RoomPolicyUpdate {
					name,
					policy: update.policy,
				})
				.map_err(|_| loam::refusal("invalid room policy data"))?;
				Ok(Self::Complete(Settlement::data(data)))
			}
			(Reply::Stewardship, value) => {
				let row = view::read_stewardship(&rooms_glowcap::Value(value))
					.map_err(|_| loam::refusal("invalid stewardship result"))?;
				let key = FieldKey::new(
					NonZeroU64::new(1).expect("result slot"),
					NonZeroU64::new(1).expect("result generation"),
				);
				let returned = match row.steward {
					Nullable::Null => None,
					Nullable::Value(uri) => Some((
						Coordinate {
							role: custody::Role::RoomAccess,
							key,
						},
						uri.text()
							.as_str()
							.ok_or_else(|| loam::refusal("invalid result URI"))?
							.into(),
					)),
				};
				let data = serde_json::to_string(&Stewardship {
					name: row.name,
					label: row.label,
					visibility: row.visibility,
					generation: row.generation,
					steward: returned.as_ref().map(|_| FieldKey::new(key.slot(), key.generation())),
				})
				.map_err(|_| loam::refusal("invalid stewardship data"))?;
				if !Text::<32768>::accepts_utf16(data.encode_utf16()) {
					return Err(loam::refusal("effect result exceeds receipt capacity"));
				}
				Ok(match returned {
					Some((coordinate, uri)) => Self::Capability(Acquisition {
						data,
						lookup: Lookup::Publication { coordinate, uri },
					}),
					None => Self::Complete(Settlement::data(data)),
				})
			}
			_ => Err(loam::refusal("invalid effect result")),
		}
	}
}
impl Acquisition {
	pub async fn acquire(&self, host: &Host) -> Result<Settlement> {
		let fields = match &self.lookup {
			Lookup::Manager {
				coordinate,
				uri,
				identity,
			} => {
				let reference = host.enliven(uri).await?;
				let governed = host.send(&reference, authority::GOVERNS, &[]).await?;
				authority::verify_manager(
					&rooms_glowcap::Value(&governed),
					&rooms_glowcap::Value(&identity.as_str().into()),
				)
				.map_err(|_| loam::refusal("operator returned a manager for a different room"))?;
				vec![saved_field(*coordinate, reference, uri)?]
			}
			Lookup::Creation(creation) => creation.acquire(host).await?,
			Lookup::Publication { coordinate, uri } => vec![saved_field(*coordinate, host.enliven(uri).await?, uri)?],
		};
		Ok(Settlement(Argument::List(vec![
			self.data.clone().into(),
			Argument::List(fields),
		])))
	}
}
fn saved_field(coordinate: Coordinate, reference: Ref, uri: &str) -> Result<Argument> {
	Ok(Argument::List(vec![
		serde_json::to_string(&coordinate)
			.map_err(|_| loam::refusal("invalid result coordinate"))?
			.into(),
		Argument::Reference(reference),
		uri.into(),
	]))
}

fn parts(value: &Argument) -> Result<Option<(&str, &[Argument])>> {
	if failure_reason(value)?.is_some() {
		return Ok(None);
	}
	if matches!(value, Argument::Void) {
		return Ok(None);
	}
	let Some([data, fields]) = value.as_list() else {
		return Err(loam::refusal("invalid private result"));
	};
	let data = data
		.as_str()
		.filter(|s| Text::<32768>::accepts_utf16(s.encode_utf16()))
		.ok_or_else(|| loam::refusal("invalid result data"))?;
	let fields = fields
		.as_list()
		.filter(|fields| fields.len() <= custody::MAX_RESULT_FIELDS)
		.ok_or_else(|| loam::refusal("invalid result fields"))?;
	Ok(Some((data, fields)))
}
enum Recipe {
	Durable(Option<String>),
	Live,
}
fn field(value: &Argument) -> Result<(Coordinate, Ref, Recipe)> {
	let Some([coordinate, reference, uri]) = value.as_list() else {
		return Err(loam::refusal("invalid result field"));
	};
	let coordinate = Coordinate::decode(
		coordinate
			.as_str()
			.ok_or_else(|| loam::refusal("result coordinate required"))?,
	)
	.map_err(|_| loam::refusal("invalid result coordinate"))?;
	let reference = Ref::try_from(reference).map_err(|_| loam::refusal("result capability required"))?;
	let uri = match uri {
		Argument::Void => Recipe::Durable(None),
		Argument::String(uri) => Recipe::Durable(Some(uri.clone())),
		Argument::List(tag) if matches!(tag.as_slice(), [tag] if tag.as_str() == Some("live")) => Recipe::Live,
		_ => return Err(loam::refusal("invalid result recipe")),
	};
	if coordinate.role.live() != matches!(uri, Recipe::Live) {
		return Err(loam::refusal("result lifetime does not match its typed role"));
	}
	Ok((coordinate, reference, uri))
}
pub(super) fn saves(value: &Argument, source: &Ref, committed: bool) -> Result<Vec<ReferenceRequest>> {
	let Some((_, fields)) = parts(value)? else {
		return Ok(Vec::new());
	};
	let mut requests = Vec::with_capacity(fields.len());
	for value in fields {
		let (_, reference, recipe) = field(value)?;
		match recipe {
			Recipe::Durable(uri) => requests.push(ReferenceRequest::Save { reference, uri }),
			Recipe::Live if committed => {}
			Recipe::Live => requests.push(ReferenceRequest::SaveLiveDependent {
				source: source.clone(),
				target: reference,
			}),
		}
	}
	Ok(requests)
}
pub(super) fn outcome(
	value: &Argument,
	reply: Reply,
	source: &Ref,
	existing: &Outcome<References>,
	call: &mut Call<'_>,
) -> Result<Outcome<References>> {
	if let Some(reason) = failure_reason(value)? {
		return Ok(Outcome::Unknown {
			reason: Text::new(reason.into()).expect("bounded diagnostic"),
		});
	}
	let Some((data, fields)) = parts(value)? else {
		return Ok(Outcome::KnownAbsent);
	};
	let retained = fields
		.iter()
		.map(|value| {
			let (coordinate, mut reference, recipe) = field(value)?;
			if matches!(recipe, Recipe::Live) {
				reference = if let Outcome::Committed { retained, .. } = existing {
					let saved = retained
						.as_slice()
						.iter()
						.find(|held| held.borrowed().coordinate() == coordinate)
						.ok_or_else(|| loam::refusal("live result coordinate differs"))?;
					let Field::Held(facet) = records::reference(&saved.borrowed()) else {
						return Err(loam::refusal("live result was not restored"));
					};
					if !call.matches_live_dependent(facet, source, &reference)? {
						return Err(loam::refusal("live result authority differs"));
					}
					facet.clone()
				} else {
					call.prepared_live_dependent(source, &reference)?
				};
			}
			Ok(records::restored(coordinate, Field::Held(reference)))
		})
		.collect::<Result<Vec<_>>>()?;
	let coordinates: Vec<_> = retained.iter().map(|field| field.borrowed().coordinate()).collect();
	let valid = match reply {
		Reply::Upload => super::uploads::matches(data, &coordinates)?,
		Reply::DirectoryRegistration => registration::matches(data, &coordinates)?,
		Reply::DirectAccess => direct::matches(data, &coordinates)?,
		Reply::IrcConnection => operations::matches_connection(data, &coordinates)?,
		Reply::Text | Reply::Listener | Reply::RetireBatch => operations::matches(reply, data, &coordinates)?,
		Reply::AcceptedAccess => invitation::matches(data, &coordinates)?,
		Reply::PublicationLease => publication::matches(data, &coordinates)?,
		Reply::ManagedRoom => creation::matches(data, &coordinates)?,
		Reply::Membership => membership::matches(data, &coordinates)?,
		Reply::Line => {
			let row: PostedLine = serde_json::from_str(data).map_err(|_| loam::refusal("invalid posted line data"))?;
			match (row.line, coordinates.as_slice()) {
				(None, []) => true,
				(Some(key), [coordinate]) => {
					coordinate.role == custody::Role::Line
						&& coordinate.key.slot() == key.slot()
						&& coordinate.key.generation() == key.generation()
				}
				_ => false,
			}
		}
		Reply::Acknowledgment => data == "null" && coordinates.is_empty(),
		Reply::Boolean => matches!(data, "true" | "false") && coordinates.is_empty(),
		Reply::RoomPolicy => serde_json::from_str::<RoomPolicyUpdate>(data).is_ok() && coordinates.is_empty(),
		Reply::RoomLink => {
			let row: RoomLink = serde_json::from_str(data).map_err(|_| loam::refusal("invalid room link data"))?;
			matches!(coordinates.as_slice(), [coordinate] if coordinate.role == custody::Role::RoomAccess
				&& coordinate.key.slot() == row.room.slot()
				&& coordinate.key.generation() == row.room.generation())
		}
		Reply::RoomManager => manager::matches(data, &coordinates)?,
		Reply::RoomModerator => moderator::matches(data, &coordinates)?,
		Reply::Stewardship => {
			let row: Stewardship = serde_json::from_str(data).map_err(|_| loam::refusal("invalid stewardship data"))?;
			match (row.steward, coordinates.as_slice()) {
				(None, []) => true,
				(Some(key), [coordinate]) => {
					coordinate.role == custody::Role::RoomAccess
						&& coordinate.key.slot() == key.slot()
						&& coordinate.key.generation() == key.generation()
				}
				_ => false,
			}
		}
	};
	if !valid {
		return Err(loam::refusal("result data does not match retained fields"));
	}
	Ok(Outcome::Committed {
		result: Text::new(data.into()).expect("checked result text"),
		retained: List::new(retained).expect("checked result fields"),
	})
}
/// A failed observation owns no returned capability fields.
fn failure_reason(value: &Argument) -> Result<Option<&str>> {
	let Some([Argument::String(status), Argument::String(reason)]) = value.as_list() else {
		return Ok(None);
	};
	if status != "unknown"
		|| !Text::<{ custody::MAX_OBSERVATION_REASON_UNITS }, true>::accepts_utf16(reason.encode_utf16())
	{
		return Err(loam::refusal("invalid terminal observation reason"));
	}
	Ok(Some(reason))
}
pub(super) fn result_requests(outcome: &Outcome<records::Metadata>) -> Result<Vec<ReferenceRequest>> {
	let Outcome::Committed { retained, .. } = outcome else {
		return Ok(Vec::new());
	};
	retained
		.as_slice()
		.iter()
		.map(|held| {
			let location = records::location(&held.borrowed());
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| loam::refusal("invalid result page"))?,
				field: location.field,
			})
		})
		.collect()
}
/// Compare actual saved authority on semantic retry. A descriptive field
/// location is never considered equal to an unverified incoming capability.
pub(super) fn restore(outcome: &mut Outcome<References>, call: &mut Call<'_>, input: Invocation<'_>) -> Result<()> {
	if let Outcome::Committed { retained, .. } = outcome {
		let fields = retained
			.as_slice()
			.iter()
			.map(|field| {
				let held = field.borrowed();
				Ok(records::restored(
					held.coordinate(),
					Field::Held(records::reference(&held).resolve(call, input)?),
				))
			})
			.collect::<Result<Vec<_>>>()?;
		*retained = List::new(fields).expect("existing bounded result fields");
	}
	Ok(())
}
pub(super) fn disclose(
	outcome: &Outcome<records::Metadata>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Option<Argument>> {
	if let Outcome::Unknown { reason } = outcome {
		return Ok(Some(Argument::List(vec![
			"unknown".into(),
			reason
				.text()
				.as_str()
				.ok_or_else(|| loam::refusal("invalid failure text"))?
				.into(),
		])));
	}
	let Outcome::Committed { result, retained } = outcome else {
		return Ok(None);
	};
	let data = Argument::String(
		result
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("invalid result text"))?
			.into(),
	);
	if retained.as_slice().is_empty() {
		return Ok(Some(data));
	}
	let fields = retained
		.as_slice()
		.iter()
		// Entrances and operations connections stay private. A client imports
		// the coordinate and invokes it through a new admitted command receipt.
		.filter(|field| {
			!matches!(
				field.borrowed().coordinate().role,
				custody::Role::AcceptedAccess
					| custody::Role::IrcConnection
					| custody::Role::DirectAccess
					| custody::Role::DirectoryName
			)
		})
		.map(|field| {
			let held = field.borrowed();
			let location = records::location(&held);
			let page = input
				.graph
				.and_then(|pages| pages.get(location.page.checked_sub(1)?))
				.ok_or_else(|| loam::refusal("invalid result page"))?;
			Ok(Argument::List(vec![
				serde_json::to_string(&held.coordinate())
					.map_err(|_| loam::refusal("invalid result coordinate"))?
					.into(),
				call.disclose_page(page, location.field, false)?,
			]))
		})
		.collect::<Result<Vec<_>>>()?;
	Ok(Some(Argument::List(vec![data, Argument::List(fields)])))
}
