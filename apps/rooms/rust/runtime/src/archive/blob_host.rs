//! File methods share bounded backend admission. Committed byte reads can
//! serve callbacks during ingestion; mutations remain serial. Reader issuance
//! stays with the archive's caller accounts and never replenishes on release.
use super::*;
use rooms_application::archive::{
	blobs::{admission, Reader as BlobReader},
	Access,
};
use rooms_glowcap::client::{files::File, Client};
impl<P: Platform> Receiver<P> {
	pub(super) fn enqueue(
		&self,
		state: &State<P>,
		authority: &Authority,
		request: Operation<P>,
	) -> Result<Argument, String> {
		authority.check()?;
		let permit = state.reserve(&request)?;
		let slot = state.requests.try_reserve().map_err(|_| "archive worker unavailable")?;
		let session = glowcap::current_session()
			.map_err(|e| e.to_string())?
			.ok_or("archive needs a caller session")?;
		let reply = session.host().defer_turn().map_err(|e| e.to_string())?;
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
	) -> Result<Argument, String> {
		if !state.retains_blobs {
			return Err("archive backend does not retain file bytes".into());
		}
		if args.len() > admission::MAX_ARGUMENTS {
			return Err("invalid archive file argument count".into());
		}
		let empty = Argument::Void;
		let mut views = [Value(&empty); admission::MAX_ARGUMENTS];
		for (view, arg) in views.iter_mut().zip(args) {
			*view = Value(arg);
		}
		let request = facet
			.admit_blob(verb, &views[..args.len()])
			.map_err(|e| e.to_string())?;
		let session = glowcap::current_session()
			.map_err(|e| e.to_string())?
			.ok_or("archive files need a caller session")?;
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
			admission::Request::Attachment(reader) => self
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
	) -> Result<Ref, String> {
		let state = self.0.upgrade().ok_or("archive owner has ended")?;
		state.live()?;
		let bytes = reader.retained_bytes() + core::mem::size_of::<(Receiver<P>, FacetPermit, Authority)>();
		let permit = state.hosting.retain(bytes)?;
		let receiver = self.clone();
		state.hosting.mint(&session, hosting::Kind::Reader, || {
			session
				.spawn_owned(move |verb, args| {
					let _held = &permit;
					let state = receiver.0.upgrade().ok_or("archive owner has ended")?;
					state.live()?;
					authority.check()?;
					if args.len() != 2 {
						return Err("archive blob read needs offset and length".into());
					}
					let (offset, maximum) =
						admission::read(verb, &[Value(&args[0]), Value(&args[1])]).map_err(|e| e.to_string())?;
					receiver.enqueue(
						&state,
						&authority,
						Operation::ReadBlob {
							reader: reader.clone(),
							offset,
							maximum,
						},
					)
				})
				.map_err(|e| e.to_string())
		})
	}
}
pub(super) fn reader_facet(scope: Filter) -> Result<Facet, String> {
	Facet::new(scope, Access::Read).map_err(|e| e.to_string())
}
