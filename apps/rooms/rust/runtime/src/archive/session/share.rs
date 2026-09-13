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
	fn owner(&self) -> Result<Rc<State<P>>, Error> {
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
	pub fn dispatch(&self, host: &Host, facet: &Facet, verb: &str, args: &[Argument]) -> Result<Argument, Error> {
		let owner = self.owner()?;
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
			Request::Narrow(narrowed) => {
				let session = glowcap::current_session()?
					.ok_or_else(|| Error::invalid("archive narrow needs a caller session"))?;
				owner
					.hosting
					.mint(&session, Kind::Facet, || self.spawn(&session, narrowed))
					.map(Into::into)
			}
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
