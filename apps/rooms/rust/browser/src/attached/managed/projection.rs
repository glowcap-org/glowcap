//! Descriptive metadata borrows shared replies and preserves exact revisions.
use glowcap::loam::{AccessStatus, ControlDescription, GrantDescription, PolicyDescription, UseDescription};
use rooms_application::content::permissions::Permission;
use serde_json::{Value, json};
pub fn status(status: AccessStatus) -> &'static str {
	match status {
		AccessStatus::Active => "active",
		AccessStatus::Paused => "paused",
		AccessStatus::Revoked => "revoked",
	}
}
pub fn policy(policy: PolicyDescription<'_>) -> Value {
	json!({
		"permissions": policy.permissions().map(|key| Permission::from_key(key).map_or_else(|| json!({"unsupportedKey": key.to_string()}), |permission| json!(permission))).collect::<Vec<_>>(),
		"bounds": policy.bounds().map(|bound| json!({"key": bound.key.to_string(), "operator": format!("{:?}", bound.operator), "value": bound.value.to_string()})).collect::<Vec<_>>()
	})
}
pub fn control(description: ControlDescription<'_>) -> Value {
	match description {
		ControlDescription::Unavailable => json!({ "available": false }),
		ControlDescription::Available(view) => json!({
			"available": true, "status": status(view.status), "revision": view.revision.to_string(),
			"inspect": view.inspect, "pause": view.pause, "resume": view.resume, "revoke": view.revoke,
			"delegateControl": view.delegate_control, "subtree": view.subtree,
			"editCeiling": view.edit_ceiling.map(policy), "issueCeiling": view.issue_ceiling.map(policy),
		}),
	}
}
pub fn grant(view: GrantDescription<'_>) -> Value {
	json!({
		"slot": view.slot, "generation": view.generation.to_string(), "revision": view.revision.to_string(),
		"label": view.label, "status": status(view.status), "effectiveStatus": status(view.effective_status),
		"ceiling": policy(view.ceiling), "configured": policy(view.configured), "delegationDepth": view.delegation_depth,
	})
}
pub fn use_access(view: UseDescription<'_>) -> Value {
	match view {
		UseDescription::Active(active) => json!({
			"status": "active", "effective": policy(active.effective),
			"configured": policy(active.configured), "ceiling": policy(active.ceiling),
			"delegationDepth": active.delegation_depth,
		}),
		UseDescription::Paused => json!({"status": "paused"}),
		UseDescription::Revoked => json!({"status": "revoked"}),
		UseDescription::OutOfScope => json!({"status": "outOfScope"}),
	}
}
