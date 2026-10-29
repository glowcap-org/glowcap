//! Read-only shares retain their source and revocation through every descendant.
use super::*;
use crate::archive::hosting::{Kind, Permit as FacetPermit};
use glowcap::{Argument, Host, Ref, Session};
use rooms_application::archive::{Facet, request::Request};
use rooms_glowcap::{Value, archive as wire};
use std::rc::Weak;

#[derive(Clone)]
pub(super) struct Work<P: Platform> {
	owner: Weak<State<P>>,
	pub source: Keeper<P>,
	active: Rc<Cell<bool>>,
}
impl<P: Platform> Work<P> {
	fn spawn_local(&self, host: &Host, facet: Facet) -> Result<Ref, Error> {
		let owner = self.owner()?;
		let permit = owner
			.hosting
			.retain(facet.scope().retained_bytes() + core::mem::size_of::<(Work<P>, Facet, FacetPermit)>())?;
		let work = self.clone();
		let actor_host = host.clone();
		Ok(host.spawn(move |verb, args| {
			let _permit = &permit;
			work.dispatch(&actor_host, &facet, verb, args)
				.map_err(Error::into_refusal)
		})?)
	}
	pub fn local(state: &Rc<State<P>>, active: Rc<Cell<bool>>) -> Self {
		Self {
			owner: Rc::downgrade(state),
			source: Keeper::Local(Local {
				owner: Rc::downgrade(state),
			}),
			active,
		}
	}
	pub fn selected(state: &Rc<State<P>>, source: Keeper<P>) -> Self {
		Self {
			owner: Rc::downgrade(state),
			source,
			active: Rc::new(Cell::new(true)),
		}
	}
	pub fn check(&self) -> Result<(), Error> {
		if !self.active.get() {
			return Err(Error::refused("this archive share was revoked"));
		}
		Ok(())
	}
	pub(super) fn owner(&self) -> Result<Rc<State<P>>, Error> {
		self.check()?;
		let owner = self
			.owner
			.upgrade()
			.ok_or_else(|| Error::closed("session archive is closed"))?;
		if *owner.stop.borrow() {
			return Err(Error::closed("session archive is closed"));
		}
		Ok(owner)
	}

	pub fn spawn(&self, session: &Session, facet: Facet) -> Result<Ref, Error> {
		let owner = self.owner()?;
		let permit = owner
			.hosting
			.retain(facet.scope().retained_bytes() + core::mem::size_of::<(Work<P>, Facet, FacetPermit)>())?;
		let work = self.clone();
		let host = session.host();
		Ok(session.spawn_owned(move |verb, args| {
			let _permit = &permit;
			work.dispatch(&host, &facet, verb, args).map_err(Error::into_refusal)
		})?)
	}
	pub fn dispatch(
		&self,
		host: &Host,
		facet: &Facet,
		verb: Option<&str>,
		args: &[Argument],
	) -> Result<Argument, Error> {
		let verb = verb.ok_or_else(|| Error::invalid("unknown archive share method"))?;
		let owner = self.owner()?;
		if matches!(
			verb,
			rooms_application::archive::blobs::admission::ATTACHMENT
				| rooms_application::archive::blobs::admission::BLOB
		) {
			return super::shared_blobs::admit(self, host, facet, verb, args);
		}
		if args.len() > 3 {
			return Err(Error::invalid("invalid archive share argument count"));
		}
		let empty = Argument::Void;
		let mut views = [Value(&empty); 3];
		for (view, argument) in views.iter_mut().zip(args) {
			*view = Value(argument);
		}
		match facet.admit(verb, &views[..args.len()]).map_err(Error::invalid_by)? {
			Request::Empty(page) => wire::page_row(&page, &Filter::default(), page.next, 1).map_err(Error::invalid_by),
			Request::Narrow(narrowed) => match glowcap::current_session()? {
				Some(session) => owner
					.hosting
					.mint(&session, Kind::Facet, || self.spawn(&session, narrowed)),
				None => owner
					.hosting
					.mint_local(Kind::Facet, || self.spawn_local(host, narrowed)),
			}
			.map(Into::into),
			Request::Put(_) => Err(Error::refused("archive share is read-only")),
			Request::Read { filter, after, limit } => owner.enqueue(filter.retained_bytes(), 0, false, None, |_| {
				let reply = host.defer_turn()?;
				Ok((
					Command::SharedPage(self.clone(), filter, after, limit, reply),
					Argument::Void,
				))
			}),
		}
	}
}
impl<P: Platform> SessionArchive<P> {
	/// One held local history capability. Shared managed content mediates it
	/// through the viewer's History permission. It is never published raw.
	pub fn local_reader(&self, host: &Host, scope: Filter) -> Result<Ref, Error> {
		let work = Work::local(&self.0, Rc::new(Cell::new(true)));
		let facet = Facet::new(scope, rooms_application::archive::Access::Read).map_err(Error::invalid_by)?;
		self.0.hosting.mint_local(Kind::Facet, || work.spawn_local(host, facet))
	}
	/// Choose the source in queue order and retain it for this share's lifetime.
	pub fn share(&self, session: Session, facet: Facet) -> Result<Reply<Ref>, Error> {
		if facet.access() != rooms_application::archive::Access::Read {
			return Err(Error::refused("archive share must be read-only"));
		}
		self.0.admit(facet.scope().retained_bytes(), 0, |answer| {
			Command::Lend(session, facet, answer)
		})
	}
}
