//! Host listeners and readiness surround the shared Rooms session lifecycle.
use super::{
	config::Config,
	error::Error,
	notice::{Notice, Report, StandingFailures},
	readiness::Readiness,
	transports::{Family, Needs, Transports},
	webrtc::{Answering, Directories},
};
use glowcap::{Host, PendingWork, webrtc::SignalingAuthority};
use rooms_platform::HostPlatform;
use rooms_platform::serving::{CONNECTION_LIMIT, PartnerNotice, Retry, accept_ended, serve_partner_until};
use rooms_platform::signaling::DirectorySignaling;
use rooms_platform::storage::session::{Custody, Session as Storage};
use rooms_runtime::session::managed::{Membership, MembershipKinds, production_limits};
use std::future::Future;
use std::rc::Rc;
use tokio::task::JoinSet;

/// The physical bytes a member session's SQLite store may hold before writes
/// are refused for capacity.
const SESSION_CAPACITY_BYTES: usize = 512 * 1024 * 1024;

#[derive(Default)]
struct Owners {
	readiness: Option<Readiness>,
	management_readiness: Option<Readiness>,
	transports: Option<Transports>,
	session: Option<Storage>,
	/// The job that keeps the WebRTC signaling routes current.
	signaling_routes: Option<Membership<HostPlatform>>,
	local: Option<super::Local>,
	archive: Option<std::rc::Rc<crate::session_archive::SessionArchive>>,
	archive_worker: Option<tokio::task::JoinHandle<crate::session_archive::Report>>,
	trace: Option<std::rc::Rc<rooms_runtime::trace::Trace<rooms_platform::HostPlatform>>>,
}
impl Owners {
	async fn stop_consumers(&mut self) -> Result<(), Error> {
		self.local.take();
		if let Some(routes) = self.signaling_routes.as_mut() {
			routes.close().await?;
		}
		self.signaling_routes.take();
		if let Some(trace) = self.trace.as_ref() {
			trace.close().await?;
		}
		self.trace.take();
		if let Some(session) = self.session.as_mut() {
			session.opened.stop_activity().await?;
		}
		Ok(())
	}
	async fn close(&mut self) -> Result<(), Error> {
		let mut result = Ok(());
		self.stop_consumers().await?;
		if let Some(session) = self.session.as_mut() {
			// The Host must remain alive until every managed close barrier succeeds.
			session.opened.close().await?;
		}
		self.session.take();
		if let Some(archive) = self.archive.as_ref() {
			archive.close().await.map_err(Error::from)?;
			if let Some(worker) = self.archive_worker.as_mut() {
				worker
					.await
					.map_err(|error| Error::closed(format!("archive worker failed: {error}")))?;
			}
			self.archive_worker.take();
			self.archive.take();
		}
		if let Some(transports) = self.transports.take() {
			result = Error::fold(result, transports.close().await);
		}
		if let Some(readiness) = self.readiness.as_ref() {
			result = Error::fold(result, readiness.remove().await);
		}
		if let Some(readiness) = self.management_readiness.as_ref() {
			result = Error::fold(result, readiness.remove().await);
		}
		if result.is_ok() {
			self.readiness.take();
			self.management_readiness.take();
		}
		result
	}
}

/// A session peer that is listening and answering. Built by [`Peer::open`],
/// driven by [`Peer::serve`], retired by [`Peer::close`].
pub struct Peer {
	owners: Owners,
	pub(super) state_directory: std::path::PathBuf,
	link: String,
	management_link: String,
	report: Report,
	connections: JoinSet<()>,
	// One shared stop signal, with at most CONNECTION_LIMIT borrowed receivers.
	// Retiring external calls needs the Host alive through their cancellation;
	// closing it only after attachment release would leave remote waits admitted.
	connections_stop: tokio::sync::watch::Sender<bool>,
}

impl Peer {
	/// Open every owner in dependency order. A failure at any step closes the
	/// steps before it and returns the first cause with any cleanup failure
	/// retained beside it.
	pub async fn open(config: Config, report: Report) -> Result<Self, Error> {
		let mut owners = Owners::default();
		match assemble(&config, &report, &mut owners).await {
			Ok((link, management_link)) => Ok(Self {
				owners,
				link,
				management_link,
				report,
				connections: JoinSet::new(),
				connections_stop: tokio::sync::watch::channel(false).0,
				state_directory: config.state,
			}),
			Err(error) => {
				// Startup cannot return while a refused barrier still owns work.
				while let Err(cause) = owners.close().await {
					report(Notice::Activity {
						operation: "startup close".into(),
						cause: glowcap::loam::refusal(cause.to_string()),
					});
					tokio::time::sleep(std::time::Duration::from_secs(1)).await;
				}
				Err(error)
			}
		}
	}
	/// The managed workspace use endpoint this peer published.
	pub fn link(&self) -> &str {
		&self.link
	}
	/// The independent management endpoint. Workspace access cannot recover it.
	pub fn management_link(&self) -> &str {
		&self.management_link
	}
	/// Serve and retain ownership until every close barrier has retired.
	pub async fn run(mut self, shutdown: impl Future<Output = ()>) -> Result<(), Error> {
		let result = self.serve(shutdown).await;
		while let Err(cause) = self.close().await {
			(self.report)(Notice::Activity {
				operation: "session close".into(),
				cause: glowcap::loam::refusal(cause.to_string()),
			});
			tokio::time::sleep(std::time::Duration::from_secs(1)).await;
		}
		result
	}
	/// Local application access for a view hosted by this same process.
	pub fn local(&self) -> Result<super::Local, Error> {
		self.owners
			.local
			.as_ref()
			.cloned()
			.ok_or_else(|| Error::closed("the session is closed"))
	}
	/// Accept and serve partners until `halt` resolves or a worker ends on its
	/// own. The caller drains dependent consumers and then retries `close` until
	/// its retained barriers succeed. Accepted connections remain owned here.
	pub async fn serve(&mut self, halt: impl Future<Output = ()>) -> Result<(), Error> {
		let Self {
			owners,
			report,
			connections,
			connections_stop,
			..
		} = self;
		tokio::pin!(halt);
		'serving: {
			// `open` never returns a peer without both, so a missing one is a
			// peer to close, not one to serve.
			let (Some(_session), Some(transports)) = (owners.session.as_mut(), owners.transports.as_ref()) else {
				break 'serving Err(Error::closed("the peer was not fully opened"));
			};
			// A refused accept is asked again after a pause; only a closed
			// listener ends serving.
			let mut retry = Retry::default();
			loop {
				tokio::select! {
					_ = &mut halt => break Ok(()),
					accepted = transports.accept(), if connections.len() < CONNECTION_LIMIT && retry.ready() => match accepted {
						Ok(session) => { connections.spawn_local(served(session, report.clone(), connections_stop.subscribe())); }
						Err(error) if accept_ended(&error) => break Err(Error::from(error)),
						Err(error) => {
							report(Notice::Partner(PartnerNotice::AcceptRefused(error)));
							retry.refused();
						}
					},
					_ = retry.wait() => {}
					Some(ended) = connections.join_next(), if !connections.is_empty() => {
						if let Err(join) = ended {
							report(Notice::Partner(PartnerNotice::TaskFailed(join)));
						}
					}
				}
			}
		}
	}
	/// Retire without serving: the same order a finished `serve` uses.
	pub async fn close(&mut self) -> Result<(), Error> {
		self.owners.stop_consumers().await?;
		self.connections_stop.send_replace(true);
		while let Some(ended) = self.connections.join_next().await {
			if let Err(join) = ended {
				(self.report)(Notice::Partner(PartnerNotice::TaskFailed(join)));
			}
		}
		self.owners.close().await
	}
}

/// Serve one accepted partner to its end, reporting an end that was not the
/// partner leaving.
async fn served(session: glowcap::Session, report: Report, mut stop: tokio::sync::watch::Receiver<bool>) {
	let halted = async {
		while !*stop.borrow_and_update() {
			if stop.changed().await.is_err() {
				break;
			}
		}
	};
	if let Err(ended) = serve_partner_until(session, halted).await {
		report(Notice::Partner(PartnerNotice::Ended(ended)));
	}
}

async fn assemble(config: &Config, report: &Report, owners: &mut Owners) -> Result<(String, String), Error> {
	// Readiness belongs to the process holding this directory's lease. A
	// refused contender must leave the running owner's mirrors intact.
	let custody = Custody::acquire(&config.state)?;
	owners.readiness = Some(Readiness::clear(config.readiness_path(), custody.directory().clone()).await?);
	owners.management_readiness =
		Some(Readiness::clear(config.state.join("control.sturdyref"), custody.directory().clone()).await?);
	let prepared = custody.prepare()?;
	let mut listener_keys = rooms_platform::serving::onion::KeyFile(Some(prepared.directory().clone()));
	let host = Host::from_seed_with_options(prepared.seed(), rooms_glowcap::host_options())?;
	let needs = Needs::configured(
		&config.dial_transports,
		config.relay_url.clone(),
		config.relay_alias_url.clone(),
		config.ice_servers.clone(),
	)?;
	// WebRTC signals through the peer's directories: a dial through the one
	// that introduced the member, an offer through any it is a named member
	// of. The routes fill once the session is open and its directories are
	// joined.
	let directories = Directories::default();
	let authority = needs.dials(Family::Webrtc).then(|| {
		let report = report.clone();
		DirectorySignaling::new(HostPlatform, directories.clone(), move |failure| {
			report(Notice::Activity {
				operation: "WebRTC signaling".into(),
				cause: glowcap::loam::refusal(failure.to_string()),
			})
		})
	});
	let signaling = authority
		.clone()
		.map(|authority| authority as Rc<dyn SignalingAuthority>);
	// Until the dial runtime adopts it, the Host has no owner but this frame.
	let transports = match Transports::open(&host, &config.transport, &needs, &mut listener_keys, signaling).await {
		Ok(transports) => transports,
		Err(error) => {
			let closed = host.close(PendingWork::Cancel).await.map_err(Error::from);
			return Err(error.retain_result(closed));
		}
	};
	let locator = transports.locator().clone();
	let registered = transports.registered().clone();
	let answering = match (authority, transports.webrtc()) {
		(Some(authority), Some(server)) => Some(Answering::new(authority, server, report.clone())),
		_ => None,
	};
	let runtime = transports.runtime();
	owners.transports = Some(transports);
	let limits = production_limits()?;
	let credentials = crate::documents::DocumentFile::bridge_secrets(prepared.directory().clone());
	let session = prepared
		.start(
			host.clone(),
			limits,
			SESSION_CAPACITY_BYTES,
			rooms_application::content::session::custody::MAX_CUSTODY_FIELDS as u32,
		)
		.await?;
	let opened = &mut owners.session.insert(session).opened;
	opened.session().configure_admission(config.admission)?;
	report(Notice::Admission(config.admission.summary()));
	let trouble_report = report.clone();
	opened.session().on_trouble(move |operation, cause| {
		trouble_report(Notice::Activity {
			operation: operation.into(),
			cause: cause.clone(),
		})
	})?;
	opened.session().configure_credentials(credentials).await?;
	if let Some(answering) = answering {
		owners.signaling_routes = Some(opened.session().follow_signaling_routes(move |routes| {
			answering.follow(&routes);
			directories.replace(routes);
		})?);
	}
	let mut backend = crate::archive::file::FileArchive::open(config.state.join("archive"), Default::default()).await?;
	let source = backend.recording_source().await?;
	let (archive, worker) = crate::session_archive::SessionArchive::new(rooms_platform::HostPlatform, runtime, backend);
	let archive = std::rc::Rc::new(archive);
	owners.archive = Some(archive.clone());
	owners.archive_worker = Some(tokio::task::spawn_local(worker.run()));
	opened.record_to(archive.clone(), source)?;
	if let Some(path) = &config.checkpoint {
		let bytes = tokio::fs::read(path).await.map_err(|source| Error::Io {
			what: "read workspace intent",
			source,
		})?;
		let text = std::str::from_utf8(&bytes).map_err(|_| Error::invalid("workspace intent is not UTF-8"))?;
		let intent = rooms_application::content::session::workspace::Intent::decode(text)
			.map_err(|_| Error::invalid("invalid managed workspace intent"))?;
		let workspace = opened.workspace()?;
		let snapshot = workspace.snapshot().await.map_err(rooms_runtime::Error::peer)?;
		if snapshot.intent != rooms_application::content::session::workspace::Intent::empty() {
			return Err(Error::refused("workspace import requires an empty managed session"));
		}
		workspace
			.prepare_acquisition(snapshot.revision, vec![], &[], &intent)?
			.submit()
			.await
			.map_err(rooms_runtime::Error::peer)?;
	}
	let trace_report = report.clone();
	let trace = std::rc::Rc::new(rooms_runtime::trace::Trace::start(
		rooms_platform::HostPlatform,
		opened.workspace()?,
		opened.session().changes()?,
		std::rc::Rc::new(move |reason| {
			trace_report(Notice::Activity {
				operation: "Trace publisher".into(),
				cause: glowcap::loam::refusal(reason),
			})
		}),
	));
	opened.session().configure_trace(trace.clone())?;
	owners.trace = Some(trace);
	owners.local = Some(super::Local {
		workspace: opened.workspace()?,
		management: opened.management()?,
		host,
		activity: opened.session().activity(),
		archive,
	});
	// A member reaches this peer over WebRTC when both sides can.
	let route = glowcap::format_locator_uri(&registered)?;
	let receive = opened.session().activity_receivers();
	let activity_report = report.clone();
	let mut standing = StandingFailures::default();
	opened.supervise_workspace(
		&route,
		rooms_platform::OsEntropy,
		MembershipKinds::ALL,
		receive,
		move |result| match result {
			Err(cause) => activity_report(Notice::Activity {
				operation: "workspace realization".into(),
				cause,
			}),
			Ok(state) => standing.report(&state.failures, &activity_report),
		},
	)?;
	let link = opened.publish(&locator).await?;
	let management_link = opened.publish_management(&locator).await?;
	if let Some(readiness) = owners.management_readiness.as_ref() {
		readiness.publish(&management_link).await?;
	}
	if let Some(readiness) = owners.readiness.as_ref() {
		readiness.publish(&link).await?;
	}
	Ok((link, management_link))
}
