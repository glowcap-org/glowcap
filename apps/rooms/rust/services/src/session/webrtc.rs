//! The peer's WebRTC, signaled through its directories.
//!
//! The peer never dials a browser on its own. A dial opens when the Host
//! follows a reference a directory handed over, and that directory carries the
//! offer, the answer and the candidates, the same way it does between two
//! browsers. [`Directories`] holds the session's current signaling routes, one
//! per directory it is a named member of, and answers the platform adapter's
//! lookup by the introducing session's designator. [`Answering`] files an
//! answering inbox through each route and hands the offers members send to
//! the WebRTC listener. [`ice_servers`] reads the `--ice-servers` option.
use super::{
	error::Error,
	notice::{Notice, Report},
};
use glowcap::webrtc::{IceServer, Server};
use rooms_application::{
	ice::{Limits, Servers},
	signaling::Incoming,
};
use rooms_glowcap::client::{
	Error as ClientError, Tasks,
	directory::signaling::{Exchange, Route},
};
use rooms_platform::{
	HostPlatform,
	signaling::{DirectorySignaling, Exchanges},
};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::Rc,
};

const LIMITS: Limits = Limits {
	servers: glowcap::WEBRTC_MAX_ICE_SERVERS,
	urls: glowcap::WEBRTC_MAX_ICE_URLS_PER_SERVER,
	url_bytes: glowcap::WEBRTC_MAX_ICE_URL_BYTES,
	credential_bytes: glowcap::WEBRTC_MAX_ICE_CREDENTIAL_BYTES,
};

/// The ICE servers a dial gathers candidates through. The value is the same
/// one the web server takes in `GLOWCAP_ROOMS_ICE_SERVERS`: STUN URLs
/// separated by commas, an empty value for none, and a public STUN server when
/// the option is absent. A value that starts with `[` is a JSON list of ICE
/// server records, the shape browsers take, so a TURN server can carry its
/// username and credential.
pub fn ice_servers(configured: Option<&str>) -> Result<Vec<IceServer>, Error> {
	let configured = configured.map(str::trim);
	let servers = match configured {
		Some(json) if json.starts_with('[') => Servers::from_json(json.as_bytes(), LIMITS),
		other => Servers::stun(other, LIMITS),
	}
	.map_err(|reason| Error::refused(format!("ICE servers: {reason}")))?;
	Ok(servers
		.iter()
		.map(|server| IceServer {
			urls: server.urls().to_vec(),
			username: server.username().unwrap_or_default().to_owned(),
			credential: server.credential().unwrap_or_default().to_owned(),
		})
		.collect())
}

/// The session's signaling routes, keyed by directory row id. The session's
/// route job replaces the set as the workspace changes, and each dial reads
/// it when its signaling starts.
#[derive(Clone, Default)]
pub struct Directories(Rc<RefCell<BTreeMap<String, Route<HostPlatform>>>>);
impl Directories {
	pub fn replace(&self, routes: BTreeMap<String, Route<HostPlatform>>) {
		*self.0.borrow_mut() = routes;
	}
}
impl Exchanges for Directories {
	type Exchange = Exchange<HostPlatform>;
	type Reply = Route<HostPlatform>;
	/// The one route whose directory session is the introducer. A closed
	/// session matches nothing, so a dial introduced through a directory the
	/// peer has lost is refused rather than signaled through a stranger.
	fn open(&self, introducer: &str, designator: &str) -> Result<Option<Self::Exchange>, ClientError> {
		let routes = self.0.borrow();
		let mut matching = routes.values().filter(|route| {
			route.session().is_some_and(|session| {
				session
					.partner_identity()
					.is_ok_and(|identity| identity.designator == introducer)
			})
		});
		let Some(route) = matching.next() else {
			return Ok(None);
		};
		if matching.next().is_some() {
			return Err(ClientError::Observation(format!(
				"two directories are served by the session {introducer}, so neither is the signaling route"
			)));
		}
		route.signaling_exchange(designator).map(Some)
	}
}

/// The authority the peer signals through, dialing and answering.
pub type Authority = DirectorySignaling<HostPlatform, Directories>;

/// One answering inbox per signaling route. Each files itself with its
/// directory and hands the offers it receives to the WebRTC listener.
pub struct Answering {
	authority: Rc<Authority>,
	server: Rc<Server>,
	report: Report,
	inboxes: RefCell<BTreeMap<String, Inbox>>,
}
struct Inbox {
	route: Route<HostPlatform>,
	/// Set once the inbox's pump has stopped, so the next route set files it
	/// again.
	ended: Rc<Cell<bool>>,
	_pump: <HostPlatform as Tasks>::Task,
}
impl Answering {
	pub fn new(authority: Rc<Authority>, server: Rc<Server>, report: Report) -> Self {
		Self {
			authority,
			server,
			report,
			inboxes: RefCell::default(),
		}
	}
	/// Keep one live inbox per route in `routes`. An inbox whose route left
	/// the set is closed, and one whose pump stopped, after a refusal or its
	/// directory closing, is filed again.
	pub fn follow(&self, routes: &BTreeMap<String, Route<HostPlatform>>) {
		let mut inboxes = self.inboxes.borrow_mut();
		inboxes.retain(|id, inbox| {
			routes
				.get(id)
				.is_some_and(|route| route.same(&inbox.route) && !inbox.ended.get())
		});
		for (id, route) in routes {
			if inboxes.contains_key(id) {
				continue;
			}
			let ended = Rc::new(Cell::new(false));
			let pump = HostPlatform.spawn(pump(
				route.clone(),
				self.authority.clone(),
				self.server.clone(),
				self.report.clone(),
				ended.clone(),
			));
			inboxes.insert(
				id.clone(),
				Inbox {
					route: route.clone(),
					ended,
					_pump: pump,
				},
			);
		}
	}
}

/// File an inbox through `route` and hand each offer and candidate it
/// receives to the listener until the inbox ends.
async fn pump(
	route: Route<HostPlatform>,
	authority: Rc<Authority>,
	server: Rc<Server>,
	report: Report,
	ended: Rc<Cell<bool>>,
) {
	let failed = |cause: String| {
		report(Notice::Activity {
			operation: "WebRTC answering".into(),
			cause: glowcap::loam::refusal(cause),
		})
	};
	match route.signaling_inbox().await {
		Err(error) => failed(error.to_string()),
		Ok(mut inbox) => {
			let reply = Rc::new(route);
			loop {
				match inbox.next().await {
					Ok(Some(Incoming::Offer { id, description, from })) => {
						if let Err(error) = authority.offered(&server, reply.clone(), id, from, &description) {
							failed(error.to_string());
						}
					}
					Ok(Some(Incoming::Candidate { id, candidate })) => authority.far_candidate(&id, &candidate),
					Ok(None) => break,
					Err(error) => {
						failed(error.to_string());
						break;
					}
				}
			}
		}
	}
	ended.set(true);
}

#[cfg(test)]
mod tests {
	use super::ice_servers;

	#[test]
	fn ice_servers_take_the_web_server_grammar_and_json_records() {
		let absent = ice_servers(None).unwrap();
		assert_eq!(absent.len(), 1);
		assert!(absent[0].urls[0].starts_with("stun:"));
		assert!(ice_servers(Some("")).unwrap().is_empty());
		let listed = ice_servers(Some("stun:one.example:3478, stun:two.example")).unwrap();
		assert_eq!(listed.len(), 2);
		assert_eq!(listed[1].urls, ["stun:two.example"]);
		assert!(listed[1].username.is_empty());
		let records = ice_servers(Some(
			r#"[{"urls":"stun:one.example"},{"urls":["turn:relay.example"],"username":"u","credential":"c"}]"#,
		))
		.unwrap();
		assert_eq!(records[1].urls, ["turn:relay.example"]);
		assert_eq!(
			(records[1].username.as_str(), records[1].credential.as_str()),
			("u", "c")
		);
		let refused = ice_servers(Some("turn:relay.example")).unwrap_err().to_string();
		assert!(refused.contains("ICE servers"), "{refused}");
		assert!(ice_servers(Some("http://one.example")).is_err());
		assert!(ice_servers(Some("[{\"urls\":\"stun:one.example\"}")).is_err());
	}
}
