#[derive(Debug)]
pub enum Error {
	Client(super::super::Error),
	Snapshot(rooms_application::session::snapshot::Refusal),
	Input(rooms_application::session::command::Refusal),
	Grant(rooms_application::grants::protocol::Refusal),
	Operator(rooms_application::server::operations::operator::view::Refusal),
	Reply(&'static str),
}
impl From<super::super::Error> for Error {
	fn from(value: super::super::Error) -> Self {
		Self::Client(value)
	}
}
impl From<rooms_application::server::operations::operator::view::Refusal> for Error {
	fn from(value: rooms_application::server::operations::operator::view::Refusal) -> Self {
		Self::Operator(value)
	}
}
impl From<rooms_application::session::snapshot::Refusal> for Error {
	fn from(value: rooms_application::session::snapshot::Refusal) -> Self {
		Self::Snapshot(value)
	}
}
impl From<rooms_application::session::command::Refusal> for Error {
	fn from(value: rooms_application::session::command::Refusal) -> Self {
		Self::Input(value)
	}
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Client(e) => e.fmt(f),
			Self::Snapshot(e) => e.fmt(f),
			Self::Input(e) => e.fmt(f),
			Self::Grant(e) => e.fmt(f),
			Self::Operator(e) => e.fmt(f),
			Self::Reply(e) => f.write_str(e),
		}
	}
}
impl core::error::Error for Error {}
