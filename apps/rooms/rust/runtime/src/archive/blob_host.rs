//! File methods share bounded backend admission. Committed byte reads can
//! serve callbacks during ingestion; mutations remain serial. Reader issuance
//! stays with the archive's caller accounts and never replenishes on release.
use super::*;
use rooms_application::archive::{
	Access,
	blobs::{Reader as BlobReader, admission},
};
use rooms_glowcap::client::{Client, files::File};
impl<P: Platform> Receiver<P> {
	pub(super) fn enqueue(
		&self,
		state: &State<P>,
		authority: &Authority,
		request: Operation<P>,
	) -> Result<Argument, Error> {
		authority.check()?;
		let permit = state.reserve(&request)?;
		let slot = state
			.requests
			.try_reserve()
			.map_err(|_| Error::closed("archive worker unavailable"))?;
		let session = glowcap::current_session()?.ok_or_else(|| Error::invalid("archive needs a caller session"))?;
		let reply = session.host().defer_turn()?;
		slot.send(Pending {
			request,
			authority: authority.clone(),
			reply: Reply::Remote(reply),
			_permit: permit,
		});
		Ok(Argument::Void)
	}
	pub(super) fn receive_blob(
		&self,
		state: &State<P>,
		facet: &Facet,
		authority: &Authority,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, Error> {
		if !state.retains_blobs {
			return Err(Error::refused("archive backend does not retain file bytes"));
		}
		if args.len() > admission::MAX_ARGUMENTS {
			return Err(Error::invalid("invalid archive file argument count"));
		}
		let empty = Argument::Void;
		let mut views = [Value(&empty); admission::MAX_ARGUMENTS];
		for (view, arg) in views.iter_mut().zip(args) {
			*view = Value(arg);
		}
		let request = facet
			.admit_blob(verb, &views[..args.len()])
			.map_err(Error::invalid_by)?;
		let session =
			glowcap::current_session()?.ok_or_else(|| Error::invalid("archive files need a caller session"))?;
		match request {
			admission::Request::Put { record, files } => {
				let permit = state.reserve_files(files.iter().map(|file| file.description.size()))?;
				let client = Client::new(session, state.platform.clone());
				let sources = files.into_iter().map(|file| File::new(client.clone(), file)).collect();
				self.enqueue(
					state,
					authority,
					Operation::Files {
						record,
						sources,
						files: permit,
					},
				)
			}
			admission::Request::Attachment { reader, .. } => self
				.spawn_reader(session, reader, authority.descendant())
				.map(Into::into),
			admission::Request::Digest { scope, digest } => self.enqueue(
				state,
				authority,
				Operation::Digest {
					scope,
					digest,
					session,
					receiver: self.clone(),
				},
			),
		}
	}
	pub(super) fn spawn_reader(
		&self,
		session: Session,
		reader: BlobReader,
		authority: Authority,
	) -> Result<Ref, Error> {
		let state = self
			.0
			.upgrade()
			.ok_or_else(|| Error::closed("archive owner has ended"))?;
		state.live()?;
		let bytes = reader.retained_bytes() + core::mem::size_of::<(Receiver<P>, FacetPermit, Authority)>();
		let permit = state.hosting.retain(bytes)?;
		let receiver = self.clone();
		state.hosting.mint(&session, hosting::Kind::Reader, || {
			Ok(session.spawn_owned(move |verb, args| {
				let _held = &permit;
				let read = || {
					let state = receiver
						.0
						.upgrade()
						.ok_or_else(|| Error::closed("archive owner has ended"))?;
					state.live()?;
					authority.check()?;
					if args.len() != 2 {
						return Err(Error::invalid("archive blob read needs offset and length"));
					}
					let (offset, maximum) =
						admission::read(verb, &[Value(&args[0]), Value(&args[1])]).map_err(Error::invalid_by)?;
					receiver.enqueue(
						&state,
						&authority,
						Operation::ReadBlob {
							reader: reader.clone(),
							offset,
							maximum,
						},
					)
				};
				read().map_err(Error::into_refusal)
			})?)
		})
	}
}
pub(super) fn reader_facet(scope: Filter) -> Result<Facet, Error> {
	Facet::new(scope, Access::Read).map_err(Error::invalid_by)
}
