//! Attached-session rendering through the shared application response readers.
use crate::service::error::Error;
use glowcap::Argument;
use rooms_application::server::operations::operator::view;
use rooms_glowcap::Value;

pub fn snapshot(reply: &Argument) -> Result<String, Error> {
	view::read_snapshot(&Value(reply))
		.and_then(|snapshot| snapshot.encode())
		.map_err(invalid)
}
fn invalid(error: view::Refusal) -> Error {
	Error::invalid_by(error)
}
