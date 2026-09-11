//! Presentation adapter for the shared command coordinator. This owns neither
//! retry policy nor a second Host. Only result intents and the rare recovery
//! snapshot cross into Rust; ordinary command bodies remain with their executor.
use rooms_application::{
	fields::{List, Text},
	session::{
		controller::{self, Authority, Pending},
		state::OperationId,
	},
	text::DocumentText,
};
use serde::Deserialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub struct RoomsCommands(controller::Commands);
#[wasm_bindgen]
impl RoomsCommands {
	#[wasm_bindgen(constructor)]
	pub fn new() -> Self {
		Self(controller::Commands::default())
	}
	pub fn begin(&self, name: &str, id: js_sys::JsString, args: js_sys::Array) -> Result<RoomsCommand, JsValue> {
		let id =
			OperationId::new(read_text(id, 128).map_err(error)?).ok_or_else(|| error(controller::Error::Arguments))?;
		self.0
			.begin(name, id, |command| {
				if !command.arity().contains(&(args.length() as usize)) {
					return Err(controller::Error::Arguments);
				}
				args.iter()
					.map(|arg| {
						let text = arg
							.dyn_into::<js_sys::JsString>()
							.map_err(|_| controller::Error::Arguments)?;
						read_text(text, rooms_application::session::command::MAX_ARGUMENT_UNITS)
					})
					.collect()
			})
			.map(RoomsCommand)
			.map_err(error)
	}
	pub fn driving(&self) -> js_sys::Array {
		self.0
			.driving()
			.iter()
			.map(|id| JsValue::from(js_text(id.text())))
			.collect()
	}
	pub fn close(&self) {
		self.0.close();
	}
}
impl Default for RoomsCommands {
	fn default() -> Self {
		Self::new()
	}
}

#[wasm_bindgen]
pub enum RoomsCommandStep {
	Refresh,
	Issue,
	Resume,
	SettleCommand,
	SettleResume,
	Refused,
	Done,
}
#[wasm_bindgen]
pub struct RoomsCommand(controller::Operation);
#[wasm_bindgen]
impl RoomsCommand {
	#[wasm_bindgen(getter)]
	pub fn id(&self) -> js_sys::JsString {
		js_text(self.0.id().text())
	}
	#[wasm_bindgen(getter)]
	pub fn step(&self) -> RoomsCommandStep {
		match self.0.step() {
			controller::Step::Refresh => RoomsCommandStep::Refresh,
			controller::Step::Issue => RoomsCommandStep::Issue,
			controller::Step::Resume => RoomsCommandStep::Resume,
			controller::Step::SettleCommand(_) => RoomsCommandStep::SettleCommand,
			controller::Step::SettleResume(_) => RoomsCommandStep::SettleResume,
			controller::Step::Refused => RoomsCommandStep::Refused,
			controller::Step::Done => RoomsCommandStep::Done,
		}
	}
	#[wasm_bindgen(getter, js_name = resumeId)]
	pub fn resume_id(&self) -> Result<js_sys::JsString, JsValue> {
		self.0
			.resuming()
			.map(|(id, _)| js_text(id.text()))
			.ok_or_else(|| error(controller::Error::Step))
	}
	#[wasm_bindgen(getter, js_name = resumeSubject)]
	pub fn resume_subject(&self) -> Result<js_sys::JsString, JsValue> {
		self.0
			.resuming()
			.map(|(_, subject)| js_text(subject))
			.ok_or_else(|| error(controller::Error::Step))
	}
	pub fn refreshed(&mut self, raw: &str) -> Result<(), JsValue> {
		let pending: List<PendingView, 256> = projection(raw)?;
		self.0
			.refreshed(pending.as_slice().iter().map(|p| Pending {
				id: p.id.text(),
				kind: p.kind.text(),
				subject: p.subject.text(),
			}))
			.map_err(error)
	}
	pub fn resumed(&mut self, raw: &str) -> Result<(), JsValue> {
		let rooms: List<AuthorityView, 256> = projection(raw)?;
		self.0
			.resumed(
				rooms
					.as_slice()
					.iter()
					.filter(|r| r.kind == Kind::Room)
					.map(|r| Authority {
						id: r.id.text(),
						link: r.link.as_ref().map(|v| v.text()),
						manager: r.manager.as_ref().map(|v| v.text()),
						steward: r.steward.as_ref().map(|v| v.text()),
					}),
			)
			.map_err(error)
	}
	pub fn refused(&mut self, reason: &str) -> Result<bool, JsValue> {
		self.0.refused(reason).map_err(error)
	}
	#[wasm_bindgen(getter)]
	pub fn revision(&self) -> Result<f64, JsValue> {
		match self.0.step() {
			controller::Step::SettleCommand(revision) | controller::Step::SettleResume(revision) => Ok(revision as f64),
			_ => Err(error(controller::Error::Step)),
		}
	}
	pub fn acknowledged(&mut self, revision: f64) -> Result<(), JsValue> {
		if !revision.is_finite() || revision < 0.0 || revision.fract() != 0.0 || revision > 9007199254740991.0 {
			return Err(error(controller::Error::Arguments));
		}
		self.0.acknowledged(revision as u64).map_err(error)
	}
	pub fn committed(&mut self) -> Result<(), JsValue> {
		self.0.committed().map_err(error)
	}
}

// Borrowing the native checkpoint needs no projection allocation. The current
// page owns a JS snapshot, so recovery transfers only these bounded facts; it
// does not duplicate the full session view or any live attachment capability.
#[derive(Deserialize)]
struct PendingView {
	id: OperationId,
	kind: Text<65536>,
	subject: Text<65536>,
}
#[derive(Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Kind {
	Room,
	Direct,
}
#[derive(Deserialize)]
struct AuthorityView {
	kind: Kind,
	id: Text<65536, true>,
	link: Option<Text<16384>>,
	manager: Option<Text<16384>>,
	steward: Option<Text<16384>>,
}
fn projection<T: serde::de::DeserializeOwned>(raw: &str) -> Result<T, JsValue> {
	if raw.len() > rooms_application::session::snapshot::MAX_TEXT_BYTES {
		return Err(error(controller::Error::Arguments));
	}
	serde_json::from_str(raw).map_err(|_| error(controller::Error::Arguments))
}
fn js_text(text: &DocumentText) -> js_sys::JsString {
	if let Some(text) = text.as_str() {
		return text.into();
	}
	// JSON carries isolated UTF-16 surrogates without changing stored identity.
	js_sys::JSON::parse(&serde_json::to_string(text).expect("document text encodes"))
		.expect("encoded document text parses")
		.unchecked_into()
}
fn error(error: controller::Error) -> JsValue {
	js_sys::Error::new(&error.to_string()).into()
}

pub(crate) fn read_text(text: js_sys::JsString, max_units: usize) -> Result<DocumentText, controller::Error> {
	if text.length() as usize > max_units {
		return Err(controller::Error::Arguments);
	}
	let scalar = text.as_string().ok_or(controller::Error::Arguments)?;
	// Compare JS strings: JsString/str equality is lossy.
	let round_trip = js_sys::JsString::from(scalar.as_str());
	Ok(if round_trip == text {
		scalar.into()
	} else {
		DocumentText::from_utf16(&text.iter().collect::<Vec<_>>())
	})
}

/// Opaque view-local draft ownership, shared with native controllers.
#[wasm_bindgen]
#[derive(Default)]
pub struct RoomsDrafts(controller::drafts::Drafts);
#[wasm_bindgen]
impl RoomsDrafts {
	#[wasm_bindgen(constructor)]
	pub fn new() -> Self {
		Self::default()
	}
	pub fn stage(&mut self, conversation: js_sys::JsString, text: js_sys::JsString) -> Result<u64, JsValue> {
		let conversation = read_text(conversation, 65_536).map_err(error)?;
		let text = read_text(text, 65_536).map_err(error)?;
		self.0.stage(conversation, text).map_err(error)
	}
	pub fn pending(&self, conversation: js_sys::JsString) -> Result<Option<js_sys::JsString>, JsValue> {
		Ok(self
			.0
			.pending(&read_text(conversation, 65_536).map_err(error)?)
			.map(js_text))
	}
	pub fn token(&self, conversation: js_sys::JsString) -> Result<Option<u64>, JsValue> {
		Ok(self.0.token(&read_text(conversation, 65_536).map_err(error)?))
	}
	pub fn finish(&mut self, conversation: js_sys::JsString, token: u64) -> Result<(), JsValue> {
		self.0.finish(&read_text(conversation, 65_536).map_err(error)?, token);
		Ok(())
	}
	pub fn retire(&mut self, conversation: js_sys::JsString) -> Result<(), JsValue> {
		self.0.retire(&read_text(conversation, 65_536).map_err(error)?);
		Ok(())
	}
	pub fn close(&mut self) {
		self.0.close();
	}
}
