use rooms_glowcap::client;
use std::{fmt, io};

#[derive(Debug)]
pub enum Error {
	Rooms(client::Error),
	Channel(io::Error),
	Binding(glowcap::Error),
	Timeout,
	Stopped,
	Admission(&'static str),
	Cleanup { primary: Box<Self>, cleanup: Box<Self> },
}
impl Error {
	pub(super) fn retain(self, cleanup: Result<(), Self>) -> Self {
		match cleanup {
			Ok(()) => self,
			Err(cleanup) => Self::Cleanup {
				primary: Box::new(self),
				cleanup: Box::new(cleanup),
			},
		}
	}
}
impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Rooms(e) => e.fmt(f),
			Self::Channel(e) => e.fmt(f),
			Self::Binding(e) => e.fmt(f),
			Self::Timeout => f.write_str("Rooms WebRTC signaling timed out"),
			Self::Stopped => f.write_str("Rooms WebRTC signaling stopped"),
			Self::Admission(reason) => f.write_str(reason),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; cleanup failed: {cleanup}"),
		}
	}
}
impl std::error::Error for Error {}
impl From<client::Error> for Error {
	fn from(e: client::Error) -> Self {
		Self::Rooms(e)
	}
}
impl From<rooms_application::signaling::Error> for Error {
	fn from(e: rooms_application::signaling::Error) -> Self {
		Self::Rooms(e.into())
	}
}
impl From<io::Error> for Error {
	fn from(e: io::Error) -> Self {
		Self::Channel(e)
	}
}
impl From<glowcap::Error> for Error {
	fn from(e: glowcap::Error) -> Self {
		Self::Binding(e)
	}
}
