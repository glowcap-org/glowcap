//! Operator-facing events emitted by the IRC client front.
use std::{fmt, rc::Rc};

#[derive(Debug)]
pub enum Notice {
	AcceptRefused { listener: &'static str, cause: String },
	ClientEnded(String),
	InboxEnded(String),
	DirectAcknowledgementFailed(String),
	DirectMessageRefused(String),
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::AcceptRefused { listener, cause } => {
				write!(f, "{listener} accept refused, retrying: {cause}")
			}
			Self::ClientEnded(cause) => write!(f, "client ended: {cause}"),
			Self::InboxEnded(cause) => write!(f, "inbox connection ended: {cause}"),
			Self::DirectAcknowledgementFailed(cause) => {
				write!(f, "direct acknowledgement failed: {cause}")
			}
			Self::DirectMessageRefused(cause) => write!(f, "direct message refused: {cause}"),
		}
	}
}

pub type Report = Rc<dyn Fn(Notice)>;
