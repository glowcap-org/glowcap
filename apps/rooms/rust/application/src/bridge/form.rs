//! Bridge forms declare bounded actions, fields, and nested disclosures.
use super::{
	Error, Id, MAX_ACTIONS, MAX_FIELDS, MAX_FORM_HINT, MAX_FORM_LABEL, MAX_FORM_SAID, MAX_FORM_SCOPE, MAX_FORM_TITLE,
	MAX_FORM_VALUE,
};
use crate::fields::{List, Text};
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Form {
	pub scope: Text<MAX_FORM_SCOPE, true>,
	pub title: Text<MAX_FORM_TITLE, true>,
	pub said: Text<MAX_FORM_SAID>,
	pub fields: List<Field, MAX_FIELDS>,
	#[serde(deserialize_with = "actions")]
	actions: List<Action, MAX_ACTIONS>,
}
impl Form {
	/// A form a bridge declares, refused when a bound does not hold or no
	/// action was given: a form with nothing to press asks for nothing.
	pub fn new(scope: &str, title: &str, said: &str, fields: Vec<Field>, actions: Vec<Action>) -> Result<Self, Error> {
		if actions.is_empty() {
			return Err(Error::Form);
		}
		Ok(Self {
			scope: Text::new(scope.into()).ok_or(Error::Form)?,
			title: Text::new(title.into()).ok_or(Error::Form)?,
			said: Text::new(said.into()).ok_or(Error::Form)?,
			fields: List::new(fields).ok_or(Error::Form)?,
			actions: List::new(actions).ok_or(Error::Form)?,
		})
	}
	pub fn decode(raw: &str) -> Result<Self, Error> {
		super::check_size(raw)?;
		serde_json::from_str(raw).map_err(|error| {
			if error.is_syntax() || error.is_eof() {
				Error::Json
			} else {
				Error::Form
			}
		})
	}
	pub fn actions(&self) -> &[Action] {
		self.actions.as_slice()
	}
	pub fn encode(&self) -> Result<alloc::string::String, Error> {
		let raw = serde_json::to_string(self).map_err(|_| Error::Form)?;
		super::check_size(&raw)?;
		Ok(raw)
	}
	/// Includes leaves behind disabled toggles. The declaration, independently
	/// of visibility, determines which identifiers can contain secrets.
	pub fn leaves(&self) -> impl Iterator<Item = LeafRef<'_>> {
		self.fields.as_slice().iter().flat_map(|field| {
			let (leaf, revealed) = match field {
				Field::Leaf(leaf) => (Some(leaf.as_ref()), [].as_slice()),
				Field::Toggle(toggle) => (None, toggle.reveals.as_slice()),
			};
			leaf.into_iter().chain(revealed.iter().map(Leaf::as_ref))
		})
	}
	pub fn has_secret(&self) -> bool {
		self.leaves().any(|leaf| leaf.secret())
	}
	pub fn is_secret(&self, id: &str) -> bool {
		self.leaves().any(|leaf| leaf.secret() && leaf.id() == id)
	}
}
fn actions<'de, D: serde::Deserializer<'de>>(d: D) -> Result<List<Action, MAX_ACTIONS>, D::Error> {
	let actions = List::<Action, MAX_ACTIONS>::deserialize(d)?;
	if actions.as_slice().is_empty() {
		return Err(serde::de::Error::custom("bridge form needs an action"));
	}
	Ok(actions)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Field {
	Leaf(Leaf),
	Toggle(ToggleField),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Leaf {
	Text(TextField),
	Secret(SecretField),
}

// Borrow raw JSON for tagged decoding. Serde's buffered enum representation
// cannot preserve the isolated UTF-16 surrogates that DocumentText admits.
#[derive(Deserialize)]
struct Tag {
	kind: alloc::string::String,
}
impl<'de> Deserialize<'de> for Field {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		let tag: Tag = serde_json::from_str(raw.get()).map_err(serde::de::Error::custom)?;
		if tag.kind == "toggle" {
			serde_json::from_str(raw.get())
				.map(Self::Toggle)
				.map_err(serde::de::Error::custom)
		} else {
			Leaf::read(raw.get(), &tag.kind)
				.map(Self::Leaf)
				.map_err(serde::de::Error::custom)
		}
	}
}
impl<'de> Deserialize<'de> for Leaf {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		let tag: Tag = serde_json::from_str(raw.get()).map_err(serde::de::Error::custom)?;
		Self::read(raw.get(), &tag.kind).map_err(serde::de::Error::custom)
	}
}
impl Leaf {
	fn read(raw: &str, kind: &str) -> Result<Self, serde_json::Error> {
		match kind {
			"text" => serde_json::from_str(raw).map(Self::Text),
			"secret" => serde_json::from_str(raw).map(Self::Secret),
			_ => Err(serde::de::Error::custom("bridge reveal must be a text or secret field")),
		}
	}
}
macro_rules! kind {
	($name:ident, $value:ident) => {
		#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
		#[serde(rename_all = "lowercase")]
		enum $name {
			$value,
		}
	};
}
kind!(TextKind, Text);
kind!(SecretKind, Secret);
kind!(ToggleKind, Toggle);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextField {
	kind: TextKind,
	pub id: Id,
	pub label: Text<MAX_FORM_LABEL, true>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub hint: Option<Text<MAX_FORM_HINT>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub placeholder: Option<Text<MAX_FORM_HINT>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub prefix: Option<Text<8, true>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub value: Option<Text<MAX_FORM_VALUE>>,
	pub required: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SecretField {
	kind: SecretKind,
	pub id: Id,
	pub label: Text<MAX_FORM_LABEL, true>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub hint: Option<Text<MAX_FORM_HINT>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub placeholder: Option<Text<MAX_FORM_HINT>>,
	pub required: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToggleField {
	kind: ToggleKind,
	pub id: Id,
	pub label: Text<MAX_FORM_LABEL, true>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub hint: Option<Text<MAX_FORM_HINT>>,
	pub on: bool,
	pub reveals: List<Leaf, MAX_FIELDS>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Action {
	pub id: Id,
	pub label: Text<MAX_FORM_LABEL, true>,
	pub busy_label: Text<MAX_FORM_LABEL, true>,
	pub tone: Tone,
	pub remembered: bool,
	#[serde(
		default,
		deserialize_with = "crate::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub confirm: Option<Confirm>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tone {
	Primary,
	Quiet,
	Danger,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Confirm {
	pub say: Text<MAX_FORM_SAID, true>,
	pub keep: Text<MAX_FORM_LABEL, true>,
	pub commit: Text<MAX_FORM_LABEL, true>,
}

/// The optional texts a text field may carry beside its label.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TextOptions<'a> {
	pub hint: Option<&'a str>,
	pub placeholder: Option<&'a str>,
	pub prefix: Option<&'a str>,
	pub value: Option<&'a str>,
}

impl TextField {
	pub fn new(id: &str, label: &str, required: bool, options: TextOptions<'_>) -> Result<Self, Error> {
		let bounded = |value: Option<&str>| -> Result<Option<Text<MAX_FORM_HINT>>, Error> {
			value.map(|v| Text::new(v.into()).ok_or(Error::Form)).transpose()
		};
		Ok(Self {
			kind: TextKind::Text,
			id: Id::new(id.into()).ok_or(Error::Form)?,
			label: Text::new(label.into()).ok_or(Error::Form)?,
			hint: bounded(options.hint)?,
			placeholder: bounded(options.placeholder)?,
			prefix: options
				.prefix
				.map(|v| Text::new(v.into()).ok_or(Error::Form))
				.transpose()?,
			value: options
				.value
				.map(|v| Text::new(v.into()).ok_or(Error::Form))
				.transpose()?,
			required,
		})
	}
}
impl SecretField {
	pub fn new(id: &str, label: &str, required: bool, placeholder: Option<&str>) -> Result<Self, Error> {
		Ok(Self {
			kind: SecretKind::Secret,
			id: Id::new(id.into()).ok_or(Error::Form)?,
			label: Text::new(label.into()).ok_or(Error::Form)?,
			hint: None,
			placeholder: placeholder
				.map(|v| Text::new(v.into()).ok_or(Error::Form))
				.transpose()?,
			required,
		})
	}
}
impl ToggleField {
	pub fn new(id: &str, label: &str, hint: Option<&str>, on: bool, reveals: Vec<Leaf>) -> Result<Self, Error> {
		Ok(Self {
			kind: ToggleKind::Toggle,
			id: Id::new(id.into()).ok_or(Error::Form)?,
			label: Text::new(label.into()).ok_or(Error::Form)?,
			hint: hint.map(|v| Text::new(v.into()).ok_or(Error::Form)).transpose()?,
			on,
			reveals: List::new(reveals).ok_or(Error::Form)?,
		})
	}
}
impl Action {
	pub fn new(
		id: &str,
		label: &str,
		busy_label: &str,
		tone: Tone,
		remembered: bool,
		confirm: Option<Confirm>,
	) -> Result<Self, Error> {
		Ok(Self {
			id: Id::new(id.into()).ok_or(Error::Form)?,
			label: Text::new(label.into()).ok_or(Error::Form)?,
			busy_label: Text::new(busy_label.into()).ok_or(Error::Form)?,
			tone,
			remembered,
			confirm,
		})
	}
}
impl Confirm {
	pub fn new(say: &str, keep: &str, commit: &str) -> Result<Self, Error> {
		Ok(Self {
			say: Text::new(say.into()).ok_or(Error::Form)?,
			keep: Text::new(keep.into()).ok_or(Error::Form)?,
			commit: Text::new(commit.into()).ok_or(Error::Form)?,
		})
	}
}

#[derive(Clone, Copy)]
pub enum LeafRef<'a> {
	Text(&'a TextField),
	Secret(&'a SecretField),
}
impl Leaf {
	pub fn as_ref(&self) -> LeafRef<'_> {
		match self {
			Self::Text(v) => LeafRef::Text(v),
			Self::Secret(v) => LeafRef::Secret(v),
		}
	}
}
impl LeafRef<'_> {
	pub fn id(&self) -> &str {
		match self {
			Self::Text(v) => v.id.as_str(),
			Self::Secret(v) => v.id.as_str(),
		}
	}
	pub fn label(&self) -> &crate::text::DocumentText {
		match self {
			Self::Text(v) => v.label.text(),
			Self::Secret(v) => v.label.text(),
		}
	}
	pub fn required(&self) -> bool {
		match self {
			Self::Text(v) => v.required,
			Self::Secret(v) => v.required,
		}
	}
	pub fn secret(&self) -> bool {
		matches!(self, Self::Secret(_))
	}
}
