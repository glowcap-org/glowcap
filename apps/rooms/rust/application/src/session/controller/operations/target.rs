//! Capture the authority selected by a gesture, without exposing its bearer.
use super::Kind;
use crate::{
	grants::Access,
	session::{checkpoint::OperationCredential, snapshot::Snapshot},
};
use alloc::string::String;

pub struct Target {
	kind: Kind,
	scope: String,
	swiss: String,
}
pub(super) fn selected(snapshot: &Snapshot, kind: Kind) -> Option<OperationCredential<'_>> {
	let home = snapshot
		.checkpoint
		.directories()
		.find(|directory| directory.home)
		.and_then(|directory| directory.id.text().as_str());
	snapshot
		.checkpoint
		.operations()
		.find(|credential| {
			credential.capability == kind.name()
				&& (matches!(kind.name(), "viz" | "peering") || Some(credential.scope) == home)
		})
		.filter(|_| snapshot.access != Access::None)
}
impl Target {
	pub fn select(snapshot: &Snapshot, kind: Kind) -> Result<Self, &'static str> {
		if snapshot.access != Access::Admin {
			return Err("Rooms operations require administrator access");
		}
		let credential =
			selected(snapshot, kind).ok_or("This session does not hold the selected operations capability")?;
		Ok(Self {
			kind,
			scope: credential.scope.into(),
			swiss: credential.swiss.into(),
		})
	}
	pub fn scope(&self) -> &str {
		&self.scope
	}
	/// Build the command from the admitted target and presentation values.
	pub fn command(
		&self,
		snapshot: &Snapshot,
		id: &str,
		action: &str,
		args: &[String],
	) -> Result<(&'static str, alloc::vec::Vec<String>), &'static str> {
		self.check(snapshot)?;
		if self.kind.name() == "peering" {
			return match (action, args) {
				("publish", [source, name]) => {
					if !snapshot
						.checkpoint
						.rooms()
						.any(|room| room.id.text().as_str() == Some(source))
					{
						return Err("That room is no longer available");
					}
					#[derive(serde::Serialize)]
					struct Publication<'a> {
						id: &'a str,
						destination: &'a str,
						source: &'a str,
						name: &'a str,
					}
					let intent = serde_json::to_string(&Publication {
						id,
						destination: self.scope(),
						source,
						name,
					})
					.map_err(|_| "Could not encode the peering publication")?;
					Ok(("publishPeeredRoom", alloc::vec![intent]))
				}
				_ => Err("Invalid Rooms peering action"),
			};
		}
		let mut command = alloc::vec![self.scope.clone()];
		let name = if self.kind.name() == "operator" {
			"operator"
		} else {
			command.push(self.kind.name().into());
			"operations"
		};
		command.push(action.into());
		command.extend_from_slice(args);
		Ok((name, command))
	}
	/// Recheck before each issue, including retries following a stale revision.
	pub fn check(&self, snapshot: &Snapshot) -> Result<(), &'static str> {
		if snapshot.access == Access::Admin
			&& selected(snapshot, self.kind)
				.is_some_and(|credential| credential.scope == self.scope && credential.swiss == self.swiss)
		{
			Ok(())
		} else {
			Err("Rooms operations authority changed; repeat the action against the current view")
		}
	}
}
