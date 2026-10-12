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

/// Why a gateway description is refused. `Display` is the exact line the
/// bridge reports.
#[derive(Debug)]
pub enum Invalid {
	/// The description could not be written as JSON, with the serializer's text.
	Encode(serde_json::Error),
	/// The description is over the size limit.
	DescriptionTooLong,
	/// The bridge answered no description.
	NoDescription,
	/// The bridge answered a description over the size limit.
	AnswerTooLong,
	/// The bridge answered a description that does not parse.
	AnswerInvalid,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Encode(source) => write!(f, "{source}"),
			Self::DescriptionTooLong => f.write_str("the bridge gateway description is too long"),
			Self::NoDescription => f.write_str("the bridge gateway answered no description"),
			Self::AnswerTooLong => f.write_str("the bridge gateway answered too long a description"),
			Self::AnswerInvalid => f.write_str("the bridge gateway answered an invalid description"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

impl Description {
	pub fn encode(&self) -> Result<String, Invalid> {
		let raw = serde_json::to_string(self).map_err(Invalid::Encode)?;
		if raw.len() > MAX_GATEWAY_JSON {
			return Err(Invalid::DescriptionTooLong);
		}
		Ok(raw)
	}
	pub fn decode(raw: &str) -> Result<Self, Invalid> {
		if raw.is_empty() {
			return Err(Invalid::NoDescription);
		}
		if raw.len() > MAX_GATEWAY_JSON {
			return Err(Invalid::AnswerTooLong);
		}
		crate::fields::json_object(raw).map_err(|_| Invalid::AnswerInvalid)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::DescriptionTooLong,
				"the bridge gateway description is too long",
			),
			(Invalid::NoDescription, "the bridge gateway answered no description"),
			(
				Invalid::AnswerTooLong,
				"the bridge gateway answered too long a description",
			),
			(
				Invalid::AnswerInvalid,
				"the bridge gateway answered an invalid description",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
