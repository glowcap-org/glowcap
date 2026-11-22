//! `session access`: hand out and manage access to a running session from a
//! terminal. The running session does the work over its control socket: it
//! issues with its own management control and keeps each access's control in
//! the same workspace rows the page keeps its controls in, so the terminal
//! and the page list and change one set. An access is named by the id `list`
//! shows. The link of a new access is printed once, in the result, and
//! appears nowhere else.
use super::{Failure, Options, operation, request};
use rooms_services::session::{attached::Lifecycle, control::rights};
use serde_json::{Value, json};

/// What the operator asked for, checked before the session is asked.
enum Action {
	Issue {
		id: Option<String>,
		label: String,
		rights: String,
	},
	List,
	Change {
		id: String,
		change: Lifecycle,
	},
	Forget(String),
}

impl Action {
	fn read(options: &Options) -> Result<Self, Failure> {
		let allowed: &[&str] = match options.verb.as_str() {
			"access-issue" => &["id", "label", "rights"],
			"access-list" => &[],
			"access-pause" | "access-resume" | "access-revoke" | "access-forget" => &["id"],
			_ => return Err(Failure::invalid("unknown access command")),
		};
		if let Some(key) = options.named.keys().find(|key| !allowed.contains(&key.as_str())) {
			return Err(Failure::invalid(format!("{} does not take --{key}", options.verb)));
		}
		if !options.arguments.is_empty() {
			return Err(Failure::invalid(format!(
				"{} takes no positional arguments",
				options.verb
			)));
		}
		let single = |key: &str| -> Result<String, Failure> {
			match options.values(key).as_slice() {
				[value] if !value.is_empty() => Ok(value.clone()),
				[] => Err(Failure::invalid(format!("--{key} is required"))),
				_ => Err(Failure::invalid(format!("--{key} needs one value"))),
			}
		};
		let change = |change| {
			Ok::<_, Failure>(Self::Change {
				id: single("id")?,
				change,
			})
		};
		match options.verb.as_str() {
			"access-issue" => {
				let rights_name = single("rights")?;
				rights(&rights_name).map_err(Failure::invalid)?;
				let id = match options.values("id").as_slice() {
					[] => None,
					_ => Some(single("id")?),
				};
				Ok(Self::Issue {
					id,
					label: single("label")?,
					rights: rights_name,
				})
			}
			"access-list" => Ok(Self::List),
			"access-pause" => change(Lifecycle::Pause),
			"access-resume" => change(Lifecycle::Resume),
			"access-revoke" => change(Lifecycle::Revoke),
			_ => Ok(Self::Forget(single("id")?)),
		}
	}

	fn body(self) -> Result<Value, Failure> {
		Ok(match self {
			Self::Issue { id, label, rights } => {
				let id = match id {
					Some(id) => id,
					None => operation()?,
				};
				json!({"verb": "access-issue", "id": id, "label": label, "rights": rights})
			}
			Self::List => json!({"verb": "access-list"}),
			Self::Change { id, change } => json!({"verb": "access-change", "id": id, "change": change}),
			Self::Forget(id) => json!({"verb": "access-forget", "id": id}),
		})
	}
}

pub async fn run(options: &Options) -> Result<Value, Failure> {
	let body = Action::read(options)?.body()?;
	if !options.state.join("control.sock").exists() {
		return Err(Failure::invalid(format!(
			"no session is running in {}. Start it with session start, then try again",
			options.state.display()
		)));
	}
	request(&options.state, body).await
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::content::permissions::Permission;

	fn request(verb: &str, named: Value) -> Options {
		serde_json::from_value(json!({"verb": verb, "state": "/s", "named": named, "arguments": []})).unwrap()
	}

	#[test]
	fn rights_names_map_to_the_application_presets_and_nothing_else() {
		let observer = rights("observer").unwrap();
		assert_eq!(observer.permissions(), [Permission::ObserveWorkspace]);
		let collaborator = rights("collaborator").unwrap();
		assert!(collaborator.permissions().contains(&Permission::InteractWorkspace));
		assert!(!collaborator.permissions().contains(&Permission::ManageCustody));
		let administrator = rights("administrator").unwrap();
		assert!(administrator.permissions().contains(&Permission::InteractWorkspace));
		assert!(administrator.permissions().contains(&Permission::ManageCustody));
		for refused in ["Observer", "admin", "none", "", "observer,collaborator", " observer"] {
			assert!(rights(refused).is_err(), "{refused:?}");
		}
	}

	#[test]
	fn a_command_is_checked_before_the_session_is_asked() {
		let issue = Action::read(&request(
			"access-issue",
			json!({"label": ["bot"], "rights": ["observer"]}),
		))
		.and_then(Action::body)
		.unwrap();
		assert_eq!(issue["rights"], "observer");
		assert_eq!(issue["id"].as_str().map(str::len), Some(32));
		let again = Action::read(&request(
			"access-issue",
			json!({"id": ["a1"], "label": ["bot"], "rights": ["observer"]}),
		))
		.and_then(Action::body)
		.unwrap();
		assert_eq!(again["id"], "a1", "an issue to finish did not keep its id");
		let revoke = Action::read(&request("access-revoke", json!({"id": ["r1"]})))
			.and_then(Action::body)
			.unwrap();
		assert_eq!(revoke, json!({"verb": "access-change", "id": "r1", "change": "revoke"}));
		for (verb, named) in [
			("access-issue", json!({"label": ["bot"]})),
			("access-issue", json!({"rights": ["observer"]})),
			("access-issue", json!({"label": [""], "rights": ["observer"]})),
			("access-issue", json!({"label": ["a", "b"], "rights": ["observer"]})),
			("access-issue", json!({"label": ["a"], "rights": ["owner"]})),
			(
				"access-issue",
				json!({"id": [""], "label": ["a"], "rights": ["observer"]}),
			),
			("access-list", json!({"id": ["x"]})),
			("access-pause", json!({})),
			("access-pause", json!({"name": ["x"]})),
			("access-revoke", json!({"id": ["x"], "label": ["y"]})),
			("access-forget", json!({})),
			("access-unknown", json!({})),
		] {
			assert!(Action::read(&request(verb, named.clone())).is_err(), "{verb} {named}");
		}
	}
}
