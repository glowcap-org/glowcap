//! Native standalone archive lifecycle. The listener, disk worker and accepted
//! connections each have an owner, and shutdown observes their completion.
use super::{
	file::{FileArchive, Options},
	Archive,
};
use crate::{
	cleanup::combine,
	serving::{accept_ended, serve_partner, Listener, PartnerNotice, ACCEPT_RETRY, CONNECTION_LIMIT},
};
use glowcap::{Host, PendingWork};
use std::{future::Future, rc::Rc};
use tokio::{task::JoinSet, time::Instant};
mod config;
pub use config::{Config, Transport, HELP};

/// Where the archive's notices about partners go. The binary installs one
/// that writes to stderr; a test installs one that collects.
pub type Report = Rc<dyn Fn(PartnerNotice)>;

/// Run inside a current-thread LocalSet. `ready` receives the authority link
/// only after identity, listener and every durable publication are ready.
pub async fn run(
	config: Config,
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&str),
	report: Report,
) -> Result<(), String> {
	let mut backend = FileArchive::open(&config.state, Options::default()).await?;
	let identity = backend.identity().await?;
	// Host defaults are the same v1.0 Syrup/baseline interop posture used by
	// the existing standalone archive, independent of the full Rooms fleet.
	let host =
		Host::from_seed_with_options(*identity.seed(), rooms_glowcap::host_options()).map_err(|e| e.to_string())?;
	serve(
		&config.transport,
		&host,
		backend,
		*identity.entropy(),
		shutdown,
		ready,
		report,
	)
	.await
}
async fn serve(
	transport: &Transport,
	host: &Host,
	mut backend: FileArchive,
	entropy: [u8; 16],
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&str),
	report: Report,
) -> Result<(), String> {
	let (listener, locator) = match Listener::open(transport, host, &mut backend).await {
		Ok(opened) => opened,
		Err(e) => {
			return combine(
				Err(e.to_string()),
				host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			)
		}
	};
	let (owner, mut worker) = Archive::new(crate::client::Deadline, backend);
	let link = match worker.publish(host.clone(), entropy, locator).await {
		Ok(link) => link,
		Err(e) => {
			let closed = listener.close().await.map_err(|e| e.to_string());
			drop(worker);
			return combine(
				combine(Err(e), closed),
				host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			);
		}
	};
	let mut worker = tokio::task::spawn_local(worker.run());
	let mut connections = JoinSet::new();
	let mut worker_observed = false;
	// A refused accept is asked again after a pause; only a closed listener
	// ends serving.
	let mut accept_again: Option<Instant> = None;
	tokio::pin!(shutdown);
	ready(&link);
	let result = loop {
		tokio::select! {
			_ = &mut shutdown => break Ok(()),
			ended = &mut worker => { worker_observed = true; break Err(format!("archive storage worker ended unexpectedly: {ended:?}")); },
			accepted = listener.accept(), if connections.len() < CONNECTION_LIMIT && accept_again.is_none() => match accepted {
				Ok(session) => { connections.spawn_local(served(session, report.clone())); },
				Err(error) if accept_ended(&error) => break Err(error.to_string()),
				Err(error) => {
					report(PartnerNotice::AcceptRefused(error));
					accept_again = Some(Instant::now() + ACCEPT_RETRY);
				}
			},
			_ = tokio::time::sleep_until(accept_again.unwrap_or_else(Instant::now)), if accept_again.is_some() => {
				accept_again = None;
			}
			Some(ended) = connections.join_next(), if !connections.is_empty() => {
				if let Err(join) = ended {
					report(PartnerNotice::TaskFailed(join));
				}
			},
		}
	};
	let mut result = combine(result, listener.close().await.map_err(|e| e.to_string()));
	let closed = owner.close().await.and_then(|r| {
		if r.publication_failures == 0 {
			Ok(())
		} else {
			Err("archive publication cleanup failed".into())
		}
	});
	result = combine(result, closed);
	if !worker_observed {
		result = combine(result, worker.await.map(|_| ()).map_err(|e| e.to_string()));
	}
	result = combine(result, host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()));
	while let Some(ended) = connections.join_next().await {
		if let Err(join) = ended {
			report(PartnerNotice::TaskFailed(join));
		}
	}
	result
}
/// Serve one accepted partner to its end, reporting an end that was not the
/// partner simply leaving.
async fn served(session: glowcap::Session, report: Report) {
	if let Err(ended) = serve_partner(session).await {
		report(PartnerNotice::Ended(ended));
	}
}
#[cfg(test)]
mod tests;
