//! Borrowed admission and routing for the Rooms session `command` method.
//! Runtime effects and checkpoint policy validate their own command arguments.
pub mod selection;
use super::{
	checkpoint::commands::{self, results},
	state::{OperationId, SafeInteger},
};
use crate::{grants::Access, room::ArgumentView};
use alloc::string::String;
use serde::{Deserialize, Serialize, Serializer, ser::SerializeSeq};

pub const MAX_ARGUMENTS: usize = 64;
pub const MAX_MATERIAL_BYTES: usize = 512 * 1024;
pub const MAX_ARGUMENT_UNITS: usize = 64 * 1024;
// Enum iteration and wire names are generated from the same variants. Exhaustive
// application requirement matches make a new route require an explicit decision.
macro_rules! catalog {
	($name:ident { $($variant:ident,)* }) => {
		#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
		#[serde(rename_all = "camelCase")]
		pub enum $name { $($variant,)* }
		impl $name { pub const ALL: &'static [Self] = &[$(Self::$variant,)*]; }
	};
}
pub(crate) use catalog;
catalog! { Effect {
	EnterRoom,
	OfferRoom,
	ShareArchiveHistory,
	OfferDurableArchive,
	RevokeIssuedArchiveShare,
	SetRoomSubject,
	SetRoomAway,
	RetireRoomMembership,
	KickRoomMember,
	IssueRoomModerator,
	Say,
	DirectReady,
	OfferDirectInbox,
	EditLine,
	WithdrawLine,
	Operator,
	RevokeManagedRoomAuthority,
	UnregisterManagedRoom,
	SetManagedRoomPolicy,
	Operations,
} }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
	Checkpoint(commands::Command),
	Result(results::Command),
	Effect(Effect),
}
impl Route {
	pub fn parse(name: &str) -> Option<Self> {
		fn parse<'a, T: Deserialize<'a>>(name: &'a str) -> Option<T> {
			T::deserialize(serde::de::value::StrDeserializer::<NameError>::new(name)).ok()
		}
		if let Some(command) = parse(name) {
			return Some(Self::Checkpoint(command));
		}
		if let Some(command) = parse(name) {
			// The shared plan builder also accepts linkRoom; the session command
			// dispatcher exposes ensureRoomLink for this operation.
			if command != results::Command::LinkRoom {
				return Some(Self::Result(command));
			}
		}
		parse(name).map(Self::Effect)
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Access,
	Administration,
	Arguments,
	OperationId,
	Count,
	MaterialSize,
	ArgumentSize,
	Unknown,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Access => "this Rooms session facet cannot issue commands",
			Self::Administration => "this Rooms session facet cannot administer retained capabilities",
			Self::Arguments => "session command takes an operation id, base revision, name, and string arguments",
			Self::OperationId => "invalid session operation id",
			Self::Count => "session command has too many arguments",
			Self::MaterialSize => "session command exceeds its byte ceiling",
			Self::ArgumentSize => "session command contains an oversized argument",
			Self::Unknown => "unknown Rooms session command",
		})
	}
}
impl core::error::Error for Refusal {}

pub struct Request<'a, A> {
	id: &'a str,
	base: u64,
	name: &'a str,
	route: Route,
	args: &'a [A],
	material_bytes: usize,
}
impl<'a, A: ArgumentView> Request<'a, A> {
	/// Access comes from the held facet. Parsing borrows delivered values and
	/// admits no capability arguments. No authority is derived from these strings.
	pub fn read(access: Access, args: &'a [A]) -> Result<Self, Refusal> {
		if !matches!(access, Access::Interact | Access::Admin) {
			return Err(Refusal::Access);
		}
		let request = Self::parse(args)?;
		request.require_administration(access)?;
		Ok(request)
	}
	/// Parse the bounded command grammar without granting authority. Managed
	/// content declares this route's requirements to the shared access owner.
	pub fn parse(args: &'a [A]) -> Result<Self, Refusal> {
		if args.len() < 3 {
			return Err(Refusal::Arguments);
		}
		let id = args[0].text().ok_or(Refusal::Arguments)?;
		let base = args[1]
			.integer()
			.and_then(|n| u64::try_from(n).ok())
			.and_then(SafeInteger::<false>::new)
			.ok_or(Refusal::Arguments)?
			.get();
		let name = args[2].text().ok_or(Refusal::Arguments)?;
		Self::from_parts(id, base, name, &args[3..])
	}
	/// Admit a local command through the same policy as the wire envelope.
	pub fn new(access: Access, id: &'a str, base: u64, name: &'a str, args: &'a [A]) -> Result<Self, Refusal> {
		if !matches!(access, Access::Interact | Access::Admin) {
			return Err(Refusal::Access);
		}
		let request = Self::from_parts(id, base, name, args)?;
		request.require_administration(access)?;
		Ok(request)
	}
	/// Commands that replace operator authority or the selected archive need
	/// the admin facet, whichever door admitted the request.
	fn require_administration(&self, access: Access) -> Result<(), Refusal> {
		if access != Access::Admin
			&& matches!(
				self.name,
				"replaceOperationsCapabilities" | "replaceOperationsBundle" | "selectArchive"
			) {
			return Err(Refusal::Administration);
		}
		Ok(())
	}
	/// Admit borrowed application arguments before constructing a wire envelope.
	/// This grants no access. The held source owns command authorization.
	pub fn from_parts(id: &'a str, base: u64, name: &'a str, args: &'a [A]) -> Result<Self, Refusal> {
		SafeInteger::<false>::new(base).ok_or(Refusal::Arguments)?;
		if !OperationId::accepts_utf16(id.encode_utf16()) {
			return Err(Refusal::OperationId);
		}
		if args.len() > MAX_ARGUMENTS {
			return Err(Refusal::Count);
		}
		let mut bytes = 2usize.saturating_add(json_string_bytes(name));
		if bytes > MAX_MATERIAL_BYTES {
			return Err(Refusal::MaterialSize);
		}
		for arg in args {
			let text = arg.text().ok_or(Refusal::Arguments)?;
			bytes = bytes.saturating_add(1).saturating_add(json_string_bytes(text));
			if bytes > MAX_MATERIAL_BYTES {
				return Err(Refusal::MaterialSize);
			}
		}
		for arg in args {
			if arg
				.text()
				.ok_or(Refusal::Arguments)?
				.encode_utf16()
				.take(MAX_ARGUMENT_UNITS + 1)
				.count() > MAX_ARGUMENT_UNITS
			{
				return Err(Refusal::ArgumentSize);
			}
		}
		Ok(Self {
			id,
			base,
			name,
			route: Route::parse(name).ok_or(Refusal::Unknown)?,
			args,
			material_bytes: bytes,
		})
	}
	pub fn id(&self) -> &'a str {
		self.id
	}
	pub fn base(&self) -> u64 {
		self.base
	}
	pub fn name(&self) -> &'a str {
		self.name
	}
	pub fn route(&self) -> Route {
		self.route
	}
	pub fn args(&self) -> impl ExactSizeIterator<Item = &'a str> {
		self.args.iter().map(|v| {
			#[expect(
				clippy::expect_used,
				reason = "`from_parts` refused any argument that is not text before this command existed"
			)]
			v.text().expect("admitted text")
		})
	}
	/// Own the exact bounded intent for receipt recovery. Serialization walks
	/// admitted borrowed arguments directly. It creates no intermediate argument
	/// inventory or payload copies. The returned string outlives the request.
	pub fn canonical(&self) -> serde_json::Result<String> {
		serde_json::to_string(&(self.id, self.base, self.name, Arguments(self.args)))
	}
	/// Exact incoming JSON array size, including bridge secrets. The eventual
	/// retry material excludes those secrets and may therefore be smaller.
	pub fn material_bytes(&self) -> usize {
		self.material_bytes
	}
}
struct Arguments<'a, A>(&'a [A]);
impl<A: ArgumentView> Serialize for Arguments<'_, A> {
	fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		let mut sequence = serializer.serialize_seq(Some(self.0.len()))?;
		for argument in self.0 {
			let text = argument
				.text()
				.ok_or_else(|| <S::Error as serde::ser::Error>::custom("a command argument is not text"))?;
			sequence.serialize_element(text)?;
		}
		sequence.end()
	}
}
fn json_string_bytes(text: &str) -> usize {
	let mut bytes = 2usize;
	for byte in text.bytes() {
		bytes = bytes.saturating_add(match byte {
			b'"' | b'\\' | 8 | 9 | 10 | 12 | 13 => 2,
			0..=31 => 6,
			_ => 1,
		});
		if bytes > MAX_MATERIAL_BYTES {
			break;
		}
	}
	bytes
}

// Unknown names are ordinary routing probes. Avoid allocating diagnostic
// strings while trying the shared command enums.
#[derive(Debug)]
struct NameError;
impl core::fmt::Display for NameError {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str("command name")
	}
}
impl core::error::Error for NameError {}
impl serde::de::Error for NameError {
	fn custom<T: core::fmt::Display>(_: T) -> Self {
		Self
	}
}
