//! Exact seat, archive and blob readers retain session and upstream admission.
use super::{MetadataRecord, records, refuse, text};
mod operations;
mod rooms;
use glowcap::{
	Argument, Ref, Result,
	loam::{Call, Delivery, Invocation, ReadInterface, ReadMethod, ReferenceRequest, Requirement},
};
use rooms_application::{
	archive::{blobs::admission, protocol},
	content::{
		permissions::Permission,
		session::{self, custody},
	},
};

struct Request {
	coordinate: custody::Coordinate,
	files: bool,
}
fn request(args: &[Argument]) -> Result<Request> {
	let [coordinate, Argument::Boolean(files)] = args else {
		return Err(refuse(
			"archive-reader takes an exact archive coordinate and file permission choice",
		));
	};
	let coordinate =
		custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid archive coordinate"))?;
	if coordinate.role != custody::Role::ArchiveAccess {
		return Err(refuse("archive-reader requires ArchiveAccess custody"));
	}
	Ok(Request {
		coordinate,
		files: *files,
	})
}
pub(super) fn history_source(args: &[Argument]) -> Result<(bool, bool)> {
	match args {
		[source, Argument::Boolean(files)] if source.as_str() == Some("device") => Ok((true, *files)),
		[source, Argument::Boolean(files)] if source.as_str() == Some("selected") => Ok((false, *files)),
		_ => Err(refuse(
			"history requires device or selected source and an explicit files choice",
		)),
	}
}
/// Decode one bounded metadata snapshot and resolve only the selected field.
/// No reference population is materialized. The facade retains that exact
/// target and its original source after this invocation retires.
pub(super) fn selected_history(call: &mut Call<'_>, input: Invocation<'_>, local: Option<&Ref>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let (device, files) = history_source(input.args)?;
	if device {
		return archive_reader(
			call,
			local.ok_or_else(|| refuse("session archive is not installed"))?,
			files,
		);
	}
	let selected = record.intent.archive.map(|key| custody::Coordinate {
		role: custody::Role::ArchiveAccess,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	});
	let target = match selected {
		Some(coordinate) => records::Field::Retained(records::location(
			&record
				.custody
				.get(coordinate)
				.ok_or_else(|| refuse("selected archive custody is absent"))?,
		))
		.resolve(call, input)?,
		None => return Err(refuse("no archive peer is selected")),
	};
	archive_reader(call, &target, files)
}
pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	if matches!(input.verb, "room-identity-reader" | "room-publication-identity") {
		rooms::coordinate(input.args)?;
		return Requirement::new(
			&[Permission::ManageCustody.key(), Permission::ReplaceWorkspace.key()],
			&[],
		);
	}
	if input.verb == "archive-issuer-reader" {
		if !input.args.is_empty() {
			return Err(refuse("archive issuer selection takes no arguments"));
		}
		return Requirement::new(&[Permission::ReadArchive.key(), Permission::ShareCustody.key()], &[]);
	}
	if input.verb == "export-configuration" {
		if !input.args.is_empty() {
			return Err(refuse("configuration export takes no arguments"));
		}
		return Requirement::new(
			&[Permission::ObserveWorkspace.key(), Permission::ShareCustody.key()],
			&[],
		);
	}
	if matches!(input.verb, "operations-reader" | "trace-snapshot") {
		return operations::requirement(input.args);
	}
	if input.verb == "custody-recipe" {
		recipe_coordinate(input.args)?;
		return Requirement::new(&[Permission::ShareCustody.key()], &[]);
	}
	if input.verb == "file-reader" {
		file(input.args)?;
		return Requirement::new(&[Permission::ReadFile.key()], &[]);
	}
	if input.verb == "bridge-form-reader" {
		seat(input.args)?;
		return Requirement::new(&[Permission::ObserveWorkspace.key()], &[]);
	}
	if input.verb == "history-reader" {
		seat(input.args)?;
		return Requirement::new(&[Permission::History.key()], &[]);
	}
	let request = request(input.args)?;
	let permissions = [Permission::ReadArchive.key(), Permission::ReadFile.key()];
	Requirement::new(&permissions[..if request.files { 2 } else { 1 }], &[])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	if input.verb == "trace-snapshot" {
		operations::selection(input.args, &record.intent)?;
		return Ok(Vec::new());
	}
	if input.verb == "export-configuration" {
		return Ok(Vec::new());
	}
	let coordinate = if matches!(input.verb, "room-identity-reader" | "room-publication-identity") {
		rooms::selection(input.args, &record.intent)?
	} else if input.verb == "operations-reader" {
		operations::selection(input.args, &record.intent)?
	} else if input.verb == "custody-recipe" {
		recipe_selection(input.args, &record.intent)?
	} else if input.verb == "archive-issuer-reader" {
		let Some(key) = record.intent.archive else {
			return Ok(Vec::new());
		};
		custody::Coordinate {
			role: custody::Role::ArchiveAccess,
			key: custody::FieldKey::new(key.slot(), key.generation()),
		}
	} else if input.verb == "workspace-history-reader" {
		if history_source(input.args)?.0 {
			return Ok(Vec::new());
		}
		let Some(key) = record.intent.archive else {
			return Ok(Vec::new());
		};
		custody::Coordinate {
			role: custody::Role::ArchiveAccess,
			key: custody::FieldKey::new(key.slot(), key.generation()),
		}
	} else if matches!(input.verb, "history-reader" | "bridge-form-reader") {
		seat(input.args)?
	} else {
		request(input.args)?.coordinate
	};
	// Retained facades use the original intent only for source admission. Their
	// upstream target is already held; current selection cannot redirect it.
	if input.delivery == Delivery::Forwarding {
		return Ok(Vec::new());
	}
	let target = record
		.custody
		.get(coordinate)
		.ok_or_else(|| refuse("reader custody is absent"))?;
	let location = records::location(&target);
	if input.verb == "room-publication-identity" {
		return Ok(vec![ReferenceRequest::InspectPageUri {
			page: location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid recipe page"))?,
			field: location.field,
		}]);
	}
	if input.verb == "custody-recipe" {
		return Ok(vec![ReferenceRequest::RestorePageWithUri {
			page: location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid recipe page"))?,
			field: location.field,
		}]);
	}
	Ok(vec![ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid archive custody page"))?,
		field: location.field,
	}])
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	if input.verb == "room-identity-reader" {
		return rooms::invoke(call, input);
	}
	if input.verb == "room-publication-identity" {
		return rooms::publication_identity(call, input);
	}
	if input.verb == "archive-issuer-reader" {
		let record = records::decode(input)?;
		let Some(key) = record.intent.archive else {
			return Ok(Argument::Void);
		};
		let selected = custody::Coordinate {
			role: custody::Role::ArchiveAccess,
			key: custody::FieldKey::new(key.slot(), key.generation()),
		};
		let field = record
			.custody
			.get(selected)
			.ok_or_else(|| refuse("selected archive issuer custody is absent"))?;
		let target = records::reference(&field).resolve(call, input)?;
		let methods = [ReadMethod {
			verb: rooms_application::archive::shares::protocol::LIST,
			results: &[],
		}];
		return call
			.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
			.map(Argument::Reference);
	}
	if input.verb == "export-configuration" {
		let intent = records::metadata(input)?
			.intent
			.export_configuration()
			.map_err(refuse)?;
		let mut coordinates: Vec<_> = intent.coordinates().collect();
		coordinates.sort_unstable_by_key(|coordinate| {
			(
				coordinate.role as usize,
				coordinate.key.slot().get(),
				coordinate.key.generation().get(),
			)
		});
		coordinates.dedup();
		if coordinates.len() > session::records::FIELDS_PER_PAGE {
			return Err(refuse("configuration exceeds the atomic import field bound"));
		}
		return Ok(Argument::List(vec![
			Argument::Integer(i64::try_from(input.content_revision).map_err(|_| refuse("export revision exhausted"))?),
			serde_json::to_string(&intent)
				.map_err(|_| refuse("invalid export configuration"))?
				.into(),
			Argument::List(
				coordinates
					.into_iter()
					.map(|coordinate| serde_json::to_string(&coordinate).map(Argument::String))
					.collect::<core::result::Result<_, _>>()
					.map_err(|_| refuse("invalid export coordinate"))?,
			),
		]));
	}
	if input.verb == "operations-reader" {
		return operations::invoke(call, input);
	}
	if input.verb == "custody-recipe" {
		let record = records::metadata(input)?;
		let selected = recipe_selection(input.args, &record.intent)?;
		let field = record
			.custody
			.get(selected)
			.ok_or_else(|| refuse("exact recipe custody is absent"))?;
		let location = records::location(&field);
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid recipe page"))?;
		return Ok(call
			.page_saved_uri(page, location.field)?
			.map_or(Argument::Void, |uri| Argument::String(uri.into())));
	}
	let blob = [ReadMethod {
		verb: rooms_application::protocol_data::READ,
		results: &[],
	}];
	if input.verb == "file-reader" {
		return call
			.disclose_reads_copying(file(input.args)?, &[ReadInterface { methods: &blob }], 0)
			.map(Argument::Reference);
	}
	if matches!(input.verb, "history-reader" | "bridge-form-reader") {
		let coordinate = seat(input.args)?;
		let record = records::decode(input)?;
		let target = record
			.custody
			.get(coordinate)
			.ok_or_else(|| refuse("reader seat custody is absent"))?;
		let target = records::reference(&target).resolve(call, input)?;
		let methods = [ReadMethod {
			verb: if input.verb == "bridge-form-reader" {
				rooms_application::bridge::ASK
			} else {
				rooms_application::room::history::VERB
			},
			results: &[],
		}];
		return call
			.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
			.map(Argument::Reference);
	}
	let request = request(input.args)?;
	let record = records::decode(input)?;
	let target = record
		.custody
		.get(request.coordinate)
		.ok_or_else(|| refuse("archive custody is absent"))?;
	let target = records::reference(&target).resolve(call, input)?;
	archive_reader(call, &target, request.files)
}

pub(super) fn trace_snapshot(input: Invocation<'_>, publisher: Option<&dyn crate::trace::Status>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let coordinate = operations::selection(input.args, &record.intent)?;
	if input.args[1].as_str() != Some("trace") {
		return Err(refuse("trace snapshot requires the exact trace interface"));
	}
	let view = match publisher {
		Some(publisher) => publisher
			.snapshot(coordinate)
			.map_err(|error| refuse(&error.to_string()))?,
		None => serde_json::json!({"url":"","connected":false,"refusal":"No trace publisher is installed"}).to_string(),
	};
	Ok(view.into())
}
fn recipe_coordinate(args: &[Argument]) -> Result<custody::Coordinate> {
	let [value] = args else {
		return Err(refuse("custody-recipe takes one exact coordinate"));
	};
	let coordinate = custody::Coordinate::decode(text(value)?).map_err(|_| refuse("invalid recipe coordinate"))?;
	if coordinate.role.live() {
		return Err(refuse("live custody has no durable publication"));
	}
	Ok(coordinate)
}
fn recipe_selection(
	args: &[Argument],
	intent: &rooms_application::content::session::workspace::Intent,
) -> Result<custody::Coordinate> {
	let selected = recipe_coordinate(args)?;
	if !intent.coordinates().any(|coordinate| coordinate == selected) {
		return Err(refuse(
			"publication requires an exact selected authority, not a receipt or private field",
		));
	}
	Ok(selected)
}
pub(in crate::session::managed) fn archive_reader(call: &mut Call<'_>, target: &Ref, files: bool) -> Result<Argument> {
	archive_interfaces(files, |interfaces| call.disclose_reads_copying(target, interfaces, 0)).map(Argument::Reference)
}
pub(in crate::session::managed) fn retained_archive_reader(
	continuation: &glowcap::loam::Continuation,
	index: usize,
	files: bool,
) -> Result<Ref> {
	archive_interfaces(files, |interfaces| {
		continuation.project_reads_copying(index, interfaces, 0)
	})
}
fn archive_interfaces<T>(files: bool, project: impl FnOnce(&[ReadInterface<'_>]) -> Result<T>) -> Result<T> {
	let blob = [ReadMethod {
		verb: rooms_application::protocol_data::READ,
		results: &[],
	}];
	let methods = [
		ReadMethod {
			verb: protocol::READ,
			results: &[],
		},
		ReadMethod {
			verb: protocol::NARROW,
			results: &[0],
		},
		ReadMethod {
			verb: admission::ATTACHMENT,
			results: &[1],
		},
		ReadMethod {
			verb: admission::BLOB,
			results: &[1],
		},
	];
	let interfaces = [
		ReadInterface {
			methods: &methods[..if files { 4 } else { 2 }],
		},
		ReadInterface { methods: &blob },
	];
	project(&interfaces)
}
fn file(args: &[Argument]) -> Result<&Ref> {
	let [Argument::Reference(target)] = args else {
		return Err(refuse("file-reader takes an already held blob capability"));
	};
	Ok(target)
}
fn seat(args: &[Argument]) -> Result<custody::Coordinate> {
	let [coordinate] = args else {
		return Err(refuse("seat reader takes exact seat custody"));
	};
	let coordinate =
		custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid reader seat coordinate"))?;
	if coordinate.role != custody::Role::RoomSeat {
		return Err(refuse("seat reader requires an already held seat"));
	}
	Ok(coordinate)
}
