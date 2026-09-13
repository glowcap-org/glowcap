//! The IRC gateway described as a bridge gateway: its two forms, its words,
//! and its connections with the channel leases nested beneath them, as the
//! JSON the Operations pane draws. Passwords never enter this projection.
//! The answer readers read a submission back against the forms declared
//! here.
use super::{Bridge, FeedStatus, Gateway, Network};
use crate::{
	bridge::{Action, Answers, Field, Form, Leaf, SecretField, TextField, TextOptions, ToggleField, Tone},
	fields::{List, Text},
	server::irc::model::{MAX_NAME, MAX_NETWORK_NAME, NetworkChoice, Sasl},
};
use alloc::{
	format,
	string::{String, ToString},
	vec::Vec,
};

/// The field ids the IRC gateway forms declare, the one contract between
/// the form drawn and the answers read back.
pub const NAME: &str = "name";
pub const HOST: &str = "host";
pub const PORT: &str = "port";
pub const NICK: &str = "nick";
pub const REALNAME: &str = "realname";
pub const TLS: &str = "tls";
pub const ACCOUNT: &str = "account";
pub const PASSWORD: &str = "password";
pub const CHANNEL: &str = "channel";
pub const OPERATOR_PERMISSION: &str = "permission";
pub const OPEN_ACTION: &str = "open";
pub const ADD_ACTION: &str = "add";

pub use crate::bridge::gateway::{
	Connection, Description, Fact, Lease, LeaseRemoval, MAX_GATEWAY_JSON, Status, StatusTone,
};
use crate::bridge::{MAX_FORM_SAID, MAX_FORM_VALUE};

fn text<const N: usize, const E: bool>(value: &str) -> Text<N, E> {
	Text::new(value.into()).expect("a bounded gateway text")
}

/// A diagnostic or stated fact is shown, never owned back: a longer text
/// is cut to fit rather than allowed to make the whole snapshot
/// unparseable exactly when an operator needs to read it.
fn shown(value: &str, max: usize) -> String {
	let units: Vec<u16> = value.encode_utf16().collect();
	if units.len() <= max {
		return value.into();
	}
	let mut cut = max - 1;
	if (0xd800..=0xdbff).contains(&units[cut - 1]) {
		cut -= 1;
	}
	let mut out = String::from_utf16_lossy(&units[..cut]);
	out.push('…');
	out
}

/// The form IRC asks Rooms to draw for a new network connection.
pub fn connection_form() -> Result<Form, crate::bridge::Error> {
	let text_field = |id, label, placeholder, hint, required| {
		TextField::new(
			id,
			label,
			required,
			TextOptions {
				placeholder: Some(placeholder),
				hint,
				value: if id == NAME { Some("") } else { None },
				..Default::default()
			},
		)
		.map(|field| Field::Leaf(Leaf::Text(field)))
	};
	Form::new(
		"connection",
		"New IRC connection",
		"This creates the network capability only. Add channels after it appears.",
		alloc::vec![
			text_field(NAME, "Name", "Libera", None, true)?,
			text_field(HOST, "Server", "irc.libera.chat", None, true)?,
			text_field(PORT, "Port", "6697", Some("6697 with TLS, 6667 without"), false)?,
			text_field(NICK, "Feed nick", "glowcap-rooms", None, true)?,
			text_field(
				REALNAME,
				"Bot real name",
				"glowcap Rooms bridge bot; admin: your Libera nick",
				Some("Identify this as a bot and name an administrator reachable on IRC."),
				true,
			)?,
			text_field(ACCOUNT, "Account", "optional", None, false)?,
			Field::Leaf(Leaf::Secret(SecretField::new(
				PASSWORD,
				"Password",
				false,
				Some("sent to your server"),
			)?)),
			Field::Toggle(ToggleField::new(TLS, "TLS", None, true, Vec::new())?),
		],
		alloc::vec![Action::new(
			OPEN_ACTION,
			"Open connection",
			"Opening…",
			Tone::Primary,
			false,
			None,
		)?],
	)
}

/// The form IRC asks Rooms to draw for a new channel under a connection.
pub fn lease_form() -> Result<Form, crate::bridge::Error> {
	Form::new(
		"lease",
		"Add channel",
		"",
		alloc::vec![
			Field::Leaf(Leaf::Text(TextField::new(
				CHANNEL,
				"Channel",
				true,
				TextOptions {
					prefix: Some("#"),
					placeholder: Some("nowhere"),
					..Default::default()
				},
			)?)),
			Field::Toggle(ToggleField::new(
				OPERATOR_PERMISSION,
				"The channel's operators permit this bridge",
				Some("They have explicitly allowed the bridge and the history it makes visible."),
				false,
				Vec::new(),
			)?),
		],
		alloc::vec![Action::new(ADD_ACTION, "Join", "Joining…", Tone::Primary, false, None)?],
	)
}

fn network_status(status: FeedStatus) -> Status {
	let (label, tone) = match status {
		FeedStatus::Up => ("connected", StatusTone::Ok),
		FeedStatus::Connecting => ("connecting", StatusTone::Pending),
		FeedStatus::Backoff => ("reconnecting", StatusTone::Pending),
		FeedStatus::Dormant => ("ready", StatusTone::Idle),
	};
	Status {
		label: text(label),
		tone,
	}
}

fn channel_status(status: FeedStatus) -> Status {
	let (label, tone) = match status {
		FeedStatus::Up => ("live", StatusTone::Ok),
		FeedStatus::Backoff => ("reconnecting", StatusTone::Pending),
		FeedStatus::Connecting | FeedStatus::Dormant => ("connecting", StatusTone::Pending),
	};
	Status {
		label: text(label),
		tone,
	}
}

fn connection_row<C: Copy + Ord, R: Clone>(network: &Network, leases: Vec<&Bridge<C, R>>) -> Connection {
	let choice = &network.choice;
	let mut facts = alloc::vec![
		Fact {
			label: text("Endpoint"),
			value: text(&shown(&choice.endpoint(), MAX_FORM_VALUE)),
		},
		Fact {
			label: text("Security"),
			value: text(if choice.tls { "TLS" } else { "cleartext" }),
		},
		Fact {
			label: text("Nick"),
			value: text(&shown(&choice.nick, MAX_FORM_VALUE)),
		},
		Fact {
			label: text("Real name"),
			value: text(&shown(&choice.realname, MAX_FORM_VALUE)),
		},
	];
	if let Some(sasl) = &choice.sasl {
		facts.push(Fact {
			label: text("Account"),
			value: text(&shown(&sasl.account, MAX_FORM_VALUE)),
		});
	}
	Connection {
		id: text(&choice.network),
		title: text(&choice.network),
		facts: List::new(facts).expect("four facts"),
		status: network_status(network.status),
		problem: text(&shown(&network.problem, MAX_FORM_SAID)),
		leases: List::new(
			leases
				.into_iter()
				.map(|bridge| Lease {
					id: text(bridge.room.channel()),
					title: text(bridge.room.channel()),
					status: channel_status(bridge.status),
					problem: text(&shown(&bridge.problem, MAX_FORM_SAID)),
					room_name: Some(text(bridge.room.name())),
					publication_id: text(bridge.room.publication_id()),
				})
				.collect(),
		)
		.expect("bounded leases"),
	}
}

/// Describe the whole IRC gateway as a bridge gateway.
pub fn describe<C: Copy + Ord, R: Clone>(gateway: &Gateway<C, R>) -> Result<Description, String> {
	let connections = gateway
		.networks()
		.map(|network| {
			let leases = gateway
				.bridges_of(&network.choice.network)
				.filter(|(_, bridge)| !bridge.stopped)
				.map(|(_, bridge)| bridge)
				.collect();
			connection_row(network, leases)
		})
		.collect();
	Ok(Description {
		title: text("IRC bridges"),
		description: text(
			"IRC networks this server may administer. Each connection owns an identity, and its channels become ordinary Rooms rooms. Members speak on IRC under their own network identity.",
		),
		connection_noun: text("connection"),
		connection_noun_plural: text("connections"),
		lease_noun: text("channel"),
		lease_noun_plural: text("channels"),
		lease_removal: LeaseRemoval {
			label: text("Part"),
			say: text("Parting closes its bridged Rooms room and ends every current membership."),
			keep: text("Keep channel"),
			commit: text("Part channel"),
		},
		connection_form: connection_form().map_err(|e| e.to_string())?,
		lease_form: lease_form().map_err(|e| e.to_string())?,
		connections: List::new(connections).ok_or("too many IRC networks to describe")?,
	})
}

fn answer(answers: &Answers, id: &str) -> String {
	answers
		.get(id)
		.and_then(|value| value.as_str().map(String::from))
		.unwrap_or_default()
}

/// Read a connection-open submission back against the form above into
/// IRC's own network choice.
pub fn connection_choice(raw: &str) -> Result<NetworkChoice, String> {
	let answers = Answers::decode(raw).map_err(|e| e.to_string())?;
	let name = answer(&answers, NAME).trim().to_string();
	let host = answer(&answers, HOST).trim().to_string();
	let nick = answer(&answers, NICK).trim().to_string();
	let realname = answer(&answers, REALNAME).trim().to_string();
	if name.is_empty() || host.is_empty() || nick.is_empty() || realname.is_empty() {
		return Err("a connection needs a name, a server, a nick, and a bot real name".into());
	}
	if name.encode_utf16().count() > MAX_NETWORK_NAME {
		return Err(format!(
			"a connection name stays within {MAX_NETWORK_NAME} characters so its channel room names fit"
		));
	}
	let tls = answer(&answers, TLS) == "on";
	let port_text = answer(&answers, PORT).trim().to_string();
	let port = if port_text.is_empty() {
		if tls { 6697 } else { 6667 }
	} else {
		port_text
			.parse::<u16>()
			.ok()
			.filter(|port| *port >= 1)
			.ok_or("a connection needs a real port")?
	};
	// A filled account is a login. Its password is left for the SASL
	// validation the gateway runs, which names an empty one and the TLS
	// requirement together. A password with no account would otherwise
	// vanish without refusal; a credential is never silently dropped.
	let account = answer(&answers, ACCOUNT).trim().to_string();
	let password = answer(&answers, PASSWORD);
	if account.is_empty() && !password.is_empty() {
		return Err("a password needs the account it logs into; fill Account or clear Password".into());
	}
	Ok(NetworkChoice {
		network: name,
		host,
		port,
		tls,
		nick,
		realname,
		sasl: if account.is_empty() {
			None
		} else {
			Some(Sasl { account, password })
		},
	})
}

/// Read an add-lease submission into IRC's channel name with its leading
/// `#`: the form draws the mark as a fixed prefix, so it is completed when
/// the reader left it off and the typed characters are otherwise kept.
pub fn lease_channel(raw: &str) -> Result<String, String> {
	let answers = Answers::decode(raw).map_err(|e| e.to_string())?;
	if answer(&answers, OPERATOR_PERMISSION) != "on" {
		return Err("joining an IRC channel requires explicit permission from its operators".into());
	}
	let typed = answer(&answers, CHANNEL).trim().to_string();
	if typed.is_empty() || typed.trim_start_matches('#').is_empty() {
		return Err("a channel name is required".into());
	}
	let channel = if typed.starts_with('#') {
		typed
	} else {
		format!("#{typed}")
	};
	if channel.encode_utf16().count() > MAX_NAME {
		return Err(format!("a channel name stays within {MAX_NAME} characters"));
	}
	Ok(channel)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::server::irc::model::channel_key;

	#[test]
	fn answers_are_read_back_against_the_forms() {
		let choice = connection_choice(
			r#"{"name":"net","host":"irc.example","port":"","nick":"feed","realname":"bridge bot; admin: alice","tls":"on","account":"a","password":"p"}"#,
		)
		.unwrap();
		assert_eq!(choice.port, 6697);
		assert!(choice.tls);
		assert_eq!(choice.realname, "bridge bot; admin: alice");
		assert_eq!(choice.sasl.unwrap().account, "a");
		assert!(connection_choice("{").is_err());
		assert!(connection_choice(r#"{}"#).is_err());
		assert!(connection_choice(r#"{"name":"n","host":"h","nick":"f","port":"not-a-port"}"#).is_err());
		assert!(connection_choice(r#"{"name":"n","host":"h","nick":"f","password":"p"}"#).is_err());
		assert!(
			connection_choice(&format!(
				r#"{{"name":"{}","host":"h","nick":"f","realname":"bot; admin: alice"}}"#,
				"n".repeat(MAX_NETWORK_NAME + 1)
			))
			.is_err()
		);
		assert!(lease_channel(r#"{"channel":"linux"}"#).is_err());
		assert_eq!(
			lease_channel(r#"{"channel":"linux","permission":"on"}"#).unwrap(),
			"#linux"
		);
		assert_eq!(
			lease_channel(r###"{"channel":"##linux","permission":"on"}"###).unwrap(),
			"##linux"
		);
		assert!(lease_channel(r###"{"channel":"#","permission":"on"}"###).is_err());
	}

	#[test]
	fn the_description_round_trips_and_hides_passwords() {
		let mut gateway: Gateway<u32, u8> = Gateway::default();
		gateway
			.open_network(NetworkChoice {
				network: "net".into(),
				host: "irc.example".into(),
				port: 6697,
				tls: true,
				nick: "feed".into(),
				realname: "bridge bot; admin: alice".into(),
				sasl: Some(Sasl {
					account: "acct".into(),
					password: "hunter2".into(),
				}),
			})
			.unwrap();
		gateway.join_bridge("net", "#room", "pub", &|_, _| false).unwrap();
		gateway.started(&channel_key("net", "#room"));
		let description = describe(&gateway).unwrap();
		let raw = description.encode().unwrap();
		assert!(!raw.contains("hunter2"));
		assert!(raw.contains("\"Account\""));
		let back = Description::decode(&raw).unwrap();
		assert_eq!(back.connections.as_slice().len(), 1);
		let connection = &back.connections.as_slice()[0];
		assert_eq!(connection.status.label.text().as_str(), Some("connecting"));
		assert_eq!(
			connection.leases.as_slice()[0].publication_id.text().as_str(),
			Some("pub")
		);
		assert!(Description::decode("").is_err());
		assert!(Description::decode("{}").is_err());
		assert_eq!(shown("abc", 2), "a…");
	}
}
