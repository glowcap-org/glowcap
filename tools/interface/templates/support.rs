#[derive(Debug)]
pub enum Error {
	InvalidArgument,
	InvalidSequence,
	InvalidReply,
	Runtime(glowcap::Error),
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::InvalidArgument => f.write_str("an argument is outside the bounds the interface declares"),
			Self::InvalidSequence => f.write_str("the target returned no positive mutation sequence"),
			Self::InvalidReply => f.write_str("the reply does not have the type the interface declares"),
			Self::Runtime(error) => error.fmt(f),
		}
	}
}
impl std::error::Error for Error {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		match self {
			Self::Runtime(error) => Some(error),
			_ => None,
		}
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Runtime(error)
	}
}
