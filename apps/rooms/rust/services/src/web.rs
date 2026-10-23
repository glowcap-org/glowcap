//! The host web executable owns its supervised directory and HTTP service.
//! Capability sessions belong to peers. This front serves assets and carries
//! opaque transport traffic for browsers.
mod admission;
mod assets;
mod browser_admission;
mod bundle;
mod compiler;
mod config;
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
		browser_assets,
		browser_admission,
		server,
		server_args,
		room,
		session,
		relay: limits,
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
	let admission = admission::Admission::new(admission_config);
	report(Notice::Admission(format!(
		"{}; per-address={}",
		admission_config.settings.summary(),
		admission_config.per_address
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
	let opened = {
		let opening = supervisor::Supervisor::open(server, server_args, room, stopping.clone(), report.clone());
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
		Ok(None) => {
			if let Some(tor) = tor {
				tor.close().await?;
			}
			return Ok(());
		}
		Err(error) => {
			let cleanup = match tor {
				Some(tor) => tor.close().await,
				None => Ok(()),
			};
			return crate::cleanup::combine(Err(error), cleanup);
		}
	};
	let public_locator = locator.location.clone();
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
					let mut result = crate::cleanup::combine(Err(error.to_string()), supervisor.close().await);
					if let Some(tor) = tor {
						result = crate::cleanup::combine(result, tor.close().await);
					}
					return result;
				}
			}
		}
		None => None,
	};
	let (location, current) = watch::channel(Some(locator));
	let (jobs, incoming) = tokio::sync::mpsc::channel(32);
	let relay = relay::Relay::with_admission(limits, current.clone(), jobs, stopping.clone(), admission);
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
	workers.spawn_local(supervisor.run(location, stopping.clone()));
	workers.spawn_local(http::serve(
		listener,
		Rc::new(http::Environment {
			assets,
			ice,
			location: current,
			previews: Rc::new(previews),
			relay,
			report: report.clone(),
		}),
		incoming,
		stop.clone(),
		stopping.clone(),
	));
	announce(
		&report,
		&format!(
			"rooms: serving\n\n  web ui           http://localhost:{port}\n  web locator      http://localhost:{port}/locator\n  room directory   {public_locator}\n\nrooms: ready"
		),
	);
	let mut result = tokio::select! {
		_ = stopped(&mut stopping) => Ok(()),
		ended = tor_ended(&mut tor) => Err(ended),
		ended = workers.join_next() => ended.ok_or("web service owner disappeared".to_owned())
			.and_then(|r| r.map_err(|e| e.to_string())).and_then(|r| r),
	};
	stop.send_replace(true);
	while let Some(ended) = workers.join_next().await {
		result = crate::cleanup::combine(result, ended.map_err(|e| e.to_string()).and_then(|r| r));
	}
	if let Some(tor) = tor {
		result = crate::cleanup::combine(result, tor.close().await);
	}
	result
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
}
