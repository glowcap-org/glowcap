//! Durable browser choices, admitted before opening a network runtime. The
//! shared checkpoint owns session policy; this envelope adds controller choice
//! and presentation preferences without acquiring any live authority.
use crate::{
	fields::{self, Text},
	session::checkpoint::{Checkpoint, Refusal, Routes, MAX_CHECKPOINT_UNITS},
};
use alloc::{rc::Rc, string::String};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
pub mod persistence;
pub mod transition;

pub const STORAGE_KEY: &str = "rooms.workspace-state";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
	version: u8,
	#[serde(skip_serializing_if = "Option::is_none")]
	left_page_directory: Option<Text<65536, true>>,
	controller: Controller,
	session: Rc<Checkpoint>,
	view: View,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Envelope<'a> {
	#[serde(deserialize_with = "crate::session::fields::version")]
	version: u8,
	#[serde(default, deserialize_with = "fields::present")]
	left_page_directory: Option<Text<65536, true>>,
	#[serde(borrow)]
	controller: &'a RawValue,
	#[serde(borrow)]
	session: &'a RawValue,
	#[serde(deserialize_with = "fields::object")]
	view: View,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Controller {
	None {},
	Local {},
	Attached { sturdyref: Text<16384> },
	Hosted { sturdyref: Text<16384> },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct View {
	pub theme: Theme,
	pub notify_on: bool,
	pub rail_open: bool,
	pub roster_open: bool,
	pub settings_tab: SettingsTab,
	pub ops_pane: OperationsPane,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
	Light,
	Dark,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SettingsTab {
	Session,
	Holdings,
	Reachability,
}
pub struct OperationsPane(&'static crate::server::operations::BootCapability);
impl Serialize for OperationsPane {
	fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		serializer.serialize_str(self.0.id)
	}
}
impl<'de> Deserialize<'de> for OperationsPane {
	fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
		let name = Text::<16>::deserialize(deserializer)?;
		name.text()
			.as_str()
			.and_then(crate::server::operations::boot_capability)
			.map(Self)
			.ok_or_else(|| serde::de::Error::custom("Rooms operations pane"))
	}
}

impl Workspace {
	pub fn controller(&self) -> &Controller {
		&self.controller
	}
	pub fn session(&self) -> &Checkpoint {
		&self.session
	}
	pub fn into_session(self) -> Rc<Checkpoint> {
		self.session
	}
	pub fn view(&self) -> &View {
		&self.view
	}
	pub fn left_page_directory(&self) -> Option<&Text<65536, true>> {
		self.left_page_directory.as_ref()
	}
	pub fn decode(raw: &str, routes: &impl Routes) -> Result<Self, Refusal> {
		if raw.encode_utf16().take(MAX_CHECKPOINT_UNITS + 1).count() > MAX_CHECKPOINT_UNITS {
			return Err(Refusal::Size);
		}
		Self::read(raw, routes)
	}
	/// JavaScript storage can contain literal unpaired UTF-16 units. Escape
	/// those units inside JSON strings before using the UTF-8 JSON reader. The
	/// size budget applies to the original document, as it does in the browser.
	pub fn decode_utf16(raw: &[u16], routes: &impl Routes) -> Result<Self, Refusal> {
		use core::fmt::Write;
		if raw.len() > MAX_CHECKPOINT_UNITS {
			return Err(Refusal::Size);
		}
		let mut json = String::with_capacity(raw.len());
		let (mut quoted, mut escaped) = (false, false);
		for scalar in char::decode_utf16(raw.iter().copied()) {
			match scalar {
				Ok(c) => {
					json.push(c);
					if escaped {
						escaped = false;
					} else if c == '"' {
						quoted = !quoted;
					} else if quoted && c == '\\' {
						escaped = true;
					}
				}
				Err(error) => {
					// Escaping an invalid JSON escape would turn a refused
					// document into a different, valid one. Keep its refusal.
					if !quoted || escaped {
						return Err(Refusal::Schema);
					}
					write!(json, "\\u{:04x}", error.unpaired_surrogate()).expect("String write");
				}
			}
		}
		Self::read(&json, routes)
	}
	fn read(raw: &str, routes: &impl Routes) -> Result<Self, Refusal> {
		let envelope: Envelope<'_> = fields::json_object(raw).map_err(|_| Refusal::Schema)?;
		let controller: Controller = fields::json_object(envelope.controller.get()).map_err(|_| Refusal::Schema)?;
		validate_controller(&controller, routes)?;
		Ok(Self {
			version: envelope.version,
			left_page_directory: envelope.left_page_directory,
			controller,
			session: Rc::new(Checkpoint::decode_embedded(envelope.session.get(), routes)?),
			view: envelope.view,
		})
	}
	/// Browser choices supply no session state. The live owner lends its exact
	/// immutable checkpoint for persistence and export.
	pub fn compose(raw: &str, session: Rc<Checkpoint>, routes: &impl Routes) -> Result<Self, Refusal> {
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Choices<'a> {
			#[serde(default, deserialize_with = "fields::present")]
			left_page_directory: Option<Text<65536, true>>,
			#[serde(borrow)]
			controller: &'a RawValue,
			#[serde(deserialize_with = "fields::object")]
			view: View,
		}
		if raw.encode_utf16().take(MAX_CHECKPOINT_UNITS + 1).count() > MAX_CHECKPOINT_UNITS {
			return Err(Refusal::Size);
		}
		let choices: Choices<'_> = fields::json_object(raw).map_err(|_| Refusal::Schema)?;
		let controller = fields::json_object(choices.controller.get()).map_err(|_| Refusal::Schema)?;
		validate_controller(&controller, routes)?;
		Ok(Self {
			version: 1,
			left_page_directory: choices.left_page_directory,
			controller,
			session,
			view: choices.view,
		})
	}
	/// Prepare controller selection and an optional verified peer checkpoint as
	/// one document. The storage owner publishes this only after a successful
	/// write, so refusal never requires undoing a live projection change.
	pub fn select(
		mut self,
		controller: &str,
		checkpoint: Option<&str>,
		routes: &impl Routes,
	) -> Result<(Self, bool), Refusal> {
		let controller = fields::json_object(controller).map_err(|_| Refusal::Schema)?;
		validate_controller(&controller, routes)?;
		let fork = checkpoint.is_none()
			&& matches!(self.controller, Controller::Attached { .. })
			&& matches!(controller, Controller::Local {} | Controller::None {});
		if let Some(checkpoint) = checkpoint {
			self.session = Rc::new(Checkpoint::decode(checkpoint, routes)?);
		} else if fork {
			self.session = Rc::new(self.session.fork());
		}
		self.controller = controller;
		Ok((self, checkpoint.is_some() || fork))
	}
	/// A portable export keeps intent and preferences but carries no bearer
	/// authority. The checkpoint lends its existing facet projection; secrets
	/// are neither cloned nor included in an intermediate JSON value.
	pub fn export(&self, include_capabilities: bool) -> Result<String, Refusal> {
		if include_capabilities {
			return self.encode();
		}
		#[derive(Serialize)]
		#[serde(rename_all = "camelCase")]
		struct Export<'a, S: Serialize> {
			version: u8,
			#[serde(skip_serializing_if = "Option::is_none")]
			left_page_directory: &'a Option<Text<65536, true>>,
			controller: Controller,
			session: S,
			view: &'a View,
		}
		let document = Export {
			version: self.version,
			left_page_directory: &self.left_page_directory,
			controller: Controller::Local {},
			session: self.session.without_authority(),
			view: &self.view,
		};
		bounded_encode(&document)
	}
	pub fn encode(&self) -> Result<String, Refusal> {
		bounded_encode(self)
	}
}

fn validate_controller(controller: &Controller, routes: &impl Routes) -> Result<(), Refusal> {
	if let Controller::Attached { sturdyref } | Controller::Hosted { sturdyref } = controller {
		let link = sturdyref.text().as_str().ok_or(Refusal::Route)?;
		if !link.starts_with("ocapn://") || !link.contains("/s/") || routes.sturdyref_authority(link).is_none() {
			return Err(Refusal::Route);
		}
	}
	Ok(())
}

fn bounded_encode(value: &impl Serialize) -> Result<String, Refusal> {
	let encoded = serde_json::to_string(value).map_err(|_| Refusal::Schema)?;
	if encoded.encode_utf16().take(MAX_CHECKPOINT_UNITS + 1).count() > MAX_CHECKPOINT_UNITS {
		return Err(Refusal::Size);
	}
	Ok(encoded)
}
