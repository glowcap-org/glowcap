//! Native listeners and readiness surround the shared Rooms session lifecycle.
use super::{
	config::Config,
	error::Error,
	notice::{Notice, Report},
	readiness::Readiness,
	transports::{Needs, Transports},
};
use crate::{
	archive::file::FileArchive,
	documents::SessionDocuments,
	serving::{accept_ended, serve_partner, PartnerNotice, ACCEPT_RETRY, CONNECTION_LIMIT},
	session_commands::SessionCommands,
};
use glowcap::{Host, PendingWork};
use rooms_runtime::session_service::{Inputs, Session as SharedSession};
use std::{future::Future, rc::Rc};
use tokio::{task::JoinSet, time::Instant};

#[derive(Default)]
struct Owners {
	readiness: Option<Readiness>,
	commands: Option<SessionCommands>,
	transports: Option<Transports>,
	session: Option<SharedSession<crate::client::Deadline>>,
}
impl Owners {
	async fn close(self) -> Result<(), Error> {
		let mut result = Ok(());
		if let Some(session) = self.session {
			result = Error::fold(result, session.close().await.map_err(Into::into));
		}
		if let Some(commands) = self.commands {
			result = Error::fold(result, commands.close().await.map_err(Error::runtime));
		}
		if let Some(transports) = self.transports {
			result = Error::fold(result, transports.close().await);
		}
		if let Some(readiness) = self.readiness {
			result = Error::fold(result, readiness.remove().await);
		}
		result
	}
}

/// A session peer that is listening and answering. Built by [`Peer::open`],
/// driven by [`Peer::serve`], retired by [`Peer::close`].
pub struct Peer {
	owners: Owners,
	link: String,
	report: Report,
}

impl Peer {
	/// Open every owner in dependency order. A failure at any step closes the
	/// steps before it and returns the first cause with any cleanup failure
	/// retained beside it.
	pub async fn open(config: Config, report: Report) -> Result<Self, Error> {
		let mut owners = Owners::default();
		match assemble(&config, &report, &mut owners).await {
			Ok(link) => Ok(Self { owners, link, report }),
			Err(error) => Err(error.retain_result(owners.close().await)),
		}
	}
	/// The administrator sturdyref this peer published.
	pub fn link(&self) -> &str {
		&self.link
	}
	/// Accept and serve partners until `halt` resolves or a worker ends on its
	/// own. Either way the peer is closed before this returns, and every
	/// accepted connection has been observed to its end.
	pub async fn serve(self, halt: impl Future<Output = ()>) -> Result<(), Error> {
		let Self { mut owners, report, .. } = self;
		let mut connections: JoinSet<()> = JoinSet::new();
		tokio::pin!(halt);
		let outcome = 'serving: {
			// `open` never returns a peer without both, so a missing one is a
			// peer to close, not one to serve.
			let (Some(session), Some(transports)) = (owners.session.as_mut(), owners.transports.as_ref()) else {
				break 'serving Err(Error::runtime("the peer was not fully opened"));
			};
			// A refused accept is asked again after a pause; only a closed
			// listener ends serving.
			let mut accept_again: Option<Instant> = None;
			loop {
				tokio::select! {
					_ = &mut halt => break Ok(()),
					ended = session.ended() => break Err(ended.into()),
					accepted = transports.accept(), if connections.len() < CONNECTION_LIMIT && accept_again.is_none() => match accepted {
						Ok(session) => { connections.spawn_local(served(session, report.clone())); }
						Err(error) if accept_ended(&error) => break Err(Error::from(error)),
						Err(error) => {
							report(Notice::Partner(PartnerNotice::AcceptRefused(error)));
							accept_again = Some(Instant::now() + ACCEPT_RETRY);
						}
					},
					_ = tokio::time::sleep_until(accept_again.unwrap_or_else(Instant::now)), if accept_again.is_some() => {
						accept_again = None;
					}
					Some(ended) = connections.join_next(), if !connections.is_empty() => {
						if let Err(join) = ended {
							report(Notice::Partner(PartnerNotice::TaskFailed(join)));
						}
					}
				}
			}
		};
		let closed = owners.close().await;
		while let Some(ended) = connections.join_next().await {
			if let Err(join) = ended {
				report(Notice::Partner(PartnerNotice::TaskFailed(join)));
			}
		}
		Error::fold(outcome, closed)
	}
	/// Retire without serving: the same order a finished `serve` uses.
	pub async fn close(self) -> Result<(), Error> {
		self.owners.close().await
	}
}

/// Serve one accepted partner to its end, reporting an end that was not the
/// partner simply leaving.
async fn served(session: glowcap::Session, report: Report) {
	if let Err(ended) = serve_partner(session).await {
		report(Notice::Partner(PartnerNotice::Ended(ended)));
	}
}

async fn assemble(config: &Config, report: &Report, owners: &mut Owners) -> Result<String, Error> {
	owners.readiness = Some(Readiness::clear(config.readiness_path()).await?);
	let mut documents = SessionDocuments::open(&config.state).await?;
	let mut listener_keys = documents.listener_keys();
	let grants_document = documents
		.take_grants()
		.ok_or_else(|| Error::runtime("session grants document is missing"))?;
	let session_owners = documents.into_owners();
	let (commands, session_worker) = SessionCommands::open(session_owners.state, crate::client::Deadline).await?;
	owners.commands = Some(commands.clone());
	let seed = commands
		.view()
		.read(|state| Ok::<_, Error>(*state.identity_seed()?))??;
	let host = Host::from_seed_with_options(seed, rooms_glowcap::host_options())?;
	let needs = Needs::from_checkpoint(&commands.view(), config.relay_url.clone())?;
	// Until the dial runtime adopts it, the Host has no owner but this frame.
	let transports = match Transports::open(&host, &config.transport, &needs, &mut listener_keys).await {
		Ok(transports) => transports,
		Err(error) => {
			let closed = host.close(PendingWork::Cancel).await.map_err(Error::from);
			return Err(error.retain_result(closed));
		}
	};
	let dial = transports.dial();
	let locator = transports.locator().clone();
	owners.transports = Some(transports);

	let backend = FileArchive::open(config.state.join("archive"), Default::default())
		.await
		.map_err(Error::runtime)?;
	let initial_checkpoint = match &config.checkpoint {
		Some(path) => Some(super::verbs::checkpoint::read(path).await?),
		None => None,
	};
	let shared_report = report.clone();
	// Transfer command custody into the shared application before opening it.
	owners.commands = None;
	let session = SharedSession::open(
		Inputs {
			recording_source: None,
			platform: crate::client::Deadline,
			connections: rooms_runtime::connections::Connections::new(dial, crate::client::Deadline),
			locator,
			entropy: || crate::entropy::OsEntropy,
			viz: Rc::new(super::viz::Viz::new(super::viz::Native)),
			report: Rc::new(move |notice| shared_report(notice.into())),
		},
		(commands, session_worker),
		grants_document,
		session_owners.bridge_secrets,
		backend,
		initial_checkpoint,
	)
	.await?;
	let link = session.link().expect("native session published at open").to_owned();
	owners.session = Some(session);
	if let Some(readiness) = owners.readiness.as_ref() {
		readiness.publish(&link).await?;
	}
	Ok(link)
}
