//! Archive calls retain their actual capability and validate returned rows before
//! exposing records. Storage and facet authority stay with the hosted archive.
use super::*;
use crate::{archive as wire, Value};
use rooms_application::{
	archive::{self, index::Page, protocol, Access, Filter, Record},
	fields::SafeInteger,
};
use std::sync::Arc;
mod blobs;
mod shares;
pub use blobs::Blob;
pub(crate) use shares::read_share_views;
pub use shares::ShareView;
pub struct Archive<D> {
	client: Client<D>,
	reference: Ref,
}
impl<D: Deadline> Archive<D> {
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self { client, reference }
	}
	pub async fn put(&self, record: &Record) -> Result<u64, Error> {
		let pending = {
			let args = [wire::record_row(record)];
			self.client
				.call(&self.reference, protocol::PUT, &args, "the archive did not answer put")
		};
		let reply = pending.await?;
		acknowledgement(&reply.0)
	}
	pub async fn read(&self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		if SafeInteger::<false>::new(after).is_none() || limit == 0 {
			return Err(archive::Error::Page.into());
		}
		let limit = limit.min(archive::MAX_READ);
		let pending = {
			let args = [
				wire::filter_row(filter)?,
				Argument::Integer(after as i64),
				Argument::Integer(limit as i64),
			];
			self.client.call(
				&self.reference,
				protocol::READ,
				&args,
				"the archive did not answer read",
			)
		};
		let reply = pending.await?;
		Ok(protocol::page(&Value(&reply.0), filter, after, limit)?)
	}
	/// Charge every remote row, including repeated keys, and expose only a
	/// complete account. A peer cannot keep this scan alive by revising one key.
	pub async fn read_all(&self, filter: &Filter) -> Result<Vec<Arc<archive::index::Entry>>, Error> {
		let mut scan = archive::index::Scan::new(filter.clone())?;
		while !scan.is_complete() {
			let page = self.read(scan.filter(), scan.after(), archive::MAX_READ).await?;
			scan.push(page)?;
		}
		Ok(scan.finish()?)
	}
	pub async fn narrow(&self, filter: &Filter, access: Access) -> Result<Self, Error>
	where
		D: Clone,
	{
		let pending = {
			let args = [
				wire::filter_row(filter)?,
				match access {
					Access::Read => "read".into(),
					Access::ReadWrite => "read-write".into(),
				},
			];
			self.client.call(
				&self.reference,
				protocol::NARROW,
				&args,
				"the archive did not answer narrow",
			)
		};
		let reply = pending.await?;
		let Argument::Reference(reference) = reply.0 else {
			return Err(archive::Error::Access.into());
		};
		Ok(Self::new(self.client.clone(), reference))
	}
}

fn acknowledgement(reply: &Argument) -> Result<u64, Error> {
	use rooms_application::room::ArgumentView;
	Value(reply)
		.integer()
		.and_then(|n| u64::try_from(n).ok())
		.and_then(SafeInteger::<true>::new)
		.map(|revision| revision.get())
		.ok_or_else(|| archive::Error::Revision.into())
}
