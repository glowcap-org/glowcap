/// A borrowed reference argument, lowered synchronously before the send returns.
/// Receipt preparation retains it independently before acquiring a sequence.
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
