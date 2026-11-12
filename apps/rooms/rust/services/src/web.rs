//! The host web executable owns its supervised directory and HTTP service.
//! Capability sessions belong to peers. This front serves assets and carries
//! opaque transport traffic for browsers.
mod admission;
mod assets;
mod browser_admission;
mod bundle;
mod capabilities;
mod client_address;
mod compiler;
mod config;
mod export;
mod http;
mod ice;
mod notice;
mod prepare;
mod preview;
mod process;
mod proxy;
mod relay;
mod rendezvous;
mod source;
mod status;
mod supervisor;
mod tor;
mod upgrade;
pub use capabilities::CapabilityRead;
use config::BrowserAssets;
pub use config::{Config, HELP};
pub use export::StaticExport;
pub use notice::{Notice, Report};
pub use prepare::Preparation;
pub use status::StatusQuery;
use std::{future::Future, rc::Rc};
use tokio::{net::TcpListener, sync::watch};

/// Serve until `halt` or a failure. `environment` is the process environment
/// the shared session reads its remaining options from, behind what this
/// front hands it.
pub async fn run(
	config: Config,
	environment: impl Fn(&str) -> Option<String>,
	report: Report,
	halt: impl Future<Output = ()>,
) -> Result<(), String> {
	let (stop, stopping) = watch::channel(false);
	let work = serve(config, environment, report, stop.clone(), stopping);
	tokio::pin!(work, halt);
	tokio::select! {
		result = &mut work => result,
		_ = &mut halt => { stop.send_replace(true); work.await }
	}
}
async fn serve(
	config: Config,
	environment: impl Fn(&str) -> Option<String>,
	report: Report,
	stop: watch::Sender<bool>,
	mut stopping: watch::Receiver<bool>,
) -> Result<(), String> {
	let Config {
		bind,
		port,
		public,
		browser_assets,
		browser_admission,
		server,
		server_args,
		room,
		session,
		relay: limits,
		relay_url,
		admission: admission_config,
		ice,
		tor,
	} = config;
	// Acquiring HTTP first prevents a conflicting web start from briefly
	// acquiring directory custody or minting operator capabilities.
	let listener = TcpListener::bind((bind.as_str(), port))
		.await
		.map_err(|e| format!("binding the HTTP listener failed: {e}"))?;
	let address = listener.local_addr().map_err(|e| e.to_string())?;
	let port = address.port();
	// The bound port is the first line on stdout, so a harness that asked for
	// port 0 learns where to reach the front before anything else prints.
	announce(&report, &format!("ROOMS-WEB-LISTENING {port}"));
	// The peers this front runs, the directory and the shared session, stop
	// first: their relay doors stand on this front's relay, so `settle`
	// retires them before it stops the relay and everything else. A halt
	// sends `stop` first, and the relay keeps its sockets until `settle`
	// has retired the peers, since it reads `relay_stop` alone.
	let (peers_stop, peers_stopping) = watch::channel(false);
	let mut peers = tokio::task::JoinSet::new();
	let (relay_stop, relay_stopping) = watch::channel(false);
	let prepared = matches!(&browser_assets, BrowserAssets::Prepared(_));
	let assets = match browser_assets {
		BrowserAssets::Disabled => None,
		BrowserAssets::Source(root) | BrowserAssets::Prepared(root) => {
			let root = tokio::fs::canonicalize(&root)
				.await
				.map_err(|e| format!("opening web assets failed: {e}"))?;
			let Some(assets) = assets::Assets::open(
				root,
				prepared,
				stopping.clone(),
				report.clone(),
				browser_admission.encoded,
			)
			.await?
			else {
				return Ok(());
			};
			Some(assets)
		}
	};
	let ice = ice::Policy::open(ice).await?;
	let admission = admission::Admission::new(admission_config.clone());
	let previews = preview::Preview::open(admission.clone()).await?;
	if *stopping.borrow() {
		return Ok(());
	}
	let tor_endpoints = tor.as_ref().map(|plan| plan.endpoints.clone());
	let mut tor = match tor {
		Some(plan) => match tor::Tor::open(plan, stopping.clone()).await? {
			Some(tor) => Some(tor),
			None => return Ok(()),
		},
		None => None,
	};
	// What this front hands the peers it runs: a named relay as it is, else
	// this server's own relay at its bound address, advertised as browsers
	// dial it, and the private Tor's endpoints.
	let own = config::own_relay(local_relay_url(address), public.as_ref());
	let handed = config::PeerEnvironment {
		relay: config::listener_relay(relay_url.as_deref(), own.clone()),
		tor: tor_endpoints,
	};
	// HTTP serves before either peer opens: the directory's relay doors and
	// the shared session's register at this front's `/register` on their way
	// up, and `/locator` answers "not ready" until the directory's
	// announcement fills the location.
	let (location, current) = watch::channel(None);
	let (session_endpoint, session_forwarding) = watch::channel(None);
	let (jobs, incoming) = tokio::sync::mpsc::channel(32);
	let pages = limits.pages.clone();
	let relay = relay::Relay::with_admission(
		limits,
		current.clone(),
		session_forwarding,
		jobs,
		relay_stopping,
		report.clone(),
		admission,
	);
	// The address every printed link names: the operator's public one, else
	// the loopback address of the port this process bound.
	let reached_at = public.map_or_else(|| format!("http://localhost:{port}/"), |public| public.to_string());
	let mut workers = tokio::task::JoinSet::new();
	if let Some(assets) = &assets {
		workers.spawn_local(assets.clone().run());
	}
	workers.spawn_local(http::serve(
		listener,
		Rc::new(http::Environment {
			assets,
			ice,
			location: current,
			page: pages.first().map(|page| page_link(page, &reached_at).to_string()),
			previews: Rc::new(previews),
			relay,
			report: report.clone(),
			trusted_proxies: admission_config.trusted_proxies,
		}),
		incoming,
		stop.clone(),
		stopping.clone(),
	));
	// The shared session reads its options now, with what the front hands it,
	// so a relay door registers at the relay that is serving.
	let shared = match session {
		Some(session) => {
			let opened = match config::session_config(session.args, |key| handed.read(&environment, key)) {
				Ok(config) => open_shared_session(config, &own, &mut tor, &stop, &report).await,
				Err(error) => Err(error),
			};
			match opened {
				Ok(peer) => Some(peer),
				Err(error) => return settle(Err(error), &stop, &relay_stop, &peers_stop, peers, workers, tor).await,
			}
		}
		None => None,
	};
	// The browser leg of a shared session attachment comes through this relay,
	// so a page is offered the session only when a browser reaches it through
	// this relay, and a TCP door joins the relay's forwarding targets.
	let session_links = shared
		.as_ref()
		.map(|peer| (peer.link().to_owned(), peer.management_link().to_owned()));
	let session_offered = shared
		.as_ref()
		.is_some_and(|peer| match relay::session_reach(peer.link()) {
			None => false,
			Some(relay::SessionReach::Direct) => true,
			Some(relay::SessionReach::Forwarded(endpoint)) => {
				session_endpoint.send_replace(Some(endpoint));
				true
			}
		});
	if let Some(peer) = shared {
		let mut session_stop = peers_stopping.clone();
		peers.spawn_local(async move { peer.run(stopped(&mut session_stop)).await.map_err(|e| e.to_string()) });
	}
	// A worker or the shared session that fails while the directory opens is
	// read at the select below, so the open runs to its own end first, inside
	// the deadline the supervisor holds its announcement to.
	let opened = open_beside_tor(
		supervisor::Supervisor::open(server, server_args, room, handed, stopping.clone(), report.clone()),
		&mut tor,
		&stop,
		async |opened| match opened {
			Some((owner, _)) => owner.close().await,
			None => Ok(()),
		},
	)
	.await;
	let (supervisor, mut locator) = match opened {
		Ok(Some(started)) => started,
		Ok(None) => return settle(Ok(()), &stop, &relay_stop, &peers_stop, peers, workers, tor).await,
		Err(error) => return settle(Err(error), &stop, &relay_stop, &peers_stop, peers, workers, tor).await,
	};
	// The minted links print once and stay out of the watch, which holds
	// routing data for every handler that reads it.
	let capabilities = std::mem::take(&mut locator.capabilities);
	let block = serving_block(
		&pages,
		&reached_at,
		&locator.location,
		session_links.as_ref(),
		session_offered,
		&capabilities,
	);
	location.send_replace(Some(locator));
	peers.spawn_local(supervisor.run(location, peers_stopping));
	announce(&report, &block);
	let result = tokio::select! {
		_ = stopped(&mut stopping) => Ok(()),
		ended = tor_ended(&mut tor) => Err(ended),
		Some(ended) = peers.join_next() => ended.map_err(|e| e.to_string()).and_then(|r| r),
		ended = workers.join_next() => ended.ok_or("web service owner disappeared".to_owned())
			.and_then(|r| r.map_err(|e| e.to_string())).and_then(|r| r),
	};
	settle(result, &stop, &relay_stop, &peers_stop, peers, workers, tor).await
}

type Tasks = tokio::task::JoinSet<Result<(), String>>;

/// Stop the peers first and wait for them, then stop the relay with every
/// other worker and wait for them, and retire Tor, keeping the first failure
/// and every later one it did not already name. A task's own failure arrives
/// here with every stop unsent, so this sends them. The HTTP listener drains
/// its relay sockets, so it ends once the relay has.
async fn settle(
	mut result: Result<(), String>,
	stop: &watch::Sender<bool>,
	relay_stop: &watch::Sender<bool>,
	peers_stop: &watch::Sender<bool>,
	mut peers: Tasks,
	mut workers: Tasks,
	tor: Option<tor::Tor>,
) -> Result<(), String> {
	peers_stop.send_replace(true);
	while let Some(ended) = peers.join_next().await {
		crate::cleanup::retain(&mut result, ended.map_err(|e| e.to_string()).and_then(|r| r));
	}
	stop.send_replace(true);
	relay_stop.send_replace(true);
	while let Some(ended) = workers.join_next().await {
		crate::cleanup::retain(&mut result, ended.map_err(|e| e.to_string()).and_then(|r| r));
	}
	if let Some(tor) = tor {
		crate::cleanup::retain(&mut result, tor.close().await);
	}
	result
}

/// The block a person reads once everything serves. The addresses come
/// first, led by each Rooms page offered this server, because that link is
/// the way in the guides name. The links that grant a power follow under
/// their own heading: the shared session's use and management links, the
/// `ROOMS-*` lines the directory minted, and, when a browser can reach the
/// session through this front (`offered`), the page offered the session,
/// whose use link rides in the fragment a browser never sends to the page's
/// host. The page asks before it uses either offer. `server` is the address
/// browsers reach this front at, as a base ending in `/`.
fn serving_block(
	pages: &[url::Url],
	server: &str,
	directory: &str,
	session: Option<&(String, String)>,
	offered: bool,
	capabilities: &[String],
) -> String {
	let shown = server.trim_end_matches('/');
	let mut block = String::from("rooms: serving\n\n");
	for page in pages {
		block.push_str(&format!("  open the page    {}\n", page_link(page, server)));
	}
	block.push_str(&format!(
		"  web ui           {shown}\n  web locator      {shown}/locator\n  room directory   {directory}\n"
	));
	let mut kept = String::new();
	if let Some((link, management)) = session {
		kept.push_str(&format!(
			"ROOMS-SESSION-LISTENING {link}\nROOMS-SESSION-MANAGEMENT {management}\n"
		));
	}
	for line in capabilities {
		kept.push_str(line);
		kept.push('\n');
	}
	if let Some((link, _)) = session.filter(|_| offered) {
		let attach: String = url::form_urlencoded::Serializer::new(String::new())
			.append_pair("attach", link)
			.finish();
		for page in pages {
			let mut offered = page_link(page, server);
			offered.set_fragment(Some(&attach));
			kept.push_str(&format!("  open the session {offered}\n"));
		}
	}
	if !kept.is_empty() {
		block.push_str(&format!(
			"\nrooms: {}\n\n",
			crate::server::readiness::KEEP_LINKS_PRIVATE
		));
		block.push_str(&kept);
	}
	block.push_str("\nrooms: ready");
	block
}

/// A Rooms page offered this server, which the page asks about before using.
fn page_link(page: &url::Url, server: &str) -> url::Url {
	let mut link = page.clone();
	link.query_pairs_mut().append_pair("server", server);
	link
}

fn local_relay_url(address: std::net::SocketAddr) -> String {
	format!("ws://{}/relay", crate::local_address(address))
}

/// Print a readiness announcement. Its reader may have closed stdout once it
/// had what it waited for, so the refusal is a notice and serving continues.
fn announce(report: &Report, text: &str) {
	if let Err(error) = crate::announce::announce(text) {
		report(Notice::AnnouncementUnread(error.to_string()));
	}
}
async fn stopped(stop: &mut watch::Receiver<bool>) {
	drop(stop.wait_for(|stopped| *stopped).await);
}

async fn tor_ended(tor: &mut Option<tor::Tor>) -> String {
	match tor {
		Some(tor) => tor.ended().await,
		None => std::future::pending().await,
	}
}

/// Open a peer beside the private Tor. When Tor ends first, the process is
/// asked to stop, the opening runs to its end, and what it opened is retired
/// through `retire`, so the failure names Tor and leaves nothing running.
async fn open_beside_tor<T>(
	opening: impl Future<Output = Result<T, String>>,
	tor: &mut Option<tor::Tor>,
	stop: &watch::Sender<bool>,
	retire: impl AsyncFnOnce(T) -> Result<(), String>,
) -> Result<T, String> {
	tokio::pin!(opening);
	tokio::select! {
		opened = &mut opening => opened,
		ended = tor_ended(tor) => {
			stop.send_replace(true);
			let retired = match opening.await {
				Ok(opened) => retire(opened).await,
				Err(error) => Err(error),
			};
			Err(crate::cleanup::failed(ended, retired))
		}
	}
}

/// Open the shared session beside this front. It dials browser members
/// through this server's `own` relay, advertised as the page dials it, unless
/// its options name a route; peer locators carry their own relay advice.
async fn open_shared_session(
	mut config: crate::session::Config,
	own: &rooms_platform::serving::relay::Address,
	tor: &mut Option<tor::Tor>,
	stop: &watch::Sender<bool>,
	report: &Report,
) -> Result<crate::session::Peer, String> {
	if config.relay_url.is_none() {
		config.relay_url = Some(own.reach.clone());
		if config.relay_alias_url.is_none() {
			config.relay_alias_url = own.public().map(str::to_owned);
		}
	}
	let session_report = report.clone();
	let opening = async {
		crate::session::Peer::open(
			config,
			Rc::new(move |notice| session_report(Notice::SharedSession(notice))),
		)
		.await
		.map_err(|error| error.to_string())
	};
	open_beside_tor(opening, tor, stop, async |mut peer| {
		peer.close().await.map_err(|error| error.to_string())
	})
	.await
}

#[cfg(test)]
mod tests {
	#[test]
	fn session_relay_uses_the_bound_http_address() {
		for (bound, expected) in [
			("0.0.0.0:4321", "ws://127.0.0.1:4321/relay"),
			("[::]:4321", "ws://[::1]:4321/relay"),
			("127.0.0.2:4321", "ws://127.0.0.2:4321/relay"),
			("[::1]:4321", "ws://[::1]:4321/relay"),
		] {
			assert_eq!(super::local_relay_url(bound.parse().unwrap()), expected);
		}
	}
	#[test]
	fn a_public_address_names_its_relay_at_the_same_origin() {
		for (public, expected) in [
			("https://rooms.example/", "wss://rooms.example/relay"),
			("https://rooms.example/sub/", "wss://rooms.example/relay"),
			("http://rooms.example:8080/", "ws://rooms.example:8080/relay"),
		] {
			assert_eq!(
				super::config::public_relay_url(&url::Url::parse(public).unwrap()),
				expected
			);
		}
	}
	/// The links as printed, held in one fixture with the page's reader test
	/// (`apps/rooms/test/server_choice_test.ts`), so the two sides agree by
	/// construction.
	#[test]
	fn a_listed_page_is_linked_with_this_server_as_its_offer() {
		let fixture: serde_json::Value =
			serde_json::from_str(include_str!("../../../test/web/page_links.json")).unwrap();
		let text = |key: &str| fixture[key].as_str().unwrap().to_owned();
		let pages = [url::Url::parse(&text("page")).unwrap()];
		let directory = "ocapn://127.0.0.1%3A9099.tcp";
		assert_eq!(
			super::serving_block(&pages, &text("server"), directory, None, false, &[]),
			format!(
				"rooms: serving\n\n  open the page    {}\n  web ui           {}\n  web locator      {}/locator\n  room directory   {directory}\n\nrooms: ready",
				text("pageLink"),
				text("server").trim_end_matches('/'),
				text("server").trim_end_matches('/'),
			)
		);
		let session = (text("session"), "ocapn://abc.iroh/s/manage".to_owned());
		let kept = ["ROOMS-OPERATOR ocapn://abc.iroh/s/op".to_owned()];
		let block = super::serving_block(&pages, &text("server"), directory, Some(&session), true, &kept);
		assert_eq!(
			block,
			format!(
				"rooms: serving\n\n  open the page    {}\n  web ui           {shown}\n  web locator      {shown}/locator\n  room directory   {directory}\n\nrooms: {}\n\nROOMS-SESSION-LISTENING {}\nROOMS-SESSION-MANAGEMENT ocapn://abc.iroh/s/manage\nROOMS-OPERATOR ocapn://abc.iroh/s/op\n  open the session {}\n\nrooms: ready",
				text("pageLink"),
				crate::server::readiness::KEEP_LINKS_PRIVATE,
				text("session"),
				text("sessionLink"),
				shown = text("server").trim_end_matches('/'),
			)
		);
		assert!(
			super::serving_block(&pages, "https://rooms.example/", directory, None, false, &[])
				.contains("  open the page    https://glowcap.org/rooms/app/?server=https%3A%2F%2Frooms.example%2F\n")
		);
		// No page listed offers nothing, and a session alone still prints its links.
		let none = super::serving_block(&[], "http://localhost:8080/", directory, Some(&session), true, &[]);
		assert!(!none.contains("open the"), "{none}");
		assert!(
			none.contains(&format!("ROOMS-SESSION-LISTENING {}\n", text("session"))),
			"{none}"
		);
		// A session no browser reaches through this front, such as one over
		// onion, still prints its links. Only the offer to the page waits.
		let unreached = super::serving_block(&pages, &text("server"), directory, Some(&session), false, &[]);
		assert!(!unreached.contains("open the session"), "{unreached}");
		assert!(
			unreached.contains("ROOMS-SESSION-MANAGEMENT ocapn://abc.iroh/s/manage\n"),
			"{unreached}"
		);
	}
}
