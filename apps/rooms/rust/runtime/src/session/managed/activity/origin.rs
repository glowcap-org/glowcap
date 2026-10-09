//! Presentation follows the original callback or the private authored line.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

pub enum Origin {
	Inbox(InboxOrigin),
	Outgoing {
		source: Ref,
		line: custody::FieldKey<custody::Line>,
	},
	Archive {
		source: Ref,
		archive: custody::FieldKey<custody::ArchiveAccess>,
	},
}
impl From<InboxOrigin> for Origin {
	fn from(origin: InboxOrigin) -> Self {
		Self::Inbox(origin)
	}
}
impl Origin {
	pub fn source(&self) -> &Ref {
		match self {
			Self::Inbox(origin) => origin.source(),
			Self::Outgoing { source, .. } | Self::Archive { source, .. } => source,
		}
	}
	pub fn is_open(&self) -> bool {
		match self {
			Self::Inbox(origin) => origin.is_open(),
			Self::Outgoing { .. } | Self::Archive { .. } => true,
		}
	}
	pub(in crate::session::managed) fn installed(
		&self,
	) -> Option<(&rooms_application::content::session::workspace::InboxSelection, &Ref)> {
		match self {
			Self::Inbox(origin) => origin.installed(),
			Self::Outgoing { .. } | Self::Archive { .. } => None,
		}
	}
	pub async fn check<P: Deadline + Clone>(&self, host: &glowcap::Host, platform: P) -> Result<()> {
		if self.admitted(host, platform).await? {
			Ok(())
		} else {
			Err(loam::refusal("original activity source is unavailable"))
		}
	}
	pub(super) async fn admitted<P: Deadline + Clone>(&self, host: &glowcap::Host, platform: P) -> Result<bool> {
		if let Self::Archive { source, archive } = self {
			let workspace = Workspace::local(host.clone(), platform, source.clone());
			return workspace
				.snapshot()
				.await
				.map(|snapshot| snapshot.intent.archive == Some(*archive))
				.map_err(|error| loam::refusal(error.to_string()));
		}
		let Self::Outgoing { source, line } = self else {
			let Self::Inbox(origin) = self else { unreachable!() };
			return origin.admitted(host, platform).await;
		};
		let workspace = Workspace::local(host.clone(), platform, source.clone());
		match workspace.check_outgoing_line(*line).await {
			Ok(()) => Ok(true),
			Err(rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error))
				if error.kind() == glowcap::ErrorKind::Broken =>
			{
				Ok(false)
			}
			Err(error) => Err(loam::refusal(error.to_string())),
		}
	}
}
