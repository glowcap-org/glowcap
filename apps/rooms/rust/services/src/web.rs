//! The host web executable owns its supervised directory and HTTP service.
//! Capability sessions belong to peers. This front serves assets and carries
//! opaque transport traffic for browsers.
mod admission;
mod assets;
mod browser_admission;
mod bundle;
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
use config::BrowserAssets;
pub use config::{Config, HELP};
pub use export::StaticExport;
pub use notice::{Notice, Report};
pub use prepare::Preparation;
pub use status::StatusQuery;
use std::{future::Future, rc::Rc};
use tokio::{net::TcpListener, sync::watch};

pub async fn run(config: Config, report: Report, halt: impl Future<Output = ()>) -> Result<(), String> {
	let (stop, stopping) = watch::channel(false);
	let work = serve(config, report, stop.clone(), stopping);
	tokio::pin!(work, halt);
	tokio::select! {
		result = &mut work => result,
		_ = &mut halt => { stop.send_replace(true); work.await }
	}
}
async fn serve(
	config: Config,
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
		relay: mut limits,
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
	report(Notice::BrowserAdmission(browser_admission.settings.summary()));
	let ice = ice::Policy::open(ice).await?;
	let admission = admission::Admission::new(admission_config.clone());
	report(Notice::Admission(format!(
		"{}; per-address={}; trusted-proxies={}",
		admission_config.settings.summary(),
		admission_config.per_address,
		admission_config.trusted_proxies.len()
	)));
	let previews = preview::Preview::open(admission.clone()).await?;
	if *stopping.borrow() {
		return Ok(());
	}
	let mut tor = match tor {
		Some(plan) => match tor::Tor::open(plan, stopping.clone()).await? {
			Some(tor) => Some(tor),
			None => return Ok(()),
		},
		None => None,
	};
	// The directory's relay listeners register where browsers reach this
	// server: the public address when one is named, else the bound one.
	let relay_url = relay_url.unwrap_or_else(|| {
		public
			.as_ref()
			.map_or_else(|| local_relay_url(address), config::public_relay_url)
	});
	// The shared session opens first: its TCP endpoint joins the relay's
	// allowed targets, which the relay reads once, at construction.
	let shared = match session {
		Some(mut config) => {
			// The cohosted session must dial browser introductions too. Use
			// the bound port, including --http-port=0, and preserve an explicit
			// operator route. Peer locators carry their own relay advice.
			config.relay_url.get_or_insert_with(|| local_relay_url(address));
			let session_report = report.clone();
			match crate::session::Peer::open(
				config,
				Rc::new(move |notice| session_report(Notice::SharedSession(notice))),
			)
			.await
			{
				Ok(peer) => Some(peer),
				Err(error) => {
					let cleanup = match tor {
						Some(tor) => tor.close().await,
						None => Ok(()),
					};
					return crate::cleanup::combine(Err(error.to_string()), cleanup);
				}
			}
		}
		None => None,
	};
	// The browser leg of a shared session attachment comes through this relay,
	// so a page is offered the session only when the relay can forward to it.
	let attach = match &shared {
		Some(peer) if limits.admit_own_session(peer.link()) => Some(peer.link()),
		_ => None,
	};
	// The address every printed link names: the operator's public one, else
	// the loopback address of the port this process bound.
	let reached_at = public.map_or_else(|| format!("http://localhost:{port}/"), |public| public.to_string());
	let links = page_links(&limits.pages, &reached_at, attach);
	// HTTP serves before the directory announces, so the location starts
	// empty: the directory's relay listeners register at this front's
	// `/register` on their way up, and `/locator` answers "not ready" until
	// the announcement fills it.
	let (location, current) = watch::channel(None);
	let (jobs, incoming) = tokio::sync::mpsc::channel(32);
	let relay = relay::Relay::with_admission(
		limits,
		current.clone(),
		jobs,
		stopping.clone(),
		report.clone(),
		admission,
	);
	let mut workers = tokio::task::JoinSet::new();
	if let Some(peer) = shared {
		announce(
			&report,
			&format!(
				"ROOMS-SESSION-LISTENING {}\nROOMS-SESSION-MANAGEMENT {}",
				peer.link(),
				peer.management_link()
			),
		);
		let mut session_stop = stopping.clone();
		workers.spawn_local(async move { peer.run(stopped(&mut session_stop)).await.map_err(|e| e.to_string()) });
	}
	if let Some(assets) = &assets {
		workers.spawn_local(assets.clone().run());
	}
	workers.spawn_local(http::serve(
		listener,
		Rc::new(http::Environment {
			assets,
			ice,
			location: current,
			previews: Rc::new(previews),
			relay,
			report: report.clone(),
			trusted_proxies: admission_config.trusted_proxies,
		}),
		incoming,
		stop.clone(),
		stopping.clone(),
	));
	let opened = {
		let opening =
			supervisor::Supervisor::open(server, server_args, room, relay_url, stopping.clone(), report.clone());
		tokio::pin!(opening);
		tokio::select! {
			opened = &mut opening => opened,
			ended = tor_ended(&mut tor) => {
				stop.send_replace(true);
				let retired = match opening.await {
					Ok(Some((owner, _))) => owner.close().await,
					Ok(None) => Ok(()),
					Err(error) => Err(error),
				};
				Err(crate::cleanup::failed(ended, retired))
			}
		}
	};
	let (supervisor, locator) = match opened {
		Ok(Some(started)) => started,
		Ok(None) => return settle(Ok(()), &stop, workers, tor).await,
		Err(error) => return settle(Err(error), &stop, workers, tor).await,
	};
	let public_locator = locator.location.clone();
	location.send_replace(Some(locator));
	workers.spawn_local(supervisor.run(location, stopping.clone()));
	let shown = reached_at.trim_end_matches('/');
	announce(
		&report,
		&format!(
			"rooms: serving\n\n{links}  web ui           {shown}\n  web locator      {shown}/locator\n  room directory   {public_locator}\n\nrooms: ready"
		),
	);
	let result = tokio::select! {
		_ = stopped(&mut stopping) => Ok(()),
		ended = tor_ended(&mut tor) => Err(ended),
		ended = workers.join_next() => ended.ok_or("web service owner disappeared".to_owned())
			.and_then(|r| r.map_err(|e| e.to_string())).and_then(|r| r),
	};
	settle(result, &stop, workers, tor).await
}

/// Stop every worker, wait for each, and retire Tor, keeping the first
/// failure and every later one it did not already name.
async fn settle(
	mut result: Result<(), String>,
	stop: &watch::Sender<bool>,
	mut workers: tokio::task::JoinSet<Result<(), String>>,
	tor: Option<tor::Tor>,
) -> Result<(), String> {
	stop.send_replace(true);
	while let Some(ended) = workers.join_next().await {
		crate::cleanup::retain(&mut result, ended.map_err(|e| e.to_string()).and_then(|r| r));
	}
	if let Some(tor) = tor {
		crate::cleanup::retain(&mut result, tor.close().await);
	}
	result
}

/// The banner's first lines, one per Rooms page listed by its address: the
/// page, offered this server, and with a shared session, the page offered
/// that session too. They lead because that link is the way in the guides
/// name. The session's use link is a capability, so it rides in the
/// fragment, which a browser never sends to the page's host. The page asks
/// before it uses either offer. `server` is the address browsers reach this
/// server at, as a base ending in `/`.
fn page_links(pages: &[url::Url], server: &str, session: Option<&str>) -> String {
	let mut lines = String::new();
	for page in pages {
		let mut link = page.clone();
		link.query_pairs_mut().append_pair("server", server);
		lines.push_str(&format!("  open the page    {link}\n"));
		if let Some(session) = session {
			let attach: String = url::form_urlencoded::Serializer::new(String::new())
				.append_pair("attach", session)
				.finish();
			link.set_fragment(Some(&attach));
			lines.push_str(&format!("  open the session {link}\n"));
		}
	}
	lines
}

fn local_relay_url(mut address: std::net::SocketAddr) -> String {
	if address.ip().is_unspecified() {
		address.set_ip(if address.is_ipv4() {
			std::net::Ipv4Addr::LOCALHOST.into()
		} else {
			std::net::Ipv6Addr::LOCALHOST.into()
		});
	}
	format!("ws://{address}/relay")
}

/// Release the watch read guard before the caller can enter async cleanup.
/// Returning that guard through select would retain it while reaping a child
/// and deadlock a concurrent shutdown sender on the same executor.
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
		assert_eq!(
			super::page_links(&pages, &text("server"), None),
			format!("  open the page    {}\n", text("pageLink"))
		);
		assert_eq!(
			super::page_links(&pages, &text("server"), Some(&text("session"))),
			format!(
				"  open the page    {}\n  open the session {}\n",
				text("pageLink"),
				text("sessionLink")
			)
		);
		assert_eq!(
			super::page_links(&pages, "https://rooms.example/", None),
			"  open the page    https://glowcap.org/rooms/app/?server=https%3A%2F%2Frooms.example%2F\n"
		);
		assert_eq!(
			super::page_links(&[], "http://localhost:8080/", Some("ocapn://abc.iroh/s/x")),
			""
		);
	}
}
