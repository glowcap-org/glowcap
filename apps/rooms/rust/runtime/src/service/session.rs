//! Shared session application startup. The embedding owns transport acceptance,
//! document acquisition, and visualization; this owner runs all Rooms workers.
use super::{
	Platform, Stop, Visualization, Worker,
	directs::DirectGraph,
	error::Error,
	facet::{Facet, Parts},
	notice::{Notice, Report},
	observed::Observed,
	owners::Owners,
};
use crate::{
	archive::Backend,
	archive::session::SessionArchive,
	archive::shares::ArchiveShares,
	documents::{Document, Documents},
	entropy::Entropy,
	grants::DurableGrants,
	grants::commands::GrantCommands,
	rooms::RoomRuntime,
	rooms::offers::RoomOffers,
	session::commands::{SessionCommands, SessionWorker},
};
use glowcap::{CaptpVersion, Host, Locator};
use rooms_application::{grants::Access, session::checkpoint::Checkpoint};
use std::rc::Rc;
use tokio::sync::watch;

/// Platform effects for one session. Runtime must adopt the Host restored from
/// this session's identity seed. Each entropy call supplies an independently
/// owned source; it must not clone a generator's state.
pub struct Inputs<P: crate::directories::connections::Platform, F> {
	pub platform: P,
	pub connections: crate::directories::connections::Connections<P>,
	pub locator: Locator,
	/// Browser recording uses the device archive identity; native hosts use
	/// their public designator when this is absent. Never supply a private seed.
	pub recording_source: Option<rooms_application::text::DocumentText>,
	pub entropy: F,
	pub trace: Rc<dyn Visualization>,
	pub report: Report,
}

/// A fully opened application, including its root publication and all workers.
/// Close it before its runtime or storage adapters. The runtime remains usable
/// afterward; retiring this session removes only its own publications.
pub struct Session<P: Platform> {
	owners: Owners<P>,
	link: Option<String>,
	publication: Publication<P>,
}
impl<P: Platform> Session<P> {
	pub async fn open<S, G, D, Q, B, F, E>(
		inputs: Inputs<P, F>,
		state: (SessionCommands, SessionWorker<S, G, P>),
		grants: DurableGrants<D>,
		bridge_secrets: Q,
		archive: B,
		initial_checkpoint: Option<Checkpoint>,
	) -> Result<Self, Error>
	where
		S: Documents + 'static,
		G: Entropy + 'static,
		D: Document + 'static,
		Q: Document + 'static,
		B: Backend + 'static,
		F: FnMut() -> E,
		E: Entropy + 'static,
	{
		let mut session = Self::open_local(inputs, state, grants, bridge_secrets, archive, initial_checkpoint).await?;
		if let Err(error) = session.publish() {
			return Err(error.retain_result(session.close().await));
		}
		Ok(session)
	}
	/// Open the same application workers without making the administrator
	/// capability reachable. The embedding prepares reachability before publish.
	pub async fn open_local<S, G, D, Q, B, F, E>(
		inputs: Inputs<P, F>,
		state: (SessionCommands, SessionWorker<S, G, P>),
		grants: DurableGrants<D>,
		bridge_secrets: Q,
		archive: B,
		initial_checkpoint: Option<Checkpoint>,
	) -> Result<Self, Error>
	where
		S: Documents + 'static,
		G: Entropy + 'static,
		D: Document + 'static,
		Q: Document + 'static,
		B: Backend + 'static,
		F: FnMut() -> E,
		E: Entropy + 'static,
	{
		let (commands, worker) = state;
		let mut owners = Owners::new(commands.clone());
		match assemble(
			inputs,
			commands,
			worker,
			(grants, bridge_secrets),
			archive,
			initial_checkpoint,
			&mut owners,
		)
		.await
		{
			Ok(publication) => Ok(Self {
				owners,
				link: None,
				publication,
			}),
			Err(error) => Err(error.retain_result(owners.close().await)),
		}
	}
	/// Trusted local access, fenced by this application's lifetime.
	pub fn local(&self) -> super::Local<P> {
		super::Local::new(&self.publication.facet)
	}
	/// The embedding composes incoming transports on the registrations already
	/// supervised by this session; it never registers another logical member.
	pub fn directories(&self) -> crate::directories::runtime::DirectoryRuntime<P> {
		self.owners
			.directories
			.as_ref()
			.expect("opened session directories")
			.clone()
	}
	pub fn link(&self) -> Option<&str> {
		self.link.as_deref()
	}
	/// Publish the already-running owner. Repeated calls retain the same name.
	pub fn publish(&mut self) -> Result<&str, Error> {
		if self.link.is_none() {
			let link = self.publication.publish(&mut self.owners)?;
			self.link = Some(link);
		}
		Ok(self.link.as_deref().expect("published session"))
	}
	/// Attach reachability hints before the first publication. A published name
	/// keeps the route that was actually prepared for its lifetime.
	pub async fn publish_at(&mut self, locator: Locator) -> Result<&str, Error> {
		if self.link.is_none() {
			if locator.designator != self.publication.locator.designator
				|| locator.transport != self.publication.locator.transport
			{
				return Err(Error::invalid("publication route belongs to another session identity"));
			}
			glowcap::format_locator_uri(&locator)?;
			self.publication.grants.publication_route(&locator).await?;
			self.publication.locator = locator;
		}
		self.publish()
	}
	/// Verify a sibling directly against the held publication owners. No
	/// transport is opened to this session's own Host.
	pub async fn verify_sibling(&self, text: &str) -> Result<(), Error> {
		self.publication.facet.require_live()?;
		if text.encode_utf16().take(16_385).count() > 16_384 {
			return Err(Error::invalid("Rooms session link exceeds its bound"));
		}
		let parsed = glowcap::parse_sturdyref(text, CaptpVersion::V1_0)?;
		let expected = rooms_glowcap::routes::Address::from_locator(self.publication.locator.clone())?;
		let actual = rooms_glowcap::routes::Address::from_locator(parsed.locator)?;
		if expected.authority != actual.authority {
			return Err(Error::invalid("Rooms link belongs to another session peer"));
		}
		if !self
			.owners
			.root
			.as_ref()
			.is_some_and(|root| root.name().as_bytes() == parsed.swissnum)
		{
			self.publication.grants.verify_name(parsed.swissnum).await?;
		}
		self.publication.facet.require_live()?;
		Ok(())
	}
	/// Resolve only when an owned worker ends unexpectedly. Safe to select
	/// against a host-specific accept loop or browser shutdown request.
	pub async fn ended(&mut self) -> Error {
		self.owners.workers.ended().await
	}
	pub async fn close(self) -> Result<(), Error> {
		self.owners.close().await
	}
}

async fn assemble<P, S, G, D, Q, B, F, E>(
	inputs: Inputs<P, F>,
	commands: SessionCommands,
	session_worker: SessionWorker<S, G, P>,
	documents: (DurableGrants<D>, Q),
	backend: B,
	initial_checkpoint: Option<Checkpoint>,
	owners: &mut Owners<P>,
) -> Result<Publication<P>, Error>
where
	P: Platform,
	S: Documents + 'static,
	G: Entropy + 'static,
	D: Document + 'static,
	Q: Document + 'static,
	B: Backend + 'static,
	F: FnMut() -> E,
	E: Entropy + 'static,
{
	let (grants_document, bridge_document) = documents;
	let Inputs {
		platform,
		connections,
		locator,
		recording_source,
		entropy: mut entropy_source,
		trace,
		report,
	} = inputs;
	let dial = connections.runtime().clone();
	let host = dial.host().clone();
	let bridge_secrets = crate::session::bridge_secrets::BridgeSecrets::open(bridge_document).await?;
	let bridge_witnesses = commands.view().read(|state| {
		Ok::<_, Error>(crate::session::bridge_secrets::checkpoint_witnesses(
			state.checkpoint()?,
		))
	})??;
	bridge_secrets.recover(&bridge_witnesses).await?;
	let (seed, entropy) = commands
		.view()
		.read(|state| Ok::<_, Error>((*state.identity_seed()?, *state.session_entropy()?)))
		.map_err(Error::from)??;
	let member = glowcap::format_locator_uri(&locator).map_err(Error::from)?;
	let (archive, archive_worker) = SessionArchive::new(platform.clone(), dial.clone(), backend);
	let archive_worker = archive_worker.with_issuer(host.clone(), locator.clone(), share_entropy(&seed));
	let archive = Rc::new(archive);
	owners.archive = Some(archive.clone());
	owners.workers.spawn(Worker::Archive, {
		let report = report.clone();
		async move {
			let outcome = archive_worker.run().await;
			// A clean run has nothing to say; anything it could not finish is
			// the operator's to hear, and never the peer's failure.
			if outcome.restore_failure.is_some()
				|| outcome.refused > 0
				|| outcome.lost_replies > 0
				|| outcome.cleanup_failures > 0
			{
				report(Notice::ArchiveReport(outcome));
			}
			Ok(())
		}
	});

	let (directories, directory_worker, mut runtime_events, inbox) =
		crate::directories::runtime::DirectoryRuntime::with_connections(
			connections,
			commands.clone(),
			member.clone(),
			platform.clone(),
			entropy_source(),
		)?;
	owners.directories = Some(directories.clone());
	// The handed-room, share, and offer owners move into `owners` whole; the
	// facet and the direct graph keep only their receivers.
	let (handed, handed_worker) = directories.handed_rooms();
	let (handed_receiver, handed_changes) = (handed.receiver(), handed.changes());
	owners.handed = Some(handed);
	let shares = ArchiveShares::new(entropy_source());
	let (share_receiver, share_changes) = (shares.receiver(), shares.changes());
	owners.shares = Some(shares);
	let (offers, offer_worker, mut offer_outcomes) = RoomOffers::new(directories.room_links());
	let offer_receiver = offers.receiver();
	owners.offers = Some(offers);
	// Archive coordinates are public data. Never encode private identity material.
	let source = match recording_source {
		Some(source) => source,
		None => host.designator().map_err(Error::from)?.into(),
	};
	let (rooms, room_worker, mut room_events) = RoomRuntime::open(
		platform.clone(),
		entropy_source(),
		directories.clone(),
		commands.clone(),
		bridge_secrets.clone(),
		Some((archive.clone(), source.clone())),
	)?;
	runtime_events.set_bridge_scope({
		let rooms = rooms.clone();
		move |conversation| rooms.bridge_scope(conversation)
	});
	// The archive is already driven; restored erasure precedes publication.
	let runtime_events =
		crate::session::retention::RetentionEvents::open(runtime_events, archive.clone(), &commands.view()).await?;
	owners.rooms = Some(rooms.clone());
	let (directs, direct_workers, mut direct_events) = DirectGraph::open(
		host.clone(),
		platform.clone(),
		&mut entropy_source(),
		directories.clone(),
		inbox,
		commands.clone(),
		archive.clone(),
		source,
		offer_receiver,
		handed_receiver.clone(),
		share_receiver.clone(),
		report.clone(),
	)?;
	let facet = Facet::new(Parts {
		platform: platform.clone(),
		trace,
		entropy: Box::new(entropy_source()),
		host: host.clone(),
		commands: commands.clone(),
		bridge_secrets,
		directories: directories.clone(),
		rooms: rooms.clone(),
		routes: directs.routes.clone(),
		dispatcher: directs.dispatcher.clone(),
		directs: directs.commands.clone(),
		archive: archive.clone(),
		events: directs.events.receiver(),
		handed: handed_receiver,
		shares: share_receiver,
		member_locator: member,
		report: report.clone(),
	});
	owners.directs = Some(directs);
	owners.facet = Some(facet.clone());

	owners.workers.spawn(
		Worker::Storage,
		session_worker.run(Observed {
			runtime: runtime_events,
			facet: facet.clone(),
		}),
	);
	owners.workers.spawn(Worker::Directories, directory_worker.run());
	owners.workers.spawn(Worker::Rooms, room_worker.run());
	let mut direct_outcomes = direct_workers.outcomes;
	owners
		.workers
		.spawn(Worker::DirectDispatch, direct_workers.dispatch.run());
	owners
		.workers
		.spawn(Worker::DirectCommands, direct_workers.commands.run());
	owners.workers.spawn(Worker::HandedRooms, handed_worker.run());
	owners.workers.spawn(Worker::RoomOffers, offer_worker.run());
	let stop = owners.workers.stop_signal();
	owners.workers.spawn(
		Worker::Changes("history change watcher"),
		super::history_changes::forward(facet.clone(), archive.changes(), stop.clone()),
	);
	// Offer and dispatch outcomes have no consumer of their own here: every
	// opening is awaited by the command that asked for it. Draining them keeps
	// their producers from blocking on a full channel.
	owners.workers.spawn(Worker::OfferOutcomes, {
		let mut stop = stop.clone();
		async move {
			loop {
				if *stop.borrow() {
					break Ok(());
				}
				tokio::select! {
					_ = stop.changed() => break Ok(()),
					outcome = offer_outcomes.next() => if outcome.is_none() { break Ok(()) },
				}
			}
		}
	});
	owners.workers.spawn(Worker::DirectOutcomes, {
		let mut stop = stop.clone();
		async move {
			loop {
				if *stop.borrow() {
					break Ok(());
				}
				tokio::select! {
					_ = stop.changed() => break Ok(()),
					outcome = direct_outcomes.next() => if outcome.is_none() { break Ok(()) },
				}
			}
		}
	});
	for (watcher, changes) in [
		("directory change watcher", directories.changes()),
		("room change watcher", rooms.changes()),
		("direct route change watcher", facet.routes().changes()),
		("direct recording change watcher", facet.0.events.changes()),
		("archive status watcher", archive.status_changes()),
		("handed-room change watcher", handed_changes),
		("archive share change watcher", share_changes),
	] {
		owners.workers.spawn(
			Worker::Changes(watcher),
			forward_changes(facet.clone(), changes, stop.clone()),
		);
	}
	owners
		.workers
		.spawn(Worker::Reconciliation, facet.reconciliation(stop.clone()));
	owners.workers.spawn(Worker::RoomEvents, {
		let facet = facet.clone();
		let mut stop = stop.clone();
		async move {
			loop {
				if *stop.borrow() {
					break Ok(());
				}
				tokio::select! {
					_ = stop.changed() => break Ok(()),
					event = room_events.next() => match event {
						Some(event) => facet.deliver_event(&event),
						None => break Ok(()),
					},
				}
			}
		}
	});
	owners.workers.spawn(Worker::DirectEvents, {
		let facet = facet.clone();
		let recording_state = facet.0.events.clone();
		async move {
			let mut recordings = crate::direct::events::RecordingObservations::default();
			let mut events_open = true;
			// The direct graph closes its sender before the archive closes. Drain
			// every admitted event and receipt instead of letting the peer's generic
			// stop signal abandon outcomes during orderly shutdown.
			loop {
				if !events_open && recordings.is_empty() {
					break Ok(());
				}
				tokio::select! {
					settlement = recordings.next(), if !recordings.is_empty() => {
						recording_state.settle_recording(settlement);
					}
					event = direct_events.next(), if events_open => match event {
						Some(event) => {
							let (delivered, receipt) = event.into_parts();
							facet.deliver_event(&super::events::from_direct(delivered));
							if let Some(settlement) = recordings.admit(receipt) {
								recording_state.settle_recording(settlement);
							}
						}
						None => events_open = false,
					},
				}
			}
		}
	});

	if let Some(checkpoint) = initial_checkpoint {
		let id = super::verbs::checkpoint::operation_id("initial-checkpoint")?;
		commands
			.prepare_replace(id, 0, checkpoint)
			.map_err(Error::from)?
			.send()
			.map_err(Error::from)?
			.wait()
			.await?;
	}
	let (grants, grant_worker) = GrantCommands::open(grants_document, host.clone(), entropy, locator.clone(), {
		let facet = facet.clone();
		move || facet.granted_behavior()
	})
	.await
	.map_err(Error::grant)?;
	owners.grants = Some(grants.clone());
	assert!(facet.0.grant_commands.set(grants.clone()).is_ok());
	facet.load_grants(grant_worker.views()?);
	owners.workers.spawn(Worker::Grants, grant_worker.run(facet.clone()));
	Ok(Publication {
		host,
		entropy,
		locator,
		facet,
		grants,
	})
}

struct Publication<P: Platform> {
	host: Host,
	entropy: [u8; Host::DURABLE_ENTROPY_BYTES],
	locator: Locator,
	facet: Facet<P>,
	grants: GrantCommands,
}
impl<P: Platform> Publication<P> {
	fn publish(&self, owners: &mut Owners<P>) -> Result<String, Error> {
		self.facet.require_live()?;
		let swiss = self.host.publish_durable_with_entropy(self.entropy, {
			let facet = self.facet.clone();
			let grants = self.grants.clone();
			move || {
				Box::new(move |verb, args| {
					grants
						.dispatch(Access::Admin, verb, args)
						.unwrap_or_else(|| facet.invoke_admin(verb, args))
				})
			}
		})?;
		// Own publication before fallible locator formatting.
		owners.root = Some(super::owners::Publication::new(self.host.clone(), swiss));
		Ok(glowcap::format_sturdyref(
			&self.locator,
			owners.root.as_ref().expect("published root").name().as_bytes(),
			CaptpVersion::V1_0,
		)?)
	}
}

async fn forward_changes<P: Platform>(
	facet: Facet<P>,
	mut changes: watch::Receiver<()>,
	mut stop: Stop,
) -> Result<(), Error> {
	loop {
		if *stop.borrow() {
			break Ok(());
		}
		tokio::select! {
			_ = stop.changed() => break Ok(()),
			changed = changes.changed() => {
				if changed.is_err() { break Ok(()) }
				facet.notify();
			}
		}
	}
}

/// Entropy for durable archive-share publications: the second half of the
/// identity seed, stable across restarts because the seed is, and distinct
/// from the session entropy the administrator publication derives from.
fn share_entropy(seed: &[u8; 32]) -> [u8; Host::DURABLE_ENTROPY_BYTES] {
	let mut entropy = [0u8; Host::DURABLE_ENTROPY_BYTES];
	entropy.copy_from_slice(&seed[16..]);
	entropy
}
