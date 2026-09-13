use super::*;
use rooms_application::archive::shares::{self, Share, protocol as share_protocol};
pub struct ShareView {
	pub share: Share,
	pub sturdyref: String,
}
impl<D: Deadline> Archive<D> {
	pub async fn share(&self, spec: &Share) -> Result<String, Error> {
		spec.validate()?;
		if spec.revoked() {
			return Err(shares::Error::Revoked.into());
		}
		let args = wire::share_issue(spec)?;
		let reply = self
			.client
			.call(
				&self.reference,
				share_protocol::ISSUE,
				&args,
				"the archive did not answer share",
			)
			.await?;
		link(&reply.0)
	}
	pub async fn revoke_share(&self, id: &str) -> Result<bool, Error> {
		if id.len() > 128 {
			return Err(shares::Error::Invalid.into());
		}
		let reply = self
			.client
			.call(
				&self.reference,
				share_protocol::REVOKE,
				&[id.into()],
				"the archive did not answer revokeShare",
			)
			.await?;
		match reply.0 {
			Argument::Boolean(v) => Ok(v),
			_ => Err(shares::Error::Invalid.into()),
		}
	}
	pub async fn shares(&self) -> Result<Vec<ShareView>, Error> {
		let reply = self
			.client
			.call(
				&self.reference,
				share_protocol::LIST,
				&[],
				"the archive did not answer shares",
			)
			.await?;
		read_share_views(reply.0)
	}
}
pub(crate) fn read_share_views(reply: Argument) -> Result<Vec<ShareView>, Error> {
	let Argument::List(rows) = reply else {
		return Err(shares::Error::Invalid.into());
	};
	if rows.len() > shares::MAX_ACTIVE {
		return Err(shares::Error::Limit.into());
	}
	let mut views = Vec::with_capacity(rows.len());
	let mut ids = std::collections::BTreeSet::new();
	for row in rows {
		let Argument::List(row) = row else {
			return Err(shares::Error::Invalid.into());
		};
		if row.len() != 4 {
			return Err(shares::Error::Invalid.into());
		}
		let share_protocol::Request::Issue(share) =
			share_protocol::Request::read(share_protocol::ISSUE, &[Value(&row[0]), Value(&row[1]), Value(&row[2])])?
		else {
			unreachable!("issue parser")
		};
		if !ids.insert(share.id().to_owned()) {
			return Err(shares::Error::Invalid.into());
		}
		views.push(ShareView {
			share,
			sturdyref: link(&row[3])?,
		});
	}
	Ok(views)
}

fn link(value: &Argument) -> Result<String, Error> {
	let text = value.as_str().ok_or(shares::Error::Invalid)?;
	if text.encode_utf16().take(16 * 1024 + 1).count() > 16 * 1024 {
		return Err(shares::Error::Limit.into());
	}
	glowcap::parse_sturdyref(text, glowcap::CaptpVersion::V1_0)?;
	Ok(text.into())
}
