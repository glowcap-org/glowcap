//! Issuer authority is held explicitly. Descendants retain revocation, never
//! the power to mint durable shares, even when their scope equals the root.
use super::*;
#[derive(Clone, Default)]
pub(super) enum Authority {
	#[default]
	Ordinary,
	Issuer,
	Shared {
		active: Rc<Cell<bool>>,
		ready: Rc<Cell<bool>>,
	},
}
impl Authority {
	pub(super) fn check(&self) -> Result<(), Error> {
		match self {
			Self::Shared { active, .. } if !active.get() => Err(Error::refused("archive share has been revoked")),
			Self::Shared { ready, .. } if !ready.get() => {
				Err(Error::closed("archive share publications are unavailable"))
			}
			_ => Ok(()),
		}
	}
	pub(super) fn descendant(&self) -> Self {
		match self {
			Self::Issuer => Self::Ordinary,
			other => other.clone(),
		}
	}
	pub(super) fn issuer(&self) -> bool {
		matches!(self, Self::Issuer)
	}
}
