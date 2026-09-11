//! Live authority for admitted work and derived archived-file readers.
use super::{
	error::Error,
	facet::{Facet, Inner, Rights},
	Platform,
};
use crate::grant_publications::GrantAuthority;
use std::{
	cell::Cell,
	rc::{Rc, Weak},
};

#[derive(Clone)]
pub(super) enum Authority {
	Admin,
	Published(GrantAuthority),
	Delegate { rights: Rights, live: Rc<Cell<bool>> },
}
impl Authority {
	pub fn rights(&self) -> Result<Rights, Error> {
		match self {
			Self::Admin => Ok(Rights::admin()),
			Self::Published(grant) => grant.read(Rights::of).map_err(Error::refused),
			Self::Delegate { rights, live } if live.get() => Ok(rights.clone()),
			Self::Delegate { .. } => Err(Error::refused("this Rooms session facet was revoked")),
		}
	}
}
#[derive(Clone)]
pub(super) struct HistoryAccess<P: Platform> {
	facet: Weak<Inner<P>>,
	authority: Authority,
}
impl<P: Platform> HistoryAccess<P> {
	pub fn new(facet: &Facet<P>, authority: &Authority) -> Result<Self, Error> {
		let access = Self {
			facet: Rc::downgrade(&facet.0),
			authority: authority.clone(),
		};
		access.check()?;
		Ok(access)
	}
	pub fn check(&self) -> Result<(), Error> {
		self.facet()?.require_live()?;
		let rights = self.authority.rights()?;
		if !rights.may_observe() || !rights.history {
			return Err(Error::refused("this Rooms session facet cannot read archived history"));
		}
		Ok(())
	}
	pub fn check_file(&self) -> Result<(), Error> {
		self.check()?;
		if !self
			.facet()?
			.0
			.commands
			.view()
			.read(|state| state.checkpoint().map(|checkpoint| checkpoint.keeps_history()))??
		{
			return Err(Error::refused("this Rooms session facet cannot read archived files"));
		}
		Ok(())
	}
	fn facet(&self) -> Result<Facet<P>, Error> {
		self.facet
			.upgrade()
			.map(Facet)
			.ok_or_else(|| Error::refused("this Rooms session facet was revoked"))
	}
}
