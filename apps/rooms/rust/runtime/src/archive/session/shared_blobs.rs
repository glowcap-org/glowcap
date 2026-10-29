//! Shared readers pin the original keeper, attachment position and revocation.
//! Their deferred replies use the archive queue, including ingestion callbacks.
use super::*;
use crate::archive::hosting::{Kind, Permit};
use glowcap::{Argument, Host, Ref, Resolver, Session};
use rooms_application::archive::{
	Facet,
	blobs::{self, admission},
};
use rooms_glowcap::Value;

pub(super) enum Selection {
	Attachment {
		reader: blobs::Reader,
		record: Record,
		index: usize,
	},
	Digest {
		scope: Filter,
		digest: String,
	},
}
pub(super) struct Request<P: Platform> {
	pub work: Work<P>,
	pub selection: Selection,
	pub host: Host,
	pub session: Option<Session>,
	pub reply: Resolver,
}
pub(super) enum Reader<P: Platform> {
	Local(blobs::Reader),
	Peer(Blob<P>),
}
pub(super) fn admit<P: Platform>(
	work: &Work<P>,
	host: &Host,
	facet: &Facet,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	if args.len() > 2 {
		return Err(Error::invalid("invalid archive blob arguments"));
	}
	let empty = Argument::Void;
	let values = [
		Value(args.first().unwrap_or(&empty)),
		Value(args.get(1).unwrap_or(&empty)),
	];
	let selection = match facet
		.admit_blob(verb, &values[..args.len()])
		.map_err(Error::invalid_by)?
	{
		admission::Request::Attachment { reader, record } => Selection::Attachment {
			index: reader.address().index(),
			reader,
			record,
		},
		admission::Request::Digest { scope, digest } => Selection::Digest { scope, digest },
		admission::Request::Put { .. } => return Err(Error::refused("archive share is read-only")),
	};
	let bytes = match &selection {
		Selection::Attachment { reader, record, .. } => reader.retained_bytes() + record.retained_bytes(),
		Selection::Digest { scope, digest } => scope.retained_bytes() + digest.capacity(),
	};
	let owner = work.owner()?;
	let session = glowcap::current_session()?;
	owner.enqueue(bytes, 0, false, None, |_| {
		Ok((
			Command::SharedReader(Request {
				work: work.clone(),
				selection,
				host: host.clone(),
				session,
				reply: host.defer_turn()?,
			}),
			Argument::Void,
		))
	})
}
impl<P: Platform> Work<P> {
	pub(super) fn spawn_reader(&self, host: &Host, session: Option<&Session>, reader: Reader<P>) -> Result<Ref, Error> {
		let owner = self.owner()?;
		// One Rc body and actor closure; local reader metadata includes its Arc
		// backing. Peer metadata remains owned and charged by the pinned keeper.
		let bytes = core::mem::size_of::<Reader<P>>()
			+ 2 * core::mem::size_of::<usize>()
			+ core::mem::size_of::<(Work<P>, Host, Rc<Reader<P>>, Permit)>()
			+ match &reader {
				Reader::Local(r) => r.retained_bytes(),
				Reader::Peer(_) => 0,
			};
		let create = || {
			let permit = owner.hosting.retain(bytes)?;
			let reader = Rc::new(reader);
			let work = self.clone();
			let actor_host = host.clone();
			let actor = move |verb: Option<&str>, args: &[Argument]| {
				let _permit = &permit;
				let result = (|| {
					let verb = verb.ok_or_else(|| Error::invalid("unknown blob reader method"))?;
					let owner = work.owner()?;
					if args.len() != 2 {
						return Err(Error::invalid("invalid archive byte arguments"));
					}
					let values = [Value(&args[0]), Value(&args[1])];
					let (offset, maximum) = admission::read(verb, &values).map_err(Error::invalid_by)?;
					owner.enqueue(0, 0, false, None, |_| {
						Ok((
							Command::SharedRead(
								work.clone(),
								reader.clone(),
								offset,
								maximum,
								actor_host.defer_turn()?,
							),
							Argument::Void,
						))
					})
				})();
				result.map_err(Error::into_refusal)
			};
			Ok(match session {
				Some(s) => s.spawn_owned(actor)?,
				None => host.spawn(actor)?,
			})
		};
		match session {
			Some(s) => owner.hosting.mint(s, Kind::Reader, create),
			None => owner.hosting.mint_local(Kind::Reader, create),
		}
	}
}
