//! Private worker ingress restores selected committed occurrences. Public use
//! cannot retrieve an upstream actor or a management control from coordinates.
use super::{Session, content::refuse, records};
use glowcap::{
	Argument, Ref, Result,
	loam::{Call, Invocation, ReferenceRequest},
};
use rooms_application::{
	content::session::{custody, records as codec},
	failure::FailureCode,
};
use rooms_glowcap::client::{Deadline, Tasks};

/// The Host restores a saved address by dialing it, and names a transport it
/// has no dialer for as the restoration's cause: `UnknownTransport`, from the
/// Zig Host's error set and from a byte-fed Host's connector refusal alike.
/// That condition clears only when the row or the session's dial transports
/// change, so the session names it with its wire code instead of letting a
/// bare break stand. The session's own custody restoration and a worker's
/// call through its source both read the Host's answer here.
pub(super) fn name_undialable(error: glowcap::Error) -> glowcap::Error {
	if !undialable(error.kind(), error.message()) {
		return error;
	}
	refuse(
		&FailureCode::SavedTransportUnavailable.line("the saved address names a transport this session does not dial"),
	)
}

/// Whether a Host's answer is a restoration that failed for want of a dialer:
/// a break whose restoration cause names `UnknownTransport` as one word.
fn undialable(kind: glowcap::ErrorKind, message: Option<&str>) -> bool {
	kind == glowcap::ErrorKind::Broken
		&& message
			.and_then(|message| message.split_once("RestorationFailed: "))
			.is_some_and(|(_, cause)| {
				cause
					.split(|c: char| !c.is_ascii_alphanumeric())
					.any(|word| word == "UnknownTransport")
			})
}

fn coordinates(args: &[Argument]) -> Result<Vec<custody::Coordinate>> {
	let values = match args {
		[Argument::Reference(_), Argument::List(values)]
		| [Argument::Reference(_), Argument::List(values), Argument::Boolean(true)] => values,
		_ => return Err(refuse("private custody takes a bounded coordinate list")),
	};
	if values.len() > codec::FIELDS_PER_PAGE {
		return Err(refuse("private custody exceeds one page"));
	}
	values
		.iter()
		.map(|value| {
			custody::Coordinate::decode(value.as_str().ok_or_else(|| refuse("invalid custody coordinate"))?)
				.map_err(|_| refuse("invalid custody coordinate"))
		})
		.collect()
}

/// Admission and reference declaration run before Call exposes the actual
/// source. The exact private root is therefore an explicit witness, checked
/// before reading metadata or restoring a saved field. Invocation still checks
/// the actual source: supplying the witness never delegates private ingress.
pub(super) fn authorize(input: Invocation<'_>, root: &Ref) -> Result<()> {
	if !matches!(input.args.first(), Some(Argument::Reference(witness)) if witness == root) {
		return Err(refuse("private session root required"));
	}
	Ok(())
}

/// One page-sized declaration spine restores the selected occurrences only.
/// Coordinates own scalar metadata through this callback. Loam owns all saved
/// recipes and their restore budget. No inventory scan or bearer codec runs.
pub(super) fn references(input: Invocation<'_>, root: &Ref) -> Result<Vec<ReferenceRequest>> {
	authorize(input, root)?;
	let record = records::metadata(input)?;
	coordinates(input.args)?
		.into_iter()
		.map(|coordinate| {
			let field = record
				.custody
				.get(coordinate)
				.ok_or_else(|| refuse("exact custody is absent"))?;
			let location = records::location(&field);
			let page = location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid custody page"))?;
			Ok(if input.args.len() == 3 {
				ReferenceRequest::RestorePageWithUri {
					page,
					field: location.field,
				}
			} else {
				ReferenceRequest::RestorePage {
					page,
					field: location.field,
				}
			})
		})
		.collect()
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>, root: &Ref) -> Result<Argument> {
	authorize(input, root)?;
	if call.source()? != *root {
		return Err(refuse("private session root required"));
	}
	let record = records::metadata(input)?;
	coordinates(input.args)?
		.into_iter()
		.map(|coordinate| {
			let field = record
				.custody
				.get(coordinate)
				.ok_or_else(|| refuse("exact custody is absent"))?;
			let location = records::location(&field);
			let page = input
				.graph
				.and_then(|pages| pages.get(location.page.checked_sub(1)?))
				.ok_or_else(|| refuse("invalid custody page"))?;
			if input.args.len() == 3 {
				let uri = call
					.page_saved_uri(page, location.field)?
					.map_or(Argument::Void, |uri| Argument::String(uri.into()));
				Ok(Argument::List(vec![
					call.disclose_page(page, location.field, false)?,
					uri,
				]))
			} else {
				call.disclose_page(page, location.field, false)
			}
		})
		.collect::<Result<Vec<_>>>()
		.map(Argument::List)
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Only the embedding with the private session owner can restore worker or
	/// editor custody. Grant inventory and public workspace clients expose no
	/// equivalent operation. Returned controls keep their own shared ceilings.
	pub async fn restore_custody(&self, selected: &[custody::Coordinate]) -> Result<Vec<Ref>> {
		self.restore_selected(selected, false).await.and_then(|held| {
			held.into_iter()
				.map(|value| Ref::try_from(&value).map_err(|_| refuse("private custody returned no capability")))
				.collect()
		})
	}

	/// Exact saved occurrences and their canonical publication home. One URI
	/// result copy survives the callback. Shared preparation retains bytes only
	/// for these explicitly requested fields. Worker restoration pays none.
	pub async fn restore_publication_custody(
		&self,
		selected: &[custody::Coordinate],
	) -> Result<Vec<(Ref, Option<String>)>> {
		let held = self.restore_selected(selected, true).await?;
		held.into_iter()
			.map(|value| {
				let (value, uri) = {
					let Argument::List(mut pair) = value else {
						return Err(refuse("invalid publication custody"));
					};
					if pair.len() != 2 {
						return Err(refuse("invalid publication custody"));
					}
					let uri = match pair.pop().ok_or_else(|| refuse("invalid publication custody"))? {
						Argument::Void => None,
						Argument::String(uri) => Some(uri),
						_ => return Err(refuse("invalid saved URI")),
					};
					(pair.pop().ok_or_else(|| refuse("invalid publication custody"))?, uri)
				};
				Ref::try_from(&value)
					.map(|reference| (reference, uri))
					.map_err(|_| refuse("private custody returned no capability"))
			})
			.collect()
	}
	async fn restore_selected(&self, selected: &[custody::Coordinate], with_uris: bool) -> Result<Vec<Argument>> {
		if selected.len() > codec::FIELDS_PER_PAGE {
			return Err(refuse("private custody exceeds one page"));
		}
		let args = selected
			.iter()
			.map(|coordinate| {
				serde_json::to_string(coordinate)
					.map(Argument::String)
					.map_err(|_| refuse("invalid custody coordinate"))
			})
			.collect::<Result<Vec<_>>>()?;
		let root = self.state.writer.root()?;
		let mut request = vec![root.into(), Argument::List(args)];
		if with_uris {
			request.push(Argument::Boolean(true));
		}
		let result = self
			.state
			.writer
			.idempotent("restore-custody", &request)
			.await
			.map_err(name_undialable)?;
		let Argument::List(held) = result else {
			return Err(refuse("invalid private custody result"));
		};
		if held.len() != selected.len() {
			return Err(refuse("invalid private custody result"));
		}
		Ok(held)
	}
}

#[cfg(test)]
mod tests {
	use super::undialable;
	use glowcap::ErrorKind;

	#[test]
	fn a_restoration_without_a_dialer_is_undialable_from_the_zig_host_and_a_byte_fed_host_alike() {
		assert!(undialable(
			ErrorKind::Broken,
			Some("RestorationFailed: UnknownTransport")
		));
		assert!(undialable(
			ErrorKind::Broken,
			Some(
				"session Discovery(\"ocapn://d.id\"): glowcap error -12: RestorationFailed: UnknownTransport: byte-fed Host has no connector for transport \"tcp\""
			)
		));
	}

	#[test]
	fn every_other_answer_stays_the_networks() {
		assert!(!undialable(
			ErrorKind::Broken,
			Some("RestorationFailed: ConnectionRefused")
		));
		assert!(!undialable(
			ErrorKind::Broken,
			Some("RestorationFailed: UnknownTransportation")
		));
		assert!(!undialable(
			ErrorKind::Broken,
			Some("UnknownTransport: byte-fed Host has no connector for transport \"tcp\"")
		));
		assert!(!undialable(
			ErrorKind::Closed,
			Some("RestorationFailed: UnknownTransport")
		));
		assert!(!undialable(ErrorKind::Broken, None));
	}
}
