//! What IRC calls the people in a bridged room, and the form it asks Rooms
//! to draw for one reader's own identity.
//!
//! A seat is a Rooms member who also holds an IRC identity. A foreign
//! member is somebody who has no Rooms membership at all. The words for both
//! are IRC's own and live here, because a Rooms server does not know what its
//! bridge is, and a browser that spelled them itself would have to be
//! rebuilt before a second bridge could say anything of its own.
use super::registration::Invalid as RegistrationInvalid;
use crate::bridge::{Action, Confirm, Field, Form, Leaf, SecretField, TextField, TextOptions, ToggleField, Tone};
use alloc::{
	format,
	string::{String, ToString},
	vec::Vec,
};

/// The attribution prefix an IRC-only member's roster name carries. A
/// roster key of `irc/bo` is a name in the room's namespace and `bo` a name
/// in IRC's. The prefix keeps the two apart, so a member on IRC cannot take
/// a Rooms member's name by picking it.
pub const PREFIX: &str = "irc/";
pub const FOREIGN_BADGE: &str = "IRC";
pub const FOREIGN_SAID: &str = "IRC only";

pub const LINK_ACTION: &str = "link";
pub const DISCONNECT_ACTION: &str = "disconnect";
pub const NICK_FIELD: &str = "nick";
pub const REGISTERED_FIELD: &str = "registered";
pub const ACCOUNT_FIELD: &str = "account";
pub const PASSWORD_FIELD: &str = "password";

/// The server-owned lifecycle of one member's projection onto IRC. Link
/// states rather than words: IRC writes what its badge says and does not
/// get to invent a fifth thing a member can be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
	Rooms,
	Connecting,
	Linked,
	Failed,
}

impl Phase {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Rooms => "rooms",
			Self::Connecting => "connecting",
			Self::Linked => "linked",
			Self::Failed => "failed",
		}
	}
	/// Whether the seat holds or is taking an IRC connection.
	pub const fn occupies(self) -> bool {
		matches!(self, Self::Connecting | Self::Linked)
	}
}

/// One member's projection as the room states it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
	pub network: String,
	pub phase: Phase,
	pub nick: String,
}

/// What IRC calls one of its seats, and what it says about it: the badge
/// short and upper-case for a chip beside a name, the sentence naming the
/// network and the nick over there.
pub fn words(view: &View) -> (&'static str, String) {
	match view.phase {
		Phase::Rooms => ("ROOMS", "Rooms only".into()),
		Phase::Connecting => ("LINKING", format!("Linking {} as {}", view.network, view.nick)),
		Phase::Linked => ("LINKED", format!("Rooms + {} as {}", view.network, view.nick)),
		Phase::Failed => ("FAILED", format!("{} link failed as {}", view.network, view.nick)),
	}
}

/// Where a seat stands, in IRC's words, including where the connection
/// reaches when a bridge knows: a reader deciding whether to hand over a
/// password is owed the endpoint it will be handed to.
fn said(view: &View, origin: &str, tls: bool) -> String {
	let reaches = if origin.is_empty() {
		String::new()
	} else {
		format!(" The connection reaches {origin}.")
	};
	// A cleartext connection cannot carry a password safely, so the
	// registered-account login is not drawn on it. Say so, rather than leave
	// a reader looking for a field that was silently withheld.
	let login = if tls {
		String::new()
	} else {
		format!(
			" Logging in to a registered {} account needs an encrypted connection, so it is not offered here.",
			view.network
		)
	};
	let standing = match view.phase {
		Phase::Rooms => format!("Rooms only. You are not present on {}.", view.network),
		Phase::Connecting => format!("Connecting to {} as <{}>…", view.network, view.nick),
		Phase::Linked => format!("Rooms and {} are linked as <{}>.", view.network, view.nick),
		Phase::Failed => format!(
			"The {} link for <{}> failed. Retry it here or stay Rooms only.",
			view.network, view.nick
		),
	};
	format!("{standing}{reaches}{login}")
}

/// What pressing the commitment is called: a different act in each state
/// even though it is one verb underneath.
fn commit(view: &View) -> &'static str {
	match view.phase {
		Phase::Rooms => "Link to IRC",
		Phase::Failed => "Retry IRC link",
		Phase::Connecting | Phase::Linked => "Change IRC identity",
	}
}

/// The form for this seat as it stands. `tls` decides whether the
/// registered-account login is drawn: over an encrypted path the nick sits
/// above a toggle that reveals an account and password. A cleartext
/// connection cannot carry a password safely, so those fields are not
/// drawn and `said` explains their absence.
pub fn identity_form(view: &View, origin: &str, tls: bool) -> Result<Form, crate::bridge::Error> {
	let mut fields = alloc::vec![Field::Leaf(Leaf::Text(TextField::new(
		NICK_FIELD,
		"IRC nick",
		true,
		TextOptions {
			value: Some(&view.nick),
			..Default::default()
		},
	)?))];
	if tls {
		fields.push(Field::Toggle(ToggleField::new(
			REGISTERED_FIELD,
			"Log in to a registered IRC account",
			None,
			false,
			alloc::vec![
				Leaf::Text(TextField::new(ACCOUNT_FIELD, "Account", true, TextOptions::default())?),
				Leaf::Secret(SecretField::new(PASSWORD_FIELD, "Password", true, None)?),
			],
		)?));
	}
	let mut actions = alloc::vec![Action::new(
		LINK_ACTION,
		commit(view),
		"Linking to IRC…",
		Tone::Primary,
		true,
		None,
	)?];
	// Nothing to stop when nobody is on IRC, so the way out is absent rather
	// than present and refused. Ending an established or standing link takes
	// a member off IRC, so it asks first; cancelling a link still connecting
	// has nothing to take away.
	if view.phase != Phase::Rooms {
		let confirm = if view.phase == Phase::Connecting {
			None
		} else {
			Some(Confirm::new(
				&format!(
					"Disconnect from {}? You will leave it and stay Rooms only until you link again.",
					view.network
				),
				"Stay linked",
				&format!("Disconnect from {}", view.network),
			)?)
		};
		actions.push(Action::new(
			DISCONNECT_ACTION,
			&if view.phase == Phase::Connecting {
				"Cancel IRC link".into()
			} else {
				format!("Disconnect from {}", view.network)
			},
			"Disconnecting…",
			Tone::Quiet,
			true,
			confirm,
		)?);
	}
	// One identity per network, shared by every channel on it: linking in
	// one room links in all of them.
	Form::new(
		&view.network,
		&format!("Your {} identity", view.network),
		&said(view, origin, tls),
		fields,
		actions,
	)
}

/// The identity a member asked for: a nick, and a login when they gave one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
	pub nick: String,
	pub sasl: Option<super::registration::SaslPlain>,
}

/// What the room answers a member who chose an identity.
pub fn linked_said(network: &str, identity: &Identity) -> String {
	match &identity.sasl {
		None => format!("you now speak on IRC as <{}> across {network}", identity.nick),
		Some(sasl) if sasl.account == identity.nick => {
			format!(
				"you now speak on IRC as <{}> across {network}, logged in",
				identity.nick
			)
		}
		Some(sasl) => format!(
			"you now speak on IRC as <{}> across {network}, logged into {}",
			identity.nick, sasl.account
		),
	}
}

pub fn disconnected_said(network: &str) -> String {
	format!("you now appear only in Rooms across {network}")
}

/// Read one submitted identity form back: what makes a nick or a password
/// valid on IRC is IRC's, checked whatever a client believed about the form
/// it drew. A login on a cleartext bridge is refused before any dial.
pub fn read_identity(answers: &crate::bridge::Answers, tls: bool) -> Result<Identity, Invalid> {
	let field = |id: &str| -> String {
		answers
			.get(id)
			.and_then(|text| text.as_str().map(String::from))
			.unwrap_or_default()
	};
	let nick = field(NICK_FIELD);
	let account = field(ACCOUNT_FIELD);
	let password = field(PASSWORD_FIELD);
	super::registration::validate_nick(&nick)?;
	if account.is_empty() && password.is_empty() {
		return Ok(Identity { nick, sasl: None });
	}
	if !tls {
		return Err(Invalid::CleartextLogin);
	}
	let sasl = super::registration::SaslPlain { account, password };
	super::registration::validate_sasl_plain(&sasl)?;
	Ok(Identity { nick, sasl: Some(sasl) })
}

/// Why a submitted identity form is refused. `Display` is the exact line
/// the reader sees.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The nick or login was refused by IRC registration.
	Registration(RegistrationInvalid),
	/// A login was submitted on a bridge without TLS.
	CleartextLogin,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Registration(source) => write!(f, "{source}"),
			Self::CleartextLogin => {
				f.write_str("this bridge runs without TLS; a registered account needs an encrypted path")
			}
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

impl From<RegistrationInvalid> for Invalid {
	fn from(source: RegistrationInvalid) -> Self {
		Self::Registration(source)
	}
}

/// Every seat word a snapshot or form carries, kept together so a bound on
/// one is a bound on all.
pub fn phases() -> Vec<Phase> {
	alloc::vec![Phase::Rooms, Phase::Connecting, Phase::Linked, Phase::Failed]
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bridge::Answers;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		assert_eq!(
			Invalid::CleartextLogin.to_string(),
			"this bridge runs without TLS; a registered account needs an encrypted path"
		);
		assert_eq!(
			Invalid::Registration(RegistrationInvalid::SaslAborted).to_string(),
			"IRC server aborted SASL authentication"
		);
	}

	fn view(phase: Phase) -> View {
		View {
			network: "libera".into(),
			phase,
			nick: "alice".into(),
		}
	}

	#[test]
	fn the_words_and_forms_follow_the_phase() {
		assert_eq!(words(&view(Phase::Rooms)), ("ROOMS", "Rooms only".into()));
		assert_eq!(words(&view(Phase::Linked)).1, "Rooms + libera as alice");
		let sealed = identity_form(&view(Phase::Linked), "irc.example:6697", true).unwrap();
		assert_eq!(sealed.fields.as_slice().len(), 2);
		assert_eq!(sealed.actions().len(), 2);
		assert!(sealed.actions()[1].confirm.is_some());
		assert!(
			sealed
				.encode()
				.unwrap()
				.contains("The connection reaches irc.example:6697.")
		);
		let clear = identity_form(&view(Phase::Rooms), "", false).unwrap();
		assert_eq!(clear.fields.as_slice().len(), 1);
		assert_eq!(clear.actions().len(), 1);
		assert!(clear.encode().unwrap().contains("not offered here"));
		let connecting = identity_form(&view(Phase::Connecting), "", true).unwrap();
		assert!(connecting.actions()[1].confirm.is_none());
	}

	#[test]
	fn a_submitted_identity_is_validated_on_ircs_terms() {
		let anonymous = Answers::decode(r#"{"nick":"alice"}"#).unwrap();
		assert_eq!(
			read_identity(&anonymous, false).unwrap(),
			Identity {
				nick: "alice".into(),
				sasl: None
			}
		);
		let login = Answers::decode(r#"{"nick":"alice","account":"acct","password":"pw"}"#).unwrap();
		assert!(
			read_identity(&login, false)
				.unwrap_err()
				.to_string()
				.contains("encrypted")
		);
		assert!(read_identity(&login, true).unwrap().sasl.is_some());
		let bad = Answers::decode(r#"{"nick":"1bad"}"#).unwrap();
		assert!(read_identity(&bad, true).is_err());
		assert_eq!(
			linked_said("libera", &read_identity(&login, true).unwrap()),
			"you now speak on IRC as <alice> across libera, logged into acct"
		);
	}
}
