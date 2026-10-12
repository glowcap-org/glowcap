//! Creation retains its exact bootstrap and every completed acquisition.
//! Durable publications issued by that bootstrap are independent room roles.
use super::*;
use rooms_application::{content::session::results::ManagedRoom, directory::creation};
use std::cell::RefCell;

/// One of at most eight jobs owns two temporary capability retains, one exact
/// bootstrap outcome and two successful Ref slots. Successful outcomes copy
/// only two validated URIs, each bounded by ReferenceRequest::MAX_URI_BYTES.
/// Retry copies those texts into its two-field settlement spine. The executor
/// holds the whole future across deadlines. Terminal bootstrap errors stay
/// cached here. Deleting either cache would repeat issuance or lose completed
/// authority when a later lookup refuses. All custody retires with the job.
pub(super) struct Acquisition {
	// Both temporary capabilities survive the bootstrap observation. They are
	// execution custody, never persisted or disclosed as durable authority.
	room: Ref,
	bootstrap: Ref,
	authorities: RefCell<Option<Result<[String; 2]>>>,
	acquired: RefCell<[Option<Ref>; 2]>,
}
fn row() -> ManagedRoom {
	ManagedRoom {
		room: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
		control: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
fn coordinates(row: &ManagedRoom) -> [Coordinate; 2] {
	[
		Coordinate {
			role: custody::Role::RoomAccess,
			key: FieldKey::new(row.room.slot(), row.room.generation()),
		},
		Coordinate {
			role: custody::Role::RoomControl,
			key: FieldKey::new(row.control.slot(), row.control.generation()),
		},
	]
}
pub(super) fn prepare(value: &Argument) -> Result<super::Acquisition> {
	let args = value
		.as_list()
		.ok_or_else(|| loam::refusal("invalid creation bootstrap"))?;
	let values = rooms_glowcap::values(args).collect::<Vec<_>>();
	let creation::Bootstrap { room, bootstrap } =
		creation::read_bootstrap(&values).map_err(|_| loam::refusal("invalid creation bootstrap"))?;
	Ok(super::Acquisition {
		data: serde_json::to_string(&row()).map_err(|_| loam::refusal("invalid created room data"))?,
		lookup: Lookup::Creation(Acquisition {
			room,
			bootstrap,
			authorities: RefCell::new(None),
			acquired: RefCell::new([None, None]),
		}),
	})
}
fn authorities(value: &Argument) -> Result<[String; 2]> {
	let value = rooms_glowcap::Value(value);
	let uris = creation::authorities(&value).map_err(|_| loam::refusal("invalid bootstrap authorities"))?;
	for uri in uris {
		if uri.len() > ReferenceRequest::MAX_URI_BYTES
			|| glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0)?
				.swissnum
				.is_empty()
		{
			return Err(loam::refusal("invalid bootstrap publication"));
		}
	}
	Ok(uris.map(String::from))
}
impl Acquisition {
	pub(super) async fn acquire(&self, host: &Host) -> Result<Vec<Argument>> {
		let _held = &self.room;
		if self.authorities.borrow().is_none() {
			// The executor retains this entire future across interruption and
			// deadlines. Even a terminal failure remains the exact bootstrap
			// outcome; recovery never requests another issuance observation.
			let result = host
				.send(&self.bootstrap, creation::AUTHORITIES, &[])
				.await
				.and_then(|value| authorities(&value));
			*self.authorities.borrow_mut() = Some(result);
		}
		let uris = self
			.authorities
			.borrow()
			.as_ref()
			.ok_or_else(|| loam::refusal("bootstrap authorities were not observed"))?
			.clone()?;
		let mut fields = Vec::with_capacity(2);
		for (index, coordinate) in coordinates(&row()).into_iter().enumerate() {
			let reference = self.acquired.borrow()[index].clone();
			let reference = match reference {
				Some(reference) => reference,
				None => {
					let reference = host.enliven(&uris[index]).await?;
					self.acquired.borrow_mut()[index] = Some(reference.clone());
					reference
				}
			};
			fields.push(saved_field(coordinate, reference, &uris[index])?);
		}
		Ok(fields)
	}
}
pub(super) fn matches(data: &str, actual: &[Coordinate]) -> Result<bool> {
	let row: ManagedRoom = serde_json::from_str(data).map_err(|_| loam::refusal("invalid created room data"))?;
	Ok(coordinates(&row) == actual)
}
