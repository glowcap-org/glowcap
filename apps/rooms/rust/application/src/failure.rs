//! Stable Rooms failure codes inside a binding's broken-promise reason.
use core::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Retry {
	Never,
	AfterRequestChange,
	AfterStateChange,
	AfterRequestOrStateChange,
	Soon,
}
impl Retry {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Never => "never",
			Self::AfterRequestChange => "after-request-change",
			Self::AfterStateChange => "after-state-change",
			Self::AfterRequestOrStateChange => "after-request-or-state-change",
			Self::Soon => "soon",
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Definition {
	pub code: FailureCode,
	pub subject: &'static str,
	pub retry: Retry,
	pub summary: &'static str,
	pub action: Option<&'static str>,
}

macro_rules! codes {
	($($variant:ident => ($wire:literal, $subject:literal, $retry:ident, $summary:literal, $action:expr)),+ $(,)?) => {
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		pub enum FailureCode { $($variant),+ }
		impl FailureCode {
			pub const fn wire(self) -> &'static str { match self { $(Self::$variant => $wire),+ } }
			pub fn parse(value: &str) -> Option<Self> { match value { $($wire => Some(Self::$variant)),+, _ => None } }
			pub const fn definition(self) -> Definition { match self { $(Self::$variant => Definition {
				code: Self::$variant,
				subject: $subject,
				retry: Retry::$retry,
				summary: $summary,
				action: $action,
			}),+ } }
		}
		pub const DEFINITIONS: &[Definition] = &[$(FailureCode::$variant.definition()),+];
	};
}

codes! {
	NickTaken => ("nick-taken", "nickname", AfterRequestChange, "That name is taken in this room.", Some("Pick another.")),
	NoSuchRoom => ("no-such-room", "room", AfterStateChange, "That room isn't open.", Some("If you followed a link, ask whoever sent it for a current one.")),
	RoomExists => ("room-exists", "room", AfterRequestChange, "A room here already has that name.", Some("Go to that one, or pick a different name.")),
	RoomTooLong => ("room-too-long", "room", AfterRequestChange, "That room name is too long.", None),
	TooManyDirects => ("too-many-directs", "session", AfterStateChange, "You hold as many direct lines as this connection allows.", Some("Close one first.")),
	TooManyRooms => ("too-many-rooms", "session", AfterStateChange, "You're in as many rooms as this connection allows.", Some("Leave one first.")),
	RoomFull => ("room-full", "room", AfterStateChange, "That room is full.", Some("Try again when somebody leaves.")),
	TooManyPeeredRooms => ("too-many-peered-rooms", "directory", AfterStateChange, "This server is listing as many rooms from elsewhere as it can.", Some("Release one first.")),
	RoomLinksFull => ("room-links-full", "directory", AfterStateChange, "This server can't make any more room links.", Some("Rooms that already have one still work.")),
	NotSteward => ("not-steward", "room-authority", AfterStateChange, "You don't manage this room.", Some("Whoever opened it does, and once that authority is revoked it doesn't come back.")),
	PeerOffline => ("peer-offline", "member", AfterStateChange, "Nobody is here under that name right now.", None),
	IntroductionPending => ("introduction-pending", "member", Soon, "They aren't set up to receive this yet.", Some("Rooms has asked them. Try again in a moment.")),
	DirectNotAccepted => ("direct-not-accepted", "direct-conversation", AfterRequestChange, "This conversation is closed on their side.", Some("Start a new one to reach them.")),
	DeliveryUncertain => ("delivery-uncertain", "message", AfterStateChange, "Nobody can say yet whether this reached them.", Some("Wait for the conversation to catch up before sending it again.")),
	NotRegistered => ("not-registered", "directory-registration", AfterRequestChange, "You haven't picked a name here yet.", None),
	NotRoomMember => ("not-room-member", "membership", AfterRequestChange, "You're no longer in that room.", Some("Join it again to keep talking.")),
	ReadOnlyMembership => ("read-only-membership", "membership", AfterStateChange, "You can read this room but not post in it.", None),
	RoomRetired => ("room-retired", "room", Never, "That room is gone.", Some("A room with the same name now is a different room.")),
	NickTooLong => ("nick-too-long", "nickname", AfterRequestChange, "That name is too long.", None),
	NotYourLocator => ("not-your-locator", "directory-registration", AfterRequestChange, "That address isn't yours.", Some("Rooms only accepts an address that belongs to this connection.")),
	BadAttachment => ("bad-attachment", "message", AfterRequestChange, "That message wasn't posted.", Some("Remove the unsupported attachment data and try again.")),
	AttachmentRefused => ("attachment-refused", "attachment", AfterRequestChange, "That file wasn't accepted.", Some("Use a smaller file, or try again after pending uploads finish.")),
	UploadIncomplete => ("upload-incomplete", "attachment", AfterRequestChange, "That upload didn't finish, or exceeded its declared size.", Some("Upload it again.")),
	BlobExpired => ("blob-expired", "attachment", Never, "That file is gone.", Some("Ask the sender to share it again.")),
	ListenerUnsupported => ("listener-unsupported", "listener", AfterStateChange, "This server can't listen on that transport.", Some("Install and configure that transport before trying again.")),
	ListenerServing => ("listener-serving", "listener", Never, "This page arrived on that listener.", Some("Use another administration path before taking it down.")),
	ListenerTransportHeld => ("listener-transport-held", "listener", AfterStateChange, "This server already has a listener on that transport.", Some("Take that listener down first.")),
	NoSuchListener => ("no-such-listener", "listener", AfterRequestChange, "There's no listener by that name.", None),
	NoRoomManagers => ("no-room-managers", "room-authority", AfterRequestChange, "This server doesn't hand out room management.", Some("Open the room without requesting management.")),
	SessionUnreachable => ("session-unreachable", "session-peer", AfterStateChange, "The shared session peer could not be reached.", Some("Make sure it is running and retry the capability it currently announces. An iroh session needs a reachable advertised address or working iroh discovery and relay access.")),
	SessionHandshakeIncomplete => ("session-handshake-incomplete", "session-peer", AfterStateChange, "The session peer was reached, but it did not finish the OCapN handshake.", Some("Check that the Rooms session peer is running compatible code, then retry.")),
	SessionCapabilityGone => ("session-capability-gone", "session-capability", AfterRequestChange, "The session peer does not know this capability.", Some("It was probably revoked or belongs to a session that no longer exists. Use one the session shows now.")),
	SessionSignalingHostOffline => ("session-signaling-host-offline", "hosting-tab", AfterStateChange, "The hosting tab is not answering WebRTC on the directory this capability names.", Some("On that tab, share the session and leave it open. Reloading it ends sharing.")),
	SessionSignalingUnavailable => ("session-signaling-unavailable", "signaling-directory", AfterStateChange, "This browser could not signal through the directory the capability names.", Some("Retry after that directory is reachable from here.")),
	SessionWebrtcNoRoute => ("session-webrtc-no-route", "webrtc-route", AfterRequestOrStateChange, "The browsers exchanged the session offer, but WebRTC found no route between them.", Some("STUN can discover a direct route. If the networks permit none, configure TURN or select Relay and share a new capability. An already-issued .webrtc capability keeps its original route.")),
	SessionPeerUnverified => ("session-peer-unverified", "session-peer", AfterRequestChange, "The session peer answered, but this browser could not authenticate it as the peer the capability names.", Some("Retry with a capability the session shows now.")),
	LinkPreviewInvalidUrl => ("link-preview-invalid-url", "link-preview", AfterRequestChange, "That address can't be previewed.", Some("Use a public HTTP or HTTPS address without embedded credentials.")),
	LinkPreviewAddressBlocked => ("link-preview-address-blocked", "link-preview", AfterRequestChange, "Rooms won't connect to that address for a preview.", Some("Link previews can reach only public internet addresses, never this server or its private network.")),
	LinkPreviewDnsFailed => ("link-preview-dns-failed", "link-preview", Soon, "The preview service couldn't find that site.", Some("Retry if its address is temporarily unavailable.")),
	LinkPreviewUnreachable => ("link-preview-unreachable", "link-preview", Soon, "The preview service couldn't reach that site.", Some("Retry when the site is available.")),
	LinkPreviewTimedOut => ("link-preview-timed-out", "link-preview", Soon, "That site took too long to answer the preview request.", Some("Retry when it is responding again.")),
	LinkPreviewRedirectRefused => ("link-preview-redirect-refused", "link-preview", AfterRequestOrStateChange, "That site's redirect could not be followed safely.", Some("Open the link directly, or retry after the site fixes its redirect.")),
	LinkPreviewHttpRefused => ("link-preview-http-refused", "link-preview", AfterStateChange, "That site refused the preview request.", Some("The link still works as written; retry if the site changes.")),
	LinkPreviewContentUnsupported => ("link-preview-content-unsupported", "link-preview", AfterStateChange, "That address is not an HTML page or supported preview image.", None),
	LinkPreviewTooLarge => ("link-preview-too-large", "link-preview", AfterStateChange, "That page or image is too large to preview safely.", None),
	LinkPreviewMetadataMissing => ("link-preview-metadata-missing", "link-preview", AfterStateChange, "That page does not publish useful preview details.", None),
	LinkPreviewBusy => ("link-preview-busy", "link-preview", Soon, "The preview service is handling as many requests as it can.", Some("Try again in a moment. The link itself is still available.")),
	LinkPreviewFailed => ("link-preview-failed", "link-preview", Soon, "Rooms could not build that link preview.", Some("Retry once. The link itself is still available.")),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Failure<'a> {
	pub code: FailureCode,
	pub detail: &'a str,
}

impl<'a> Failure<'a> {
	/// Read the canonical Rooms reason, including the generic binding wrapper that
	/// shipped around it. A code-shaped phrase inside diagnostic detail is not a
	/// failure code. Unknown reasons stay untyped; reading allocates nothing.
	pub fn parse(reason: &'a str) -> Option<Self> {
		let reason = match reason.strip_prefix("glowcap error ") {
			Some(wrapped) => {
				let (status, payload) = wrapped.split_once(": ")?;
				let digits = status.strip_prefix('-').unwrap_or(status);
				if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
					return None;
				}
				status.parse::<i32>().ok()?;
				payload
			}
			None => reason,
		};
		let (segment, detail) = reason.split_once(": ").unwrap_or((reason, ""));
		FailureCode::parse(segment).map(|code| Self { code, detail })
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

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn parses_only_the_owned_code_position() {
		assert_eq!(
			Failure::parse("nick-taken: alice"),
			Some(Failure {
				code: FailureCode::NickTaken,
				detail: "alice",
			})
		);
		assert_eq!(
			Failure::parse("glowcap error -14: nick-taken: alice"),
			Some(Failure {
				code: FailureCode::NickTaken,
				detail: "alice",
			})
		);
		assert_eq!(Failure::parse("transport: nick-taken: alice"), None);
		assert_eq!(
			Failure::parse("blob-expired: nick-taken: alice"),
			Some(Failure {
				code: FailureCode::BlobExpired,
				detail: "nick-taken: alice",
			})
		);
	}

	#[test]
	fn rejects_an_unrecognised_or_malformed_wrapper() {
		assert_eq!(Failure::parse("glowcap error nope: nick-taken: alice"), None);
		assert_eq!(Failure::parse("glowcap error +14: nick-taken: alice"), None);
		assert_eq!(Failure::parse("prefix glowcap error -14: nick-taken: alice"), None);
	}

	#[test]
	fn every_definition_has_one_round_tripping_code() {
		for (index, definition) in DEFINITIONS.iter().enumerate() {
			assert_eq!(FailureCode::parse(definition.code.wire()), Some(definition.code));
			assert!(
				DEFINITIONS[..index]
					.iter()
					.all(|prior| prior.code.wire() != definition.code.wire()),
				"duplicate Rooms failure code {}",
				definition.code.wire()
			);
		}
	}
}
