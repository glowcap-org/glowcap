//! The gateway a bridge declares to an operator. Forms, words and connection
//! descriptions are independent of the protocol the bridge serves.
use super::{Form, MAX_FORM_LABEL, MAX_FORM_SAID, MAX_FORM_TITLE, MAX_FORM_VALUE};
use crate::{
	fields::{List, Text},
	server::operations::MAX_OPERATIONS_ROWS,
};
use alloc::string::{String, ToString};
use serde::{Deserialize, Serialize};
pub const MAX_NAME: usize = 128;

/// The longest description a snapshot may carry.
pub const MAX_GATEWAY_JSON: usize = 256 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "lowercase")]
pub enum StatusTone {
	Ok,
	Pending,
	Failed,
	Idle,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Status {
	pub label: Text<MAX_FORM_LABEL, true>,
	pub tone: StatusTone,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fact {
	pub label: Text<MAX_FORM_LABEL, true>,
	pub value: Text<MAX_FORM_VALUE, true>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Lease {
	pub id: Text<MAX_NAME, true>,
	pub title: Text<MAX_NAME, true>,
	#[serde(deserialize_with = "crate::fields::object")]
	pub status: Status,
	pub problem: Text<MAX_FORM_SAID>,
	#[serde(deserialize_with = "crate::fields::required_nullable")]
	pub room_name: Option<Text<32, true>>,
	pub publication_id: Text<128>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
	pub id: Text<MAX_NAME, true>,
	pub title: Text<MAX_NAME, true>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub facts: List<Fact, 8>,
	#[serde(deserialize_with = "crate::fields::object")]
	pub status: Status,
	pub problem: Text<MAX_FORM_SAID>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub leases: List<Lease, MAX_OPERATIONS_ROWS>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LeaseRemoval {
	pub label: Text<MAX_FORM_LABEL, true>,
	pub say: Text<MAX_FORM_SAID, true>,
	pub keep: Text<MAX_FORM_LABEL, true>,
	pub commit: Text<MAX_FORM_LABEL, true>,
}

/// The whole gateway as its bridge describes it right now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Description {
	pub title: Text<MAX_FORM_TITLE, true>,
	pub description: Text<MAX_FORM_SAID>,
	pub connection_noun: Text<MAX_FORM_LABEL, true>,
	pub connection_noun_plural: Text<MAX_FORM_LABEL, true>,
	pub lease_noun: Text<MAX_FORM_LABEL, true>,
	pub lease_noun_plural: Text<MAX_FORM_LABEL, true>,
	#[serde(deserialize_with = "crate::fields::object")]
	pub lease_removal: LeaseRemoval,
	#[serde(deserialize_with = "crate::fields::object")]
	pub connection_form: Form,
	#[serde(deserialize_with = "crate::fields::object")]
	pub lease_form: Form,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub connections: List<Connection, MAX_OPERATIONS_ROWS>,
}

impl Description {
	pub fn encode(&self) -> Result<String, String> {
		let raw = serde_json::to_string(self).map_err(|e| e.to_string())?;
		if raw.len() > MAX_GATEWAY_JSON {
			return Err("the bridge gateway description is too long".into());
		}
		Ok(raw)
	}
	pub fn decode(raw: &str) -> Result<Self, String> {
		if raw.is_empty() {
			return Err("the bridge gateway answered no description".into());
		}
		if raw.len() > MAX_GATEWAY_JSON {
			return Err("the bridge gateway answered too long a description".into());
		}
		crate::fields::json_object(raw).map_err(|_| "the bridge gateway answered an invalid description".into())
	}
}
