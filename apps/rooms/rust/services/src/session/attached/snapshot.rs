//! The revision and posting authority a caller checks before writing.
use super::*;

pub(super) type Check = Box<dyn Fn(&Snapshot) -> bool>;

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// The session's current revision, the base a command is sent at.
	pub async fn revision(&self) -> Result<u64, Error> {
		Ok(self.snapshot().await?.revision)
	}
	/// Read through an active posting grant. Admission checks the grant and
	/// workspace revision again before a post reaches the conversation.
	pub async fn posting_snapshot(&self) -> Result<Snapshot, Error> {
		use rooms_application::content::permissions::Permission;
		let access = self.workspace.describe_access().await.map_err(link::failure)?;
		match access.view() {
			UseDescription::Active(active)
				if active
					.effective
					.permissions()
					.any(|key| key == Permission::InteractWorkspace.key()) =>
			{
				self.snapshot().await
			}
			UseDescription::Paused => Err(Error::Paused),
			UseDescription::Revoked => Err(Error::Revoked),
			_ => Err(Error::Refused),
		}
	}
	/// Restrict the snapshots this attachment uses to select routes and author
	/// commands. A change after a checked read is fenced by the command's base.
	pub fn require_snapshot(&self, accepts: impl Fn(&Snapshot) -> bool + 'static) {
		self.snapshot_checks.borrow_mut().push(Box::new(accepts));
	}
	/// The session's workspace as it is now, with the revision it was read at.
	pub async fn snapshot(&self) -> Result<Snapshot, Error> {
		match self.workspace.snapshot().await {
			Ok(snapshot) if self.snapshot_checks.borrow().iter().any(|accepts| !accepts(&snapshot)) => {
				Err(Error::Refused)
			}
			Ok(snapshot) => Ok(snapshot),
			Err(error) => Err(self.failure(error).await),
		}
	}
}
