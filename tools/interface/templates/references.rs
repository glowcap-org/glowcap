use glowcap::{AsSendTarget, Session};

/// A borrowed reference argument, lowered synchronously before the send returns.
/// It never owns an independent pending reference across a suspension.
pub enum Reference<'a> {
	Target(&'a Ref),
	Pending(&'a RemotePromise),
}
impl<'a> From<&'a Ref> for Reference<'a> {
	fn from(value: &'a Ref) -> Self {
		Self::Target(value)
	}
}
impl<'a> From<&'a RemotePromise> for Reference<'a> {
	fn from(value: &'a RemotePromise) -> Self {
		Self::Pending(value)
	}
}
impl Reference<'_> {
	fn argument(self) -> Argument {
		match self {
			Self::Target(value) => value.into(),
			Self::Pending(value) => value.into(),
		}
	}
}
fn text(value: Argument) -> Result<String, Error> {
	if let Argument::String(text) = value {
		Ok(text)
	} else {
		Err(Error::InvalidReply)
	}
}
fn nothing(value: Argument) -> Result<(), Error> {
	if matches!(value, Argument::Void) {
		Ok(())
	} else {
		Err(Error::InvalidReply)
	}
}
