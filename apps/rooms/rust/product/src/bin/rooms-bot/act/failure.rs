//! An action verb's failure as the JSON a harness reads: the same
//! `{"ok":false,"error":{class,retry,message}}` shape `rooms-session` prints,
//! with the operation and base added when the write may have landed, so the
//! caller can observe it instead of sending it again.
use super::super::{error::Error, rooms::captp::Failure as Dialing};
use rooms_application::failure::Retry;
use rooms_services::session::{attached, control::Failure};
use serde_json::{Value, json};

fn action(failure: &Failure, extra: Option<(&str, u64)>) -> Error {
	let mut response = failure.response();
	if let (Some((name, value)), Some(error)) = (extra, response.get_mut("error").and_then(Value::as_object_mut)) {
		error.insert(name.into(), json!(value));
	}
	Error::Action {
		response,
		message: failure.message.clone(),
	}
}

/// A failed view call. An uncertain write names its base.
pub fn call(cause: &attached::Error) -> Error {
	let extra = match cause {
		attached::Error::Uncertain { base, .. } => Some(("base", *base)),
		_ => None,
	};
	action(&Failure::from(cause), extra)
}

/// A failed view call whose write no verb can look at again, so it names
/// neither operation nor base.
pub fn unobservable(cause: &attached::Error) -> Error {
	action(&Failure::from(cause), None)
}

/// A failed attach.
pub fn attach(cause: &Dialing) -> Error {
	match cause {
		Dialing::Attach(cause) => call(cause),
		Dialing::Platform(_) => action(&Failure::new("system", Retry::Soon, cause), None),
	}
}

/// A write the session settled without applying it.
pub fn unapplied(status: &str) -> Error {
	let message = format!("the session did not apply the command: {status}");
	action(&Failure::new(status, Retry::AfterStateChange, message), None)
}

/// An uncertain write's operation, added to the failure so it can be observed.
pub fn with_operation(error: Error, operation: &str) -> Error {
	match error {
		Error::Action { mut response, message } => {
			if let Some(object) = response.get_mut("error").and_then(Value::as_object_mut) {
				object.insert("operation".into(), json!(operation));
			}
			Error::Action { response, message }
		}
		other => other,
	}
}
