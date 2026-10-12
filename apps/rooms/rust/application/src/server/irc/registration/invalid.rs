//! Why a registration input or an observed server message is refused. The
//! `Display` of each variant is the exact line the driver reports.
use super::{REALNAME_BYTES, SASL_ACCOUNT_BYTES, SASL_PASSWORD_BYTES};
use alloc::string::{String, ToString};
use core::fmt;

/// A refused nick, real name, SASL login, or server message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The nick is not 1..28 nickname characters starting with a letter or special.
	NickCharacters,
	/// The real name is empty, too long, or holds NUL or a line break.
	RealnameBytes,
	/// The SASL account is empty, too long, or holds NUL.
	SaslAccountBytes,
	/// The SASL password is empty, too long, or holds NUL.
	SaslPasswordBytes,
	/// The wire encoder or a UTF-8 check refused a line, with its own text.
	Wire(String),
	/// The server gave the feed a nick other than the one it chose, with the full line.
	Renamed(String),
	/// The server asked for authentication after registration.
	AuthenticateAfterRegistration,
	/// The server's capability list has no SASL.
	SaslNotAdvertised,
	/// The server's SASL list has no PLAIN.
	SaslPlainNotAdvertised,
	/// The server answered the SASL capability request with NAK.
	SaslCapabilityRefused,
	/// The server began SASL before the capability was acknowledged.
	SaslBeforeAgreed,
	/// The server asked for the SASL payload a second time.
	SaslPayloadTwice,
	/// The server aborted SASL with `AUTHENTICATE *`.
	SaslAborted,
	/// The server completed SASL before credentials were sent.
	SaslBeforeCredentials,
	/// The server answered with a SASL failure numeric.
	SaslFailed { command: String },
	/// The server reported the nick as already in use.
	NickInUse { nick: String },
	/// The server announced a case mapping other than rfc1459.
	UnsupportedCasemapping { param: String },
	/// The server sent ERROR, with its reason.
	ServerClosed { reason: String },
	/// The welcome arrived before SASL finished.
	RegisteredBeforeSasl,
}

impl fmt::Display for Invalid {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::NickCharacters => {
				f.write_str("IRC nickname must be 1..28 ASCII nickname characters and begin with a letter or special")
			}
			Self::RealnameBytes => write!(
				f,
				"IRC real name must be 1..{REALNAME_BYTES} UTF-8 bytes without NUL or a line break"
			),
			Self::SaslAccountBytes => write!(
				f,
				"IRC SASL account must be 1..{SASL_ACCOUNT_BYTES} UTF-8 bytes without NUL"
			),
			Self::SaslPasswordBytes => write!(
				f,
				"IRC SASL password must be 1..{SASL_PASSWORD_BYTES} UTF-8 bytes without NUL"
			),
			Self::Wire(text) | Self::Renamed(text) => f.write_str(text),
			Self::AuthenticateAfterRegistration => f.write_str("IRC requested authentication after registration"),
			Self::SaslNotAdvertised => f.write_str("IRC server does not advertise SASL"),
			Self::SaslPlainNotAdvertised => f.write_str("IRC server does not advertise the SASL PLAIN mechanism"),
			Self::SaslCapabilityRefused => f.write_str("IRC server refused the SASL capability"),
			Self::SaslBeforeAgreed => f.write_str("IRC server started SASL before agreeing to it"),
			Self::SaslPayloadTwice => f.write_str("IRC server requested the SASL payload twice"),
			Self::SaslAborted => f.write_str("IRC server aborted SASL authentication"),
			Self::SaslBeforeCredentials => f.write_str("IRC server completed SASL before receiving credentials"),
			Self::SaslFailed { command } => write!(f, "IRC SASL authentication failed ({command})"),
			Self::NickInUse { nick } => write!(f, "IRC nickname \"{nick}\" is already in use"),
			Self::UnsupportedCasemapping { param } => write!(f, "IRC server uses unsupported {param}"),
			Self::ServerClosed { reason } => write!(f, "IRC server closed: {reason}"),
			Self::RegisteredBeforeSasl => f.write_str("IRC registered before SASL authentication completed"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::NickCharacters,
				"IRC nickname must be 1..28 ASCII nickname characters and begin with a letter or special",
			),
			(
				Invalid::RealnameBytes,
				"IRC real name must be 1..300 UTF-8 bytes without NUL or a line break",
			),
			(
				Invalid::SaslAccountBytes,
				"IRC SASL account must be 1..64 UTF-8 bytes without NUL",
			),
			(
				Invalid::SaslPasswordBytes,
				"IRC SASL password must be 1..256 UTF-8 bytes without NUL",
			),
			(
				Invalid::AuthenticateAfterRegistration,
				"IRC requested authentication after registration",
			),
			(Invalid::SaslNotAdvertised, "IRC server does not advertise SASL"),
			(
				Invalid::SaslPlainNotAdvertised,
				"IRC server does not advertise the SASL PLAIN mechanism",
			),
			(Invalid::SaslCapabilityRefused, "IRC server refused the SASL capability"),
			(
				Invalid::SaslBeforeAgreed,
				"IRC server started SASL before agreeing to it",
			),
			(Invalid::SaslPayloadTwice, "IRC server requested the SASL payload twice"),
			(Invalid::SaslAborted, "IRC server aborted SASL authentication"),
			(
				Invalid::SaslBeforeCredentials,
				"IRC server completed SASL before receiving credentials",
			),
			(
				Invalid::SaslFailed { command: "904".into() },
				"IRC SASL authentication failed (904)",
			),
			(
				Invalid::NickInUse { nick: "bot".into() },
				"IRC nickname \"bot\" is already in use",
			),
			(
				Invalid::UnsupportedCasemapping {
					param: "CASEMAPPING=ascii".into(),
				},
				"IRC server uses unsupported CASEMAPPING=ascii",
			),
			(Invalid::ServerClosed { reason: "bye".into() }, "IRC server closed: bye"),
			(
				Invalid::RegisteredBeforeSasl,
				"IRC registered before SASL authentication completed",
			),
			(Invalid::Wire("wire text".into()), "wire text"),
			(Invalid::Renamed("renamed text".into()), "renamed text"),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
