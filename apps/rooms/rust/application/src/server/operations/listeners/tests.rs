use super::*;
use alloc::vec;

/// A wire value the asks are read from.
#[derive(Clone, Debug)]
enum V {
	Text(String),
	Int(i128),
	List(Vec<V>),
}
impl ArgumentView for V {
	fn boolean(&self) -> Option<bool> {
		None
	}
	fn is_null(&self) -> bool {
		false
	}
	fn text(&self) -> Option<&str> {
		match self {
			Self::Text(text) => Some(text),
			_ => None,
		}
	}
	fn integer(&self) -> Option<i128> {
		match self {
			Self::Int(n) => Some(*n),
			_ => None,
		}
	}
	fn float(&self) -> Option<f64> {
		None
	}
	fn contains_capability(&self) -> bool {
		false
	}
}
impl ListArgument for V {
	fn list_len(&self) -> Option<usize> {
		match self {
			Self::List(items) => Some(items.len()),
			_ => None,
		}
	}
	fn at(&self, index: usize) -> Option<Self> {
		match self {
			Self::List(items) => items.get(index).cloned(),
			_ => None,
		}
	}
}
fn t(text: &str) -> V {
	V::Text(text.into())
}
fn pair(name: &str, value: V) -> V {
	V::List(vec![t(name), value])
}

struct Env(BTreeMap<&'static str, &'static str>);
impl Environment for Env {
	fn env(&self, name: &str) -> Option<String> {
		self.0.get(name).map(|s| s.to_string())
	}
}

#[test]
fn an_up_is_read_exactly() {
	let (transport, ask) = Ask::read(&[
		t(Transport::KeyedTcp.name()),
		V::List(vec![pair("port", V::Int(7)), pair("bind", t("::1"))]),
	])
	.unwrap();
	assert_eq!(transport, Transport::KeyedTcp);
	assert_eq!(ask.port, Some(7));
	assert_eq!(ask.bind.as_deref(), Some("::1"));
	let intent = ask.intent(transport);
	assert_eq!(Ask::from_intent(&intent), ask);
	let refused = |args: &[V]| Ask::read(args).unwrap_err().reason();
	assert_eq!(refused(&[]), "up takes a transport and, optionally, its named options");
	assert!(refused(&[t("carrier-pigeon")]).starts_with("listener-unsupported: \"carrier-pigeon\" names no transport"));
	assert_eq!(
		refused(&[t("iroh"), V::List(vec![pair("port", V::Int(1))])]),
		"a iroh listener has no \"port\" option"
	);
	assert_eq!(
		refused(&[t("tcp"), V::List(vec![pair("relay", t("x"))])]),
		"a tcp listener has no \"relay\" option (it takes bind, port, advertise)"
	);
	assert_eq!(
		refused(&[
			t("tcp"),
			V::List(vec![pair("port", V::Int(1)), pair("port", V::Int(2))])
		]),
		"the port listener option was supplied twice"
	);
	assert_eq!(
		refused(&[t("tcp"), V::List(vec![pair("port", V::Int(70000))])]),
		"port is an integer between 0 and 65535"
	);
	assert_eq!(
		refused(&[t("keyed-relay"), V::List(vec![pair("relay", t(""))])]),
		"relay is a non-empty string under 4 KiB"
	);
	assert_eq!(
		read_down(&[V::Int(0)]).unwrap_err().reason(),
		"down takes the number list answered"
	);
	assert_eq!(read_down(&[V::Int(3)]).unwrap(), 3);
}

#[test]
fn seats_admit_one_listener_per_transport_and_keep_the_announced_one() {
	let env = Env(BTreeMap::new());
	let mut seats = Seats::default();
	let boot = seats.adopt_boot(Transport::Tcp, "127.0.0.1:9".into());
	assert_eq!(boot, 1);
	assert_eq!(
		seats.admit(Transport::Tcp, &env).unwrap_err().code,
		Some(FailureCode::ListenerTransportHeld)
	);
	assert_eq!(
		seats.admit(Transport::Onion, &env).unwrap_err().reason(),
		format!("listener-unsupported: {ONION_NEEDS_TOR}")
	);
	seats.admit(Transport::KeyedTcp, &env).unwrap();
	let id = seats.brought_up(Transport::KeyedTcp, "ocapn://k.keyed-tcp".into(), true);
	assert_eq!(
		seats.take_down(boot).unwrap_err().code,
		Some(FailureCode::ListenerServing)
	);
	assert_eq!(seats.take_down(99).unwrap_err().code, Some(FailureCode::NoSuchListener));
	assert!(seats.take_down(id).is_ok());
	let listed = seats.seats(&env);
	assert_eq!(listed.len(), 7);
	assert!(listed[0].serving);
	assert_eq!(listed[1].live.as_ref().map(|live| live.id), Some(id));
	assert_eq!(listed[6].unavailable, ONION_NEEDS_TOR);
	assert_eq!(
		listed[1].takes[1],
		("port".into(), "port".into(), "an ephemeral port".into())
	);
	seats.went_down(id);
	assert_eq!(seats.live().count(), 1);
}

#[test]
fn hints_follow_the_environment_and_the_relay_register_url_is_derived() {
	let env = Env([
		("GLOWCAP_ROOMS_BIND", "0.0.0.0"),
		("GLOWCAP_ONION_SOCKS", "s"),
		("GLOWCAP_ONION_CONTROL", "c"),
	]
	.into_iter()
	.collect());
	let seats = Seats::default();
	let tcp = seats.seat(Transport::Tcp, &env);
	assert_eq!(tcp.takes[0].2, "0.0.0.0");
	assert!(seats.seat(Transport::Onion, &env).unavailable.is_empty());
	assert_eq!(
		register_url("ws://relay.example:8/relay?x=1#y").unwrap(),
		"ws://relay.example:8/register"
	);
	assert_eq!(
		register_url("http://x/").unwrap_err().detail,
		"A relay URL uses ws or wss, and \"http://x/\" uses neither."
	);
	assert_eq!(
		register_url("nope").unwrap_err().detail,
		"\"nope\" is not a WebSocket URL."
	);
}
