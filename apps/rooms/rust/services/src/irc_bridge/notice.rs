//! Operator-facing events emitted by the IRC bridge library.
use std::{fmt, rc::Rc};

#[derive(Debug)]
pub enum Notice {
	AcceptRefused(String),
	ConnectionEnded(String),
	ReleaseFailed(String),
	DeliveryFailed(String),
	AnswerFailed(String),
	Reconnecting(String),
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::AcceptRefused(cause) => write!(f, "accept refused: {cause}"),
			Self::ConnectionEnded(cause) => write!(f, "connection ended: {cause}"),
			Self::ReleaseFailed(cause) => write!(f, "capability release failed: {cause}"),
			Self::DeliveryFailed(cause) => write!(f, "subscriber delivery failed: {cause}"),
			Self::AnswerFailed(cause) => write!(f, "post answer failed: {cause}"),
			Self::Reconnecting(cause) => write!(f, "{cause}; reconnecting"),
		}
	}
}

pub type Report = Rc<dyn Fn(Notice)>;
