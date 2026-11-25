//! An action verb's failure as the JSON a harness reads: the same
//! `{"ok":false,"error":{class,retry,message}}` shape `rooms-session` prints,
//! with the operation and base added when the write may have landed, so the
//! caller can observe it instead of sending it again.
use super::super::{error::Error, rooms::captp::Failure as Dialing};
use rooms_application::failure::Retry;
use rooms_services::session::{
	attached,
	control::{CONFLICT, Failure},
};
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

/// A failed view call whose write no verb can look at again, or that sent
/// nothing, so it names neither operation nor base.
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

/// A failure the verb names itself.
pub fn refused(failure: &Failure) -> Error {
	action(failure, None)
}

/// A verb whose budget ended before anything reached the session.
pub fn nothing_sent() -> Error {
	action(
		&Failure::new(
			"unreachable",
			Retry::Soon,
			"this command's time ran out before it reached the session: nothing was sent",
		),
		None,
	)
}

/// A `--dm` open the verb's budget ended. The open may have started, and the
/// bot settles it. The post that followed it was never sent.
pub fn open_spent() -> Error {
	action(
		&Failure::uncertain(
			"this command's time ran out while it reached the conversation: the open may or may not have happened and the bot settles it, and no line was sent. Do not open it again in this turn",
		),
		None,
	)
}

/// A write the session had not settled by the bound, which may still apply.
/// It names its base so the same operation can be sent again there.
pub fn unsettled(sent: &attached::Sent) -> Error {
	let message = format!("the session had not settled the command: {}", sent.status.wire());
	action(
		&Failure::new("uncertain", Retry::AfterStateChange, message),
		Some(("base", sent.base)),
	)
}

/// A write the session settled without applying it.
pub fn unapplied(status: &str) -> Error {
	let message = format!("the session did not apply the command: {status}");
	action(&Failure::new(status, Retry::AfterStateChange, message), None)
}

/// Whether `error` is the session's answer that the write was not applied
/// because the workspace moved under its base, which committed nothing.
pub fn is_conflict(error: &Error) -> bool {
	matches!(error, Error::Action { response, .. } if response["error"]["class"] == CONFLICT && response["error"]["settling"].is_null())
}

/// An uncertain write's operation, added to the failure so it can be observed.
pub fn with_operation(error: Error, operation: &str) -> Error {
	with(error, "operation", json!(operation))
}

/// A failure with `name` added to what it prints, such as the `settling`
/// mark of an action whose receipt the bot settles, so nothing is sent again.
pub fn marked(error: Error, name: &str, value: Value) -> Error {
	with(error, name, value)
}

/// A failure of the open a `--dm` needed, marked so an agent can tell it
/// from a failure of the line that follows, which the open precedes.
pub fn opening(error: Error) -> Error {
	with(error, "opening", json!(true))
}

/// A failed post to the direct conversation a `--dm` reached. It names that
/// conversation and the open that made it, which stand whether or not the
/// line posted.
pub fn after_reaching(error: Error, conversation: &str, opened: &Value) -> Error {
	with(
		with(error, "conversation", json!(conversation)),
		"opened",
		opened.clone(),
	)
}

fn with(error: Error, name: &str, value: Value) -> Error {
	match error {
		Error::Action { mut response, message } => {
			if let Some(object) = response.get_mut("error").and_then(Value::as_object_mut) {
				object.insert(name.into(), value);
			}
			Error::Action { response, message }
		}
		other => other,
	}
}
