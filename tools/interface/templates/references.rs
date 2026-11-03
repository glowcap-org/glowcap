use glowcap::AsSendTarget;

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

// Presence is fixed stack scratch. A missing optional argument ends the supplied
// prefix; a later Some is refused before arguments acquire wire custody.
fn optional_argument_count(present: &[bool]) -> Result<usize, Error> {
	let count = present.iter().take_while(|value| **value).count();
	if present[count..].iter().any(|value| *value) {
		return Err(Error::InvalidArgument);
	}
	Ok(count)
}
