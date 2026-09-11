//! Stable Rooms failure codes inside a binding's broken-promise reason.
use core::fmt;

macro_rules! codes {
	($($variant:ident => $wire:literal),+ $(,)?) => {
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		pub enum FailureCode { $($variant),+ }
		impl FailureCode {
			pub const fn wire(self) -> &'static str { match self { $(Self::$variant => $wire),+ } }
			pub fn parse(value: &str) -> Option<Self> { match value { $($wire => Some(Self::$variant)),+, _ => None } }
		}
	};
}

codes! {
	NickTaken => "nick-taken",
	NoSuchRoom => "no-such-room",
	RoomExists => "room-exists",
	RoomTooLong => "room-too-long",
	TooManyRooms => "too-many-rooms",
	RoomFull => "room-full",
	TooManyPeeredRooms => "too-many-peered-rooms",
	RoomLinksFull => "room-links-full",
	NotSteward => "not-steward",
	PeerOffline => "peer-offline",
	IntroductionPending => "introduction-pending",
	DirectNotAccepted => "direct-not-accepted",
	NotRegistered => "not-registered",
	NotRoomMember => "not-room-member",
	ReadOnlyMembership => "read-only-membership",
	RoomRetired => "room-retired",
	NickTooLong => "nick-too-long",
	NotYourLocator => "not-your-locator",
	BadAttachment => "bad-attachment",
	AttachmentRefused => "attachment-refused",
	UploadIncomplete => "upload-incomplete",
	BlobExpired => "blob-expired",
	ListenerUnsupported => "listener-unsupported",
	ListenerServing => "listener-serving",
	ListenerTransportHeld => "listener-transport-held",
	NoSuchListener => "no-such-listener",
	NoRoomManagers => "no-room-managers",
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Failure<'a> {
	pub code: FailureCode,
	pub detail: &'a str,
}

impl<'a> Failure<'a> {
	/// Bindings can prepend their own diagnostic. Match complete colon-delimited
	/// segments and retain the entire remaining detail, including further colons.
	/// Unknown and untyped reasons stay untyped; reading this allocates nothing.
	pub fn parse(mut reason: &'a str) -> Option<Self> {
		loop {
			let (segment, detail) = reason.split_once(": ").unwrap_or((reason, ""));
			if let Some(code) = FailureCode::parse(segment) {
				return Some(Self { code, detail });
			}
			if detail.is_empty() {
				return None;
			}
			reason = detail;
		}
	}
}

impl fmt::Display for Failure<'_> {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		write!(f, "{}: {}", self.code.wire(), self.detail)
	}
}

/// Application failure details crossing retained queues or broken promises.
/// Borrow the bounded UTF-8 prefix so callers choose whether retention is needed.
pub const MAX_REASON_BYTES: usize = 4096;
pub fn reason_prefix(reason: &str) -> &str {
	let mut end = reason.len().min(MAX_REASON_BYTES);
	while !reason.is_char_boundary(end) {
		end -= 1;
	}
	&reason[..end]
}
