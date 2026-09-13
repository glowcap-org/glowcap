//! The host web executable owns its supervised directory and HTTP service.
//! Capability sessions belong to peers; this front serves assets and carries
//! opaque transport traffic for browsers.
mod assets;
mod bundle;
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
		root,
		prepared,
		server,
		server_args,
		room,
		relay: limits,
		ice,
		tor,
	} = config;
	// Acquiring HTTP first prevents a conflicting web start from briefly
	// acquiring directory custody or minting operator capabilities.
	let listener = TcpListener::bind((bind.as_str(), port))
		.await
		.map_err(|e| format!("binding the HTTP listener failed: {e}"))?;
	let port = listener.local_addr().map_err(|e| e.to_string())?.port();
	let root = tokio::fs::canonicalize(&root)
		.await
		.map_err(|e| format!("opening web assets failed: {e}"))?;
	let Some(assets) = assets::Assets::open(root, prepared, stopping.clone(), report.clone()).await? else {
		return Ok(());
	};
	let ice = ice::Policy::open(ice).await?;
	let previews = preview::Preview::open().await?;
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
				Err(crate::cleanup::combine(ended, retired).expect_err("Tor ended before directory readiness"))
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
	let (location, current) = watch::channel(Some(locator));
	let (jobs, incoming) = tokio::sync::mpsc::channel(32);
	let relay = relay::Relay::new(limits, current.clone(), jobs, stopping.clone());
	let mut workers = tokio::task::JoinSet::new();
	workers.spawn_local(assets.clone().run());
	workers.spawn_local(supervisor.run(location, stopping.clone()));
	workers.spawn_local(http::serve(
		listener,
		Rc::new(http::Environment {
			assets,
			ice,
			location: current,
			previews: Rc::new(previews),
			relay,
			report,
		}),
		incoming,
		stop.clone(),
		stopping.clone(),
	));
	println!(
		"rooms: serving\n\n  web ui           http://localhost:{port}\n  web locator      http://localhost:{port}/locator\n  room directory   {public_locator}\n\nrooms: ready"
	);
	let mut result = tokio::select! {
		_ = stopped(&mut stopping) => Ok(()),
		ended = tor_ended(&mut tor) => ended,
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

/// Release the watch read guard before the caller can enter async cleanup.
/// Returning that guard through select would retain it while reaping a child
/// and deadlock a concurrent shutdown sender on the same executor.
async fn stopped(stop: &mut watch::Receiver<bool>) {
	drop(stop.wait_for(|stopped| *stopped).await);
}

async fn tor_ended(tor: &mut Option<tor::Tor>) -> Result<(), String> {
	match tor {
		Some(tor) => tor.ended().await,
		None => std::future::pending().await,
	}
}
