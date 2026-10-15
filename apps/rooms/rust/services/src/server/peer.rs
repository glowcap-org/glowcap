//! The running server: the leased document, the Host minted from its
//! identity seed, the operator capabilities published before the listener
//! opens, the listener, the durable names republished from the document,
//! the history restored from disk, the listeners restored from the operator's
//! kept intent, and the loop that serves partners, runs the work the verbs
//! queued, changes durable authority one job at a time, and keeps the clocks
//! that expire signaling exchanges and quiet uploads.
use super::{
	authority, behavior,
	config::Config,
	document,
	error::Error,
	history,
	notice::{Notice, Report},
	operations::{self, Minted, listeners::Registry},
	signaling,
	state::{State, WORK_LIMIT, Work},
};
use glowcap::{Host, PendingWork, Session};
use rooms_application::{
	directory::NAME as DIRECTORY,
	files::FileLimits,
	server::{history::Index, rooms::Rooms},
};
use rooms_platform::serving::{CONNECTION_LIMIT, Listener, PartnerNotice, Retry, accept_ended, serve_partner};
use std::{cell::RefCell, future::Future, rc::Rc};
use tokio::{sync::mpsc, task::JoinSet, time::Instant};

#[cfg(test)]
mod authority_wait_tests;
#[cfg(test)]
mod name_tests;

pub struct Peer {
	owners: Owners,
	state: Rc<RefCell<State>>,
	work: mpsc::Receiver<Work>,
	report: Report,
	minted: Vec<Minted>,
}

/// What a running server tells the program that started it.
pub struct Ready {
	/// The locator partners dial, which `advertisedLocation` also answers.
	pub location: String,
	/// The operator capabilities minted, in the boot block's order.
	pub capabilities: Vec<Minted>,
	/// The live timeline endpoint's sturdyref, when it is serving.
	pub trace: Option<String>,
	/// The actual loopback timeline port, including an ephemeral selection.
	pub trace_port: Option<u16>,
	announcement: String,
}

impl Ready {
	/// One versioned supervisor record. Capability tokens stay on stderr.
	pub fn announcement(&self) -> &str {
		&self.announcement
	}
	/// The supervisor record, rendered once while the peer can still refuse it.
	fn render(
		location: &str,
		trace: Option<&str>,
		trace_port: Option<u16>,
		local_endpoint: Option<&rooms_platform::serving::endpoint::Endpoint>,
	) -> Result<String, Error> {
		let mut announcement =
			super::readiness::Announcement::new(location.to_owned(), trace_port, local_endpoint.cloned());
		announcement.trace_locator = trace
			.map(|link| {
				let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0)
					.map_err(|e| Error::refused(format!("the trace sturdyref is invalid: {e}")))?;
				glowcap::format_locator_uri(&parsed.locator)
					.map_err(|e| Error::refused(format!("the trace locator cannot be rendered: {e}")))
			})
			.transpose()?;
		announcement.line().map_err(Error::refused)
	}
}

/// Everything `open` acquires, in acquisition order, so `close` can retire
/// exactly what exists in reverse. The workers the loop runs are handed to
/// `serve`, which joins them at its end.
#[derive(Default)]
struct Owners {
	local_endpoint: Option<rooms_platform::serving::endpoint::Endpoint>,
	host: Option<Host>,
	listener: Option<Rc<Listener>>,
	/// The document's custody, held by the authority worker while serving.
	authority: Option<authority::queue::Writer>,
	history: Option<(
		history::Backend,
		mpsc::Receiver<rooms_application::server::history::Persist>,
	)>,
	/// The live timeline endpoint, while `trace` is asked.
	trace: Option<operations::trace::Trace>,
	operations: Option<operations::document::Writer>,
}

impl Owners {
	async fn close(self) -> Result<(), Error> {
		let mut result = Ok(());
		if let Some(listener) = &self.listener {
			result = Error::fold(result, listener.close().await.map_err(Error::from));
		}
		if let Some(trace) = self.trace {
			trace.close().await;
		}
		if let Some(host) = &self.host {
			result = Error::fold(result, host.close(PendingWork::Cancel).await.map_err(Error::from));
		}
		drop(self.authority);
		result
	}
}

impl Peer {
	pub async fn open(config: Config, report: Report) -> Result<Self, Error> {
		Self::open_until(config, report, std::future::pending())
			.await?
			.ok_or_else(|| Error::refused("server opening ended without a shutdown request"))
	}
	/// Filesystem actions already admitted are joined. A halt that resolves
	/// between acquisition steps retires the owners acquired so far and
	/// returns `None`.
	pub(super) async fn open_until(
		config: Config,
		report: Report,
		halt: impl Future<Output = ()>,
	) -> Result<Option<Self>, Error> {
		let mut owners = Owners::default();
		let (work, receiver) = mpsc::channel(WORK_LIMIT);
		tokio::pin!(halt);
		match assemble(&config, &mut owners, work, report.clone(), halt.as_mut()).await {
			Ok(Some((state, minted))) => Ok(Some(Self {
				owners,
				state,
				work: receiver,
				report,
				minted,
			})),
			Ok(None) => owners.close().await.map(|()| None),
			Err(error) => Err(error.retain(owners.close().await)),
		}
	}
	/// What the program that started this server prints.
	pub fn ready(&self) -> Result<Ready, Error> {
		let location = self.state.borrow().location.clone();
		let trace = self.owners.trace.as_ref().map(|trace| trace.sturdyref.clone());
		let trace_port = self.owners.trace.as_ref().map(|trace| trace.port);
		let announcement = Ready::render(
			&location,
			trace.as_deref(),
			trace_port,
			self.owners.local_endpoint.as_ref(),
		)?;
		Ok(Ready {
			location,
			capabilities: self.minted.clone(),
			trace,
			trace_port,
			announcement,
		})
	}
	/// The locator partners dial, which `advertisedLocation` also answers.
	pub fn location(&self) -> String {
		self.state.borrow().location.clone()
	}
	/// Accept and serve partners until `halt` resolves. Either way the peer
	/// is closed before this returns, and every accepted connection, queued
	/// task, and authority change has been observed to its end.
	pub async fn serve(self, halt: impl Future<Output = ()>) -> Result<(), Error> {
		let Self {
			mut owners,
			state,
			mut work,
			report,
			..
		} = self;
		let mut connections: JoinSet<()> = JoinSet::new();
		let mut tasks: JoinSet<()> = JoinSet::new();
		let mut workers: JoinSet<Result<(), Error>> = JoinSet::new();
		let writer = owners
			.authority
			.take()
			.ok_or_else(|| Error::refused("the authority writer was not opened"))?;
		let mut authorizing = tokio::task::spawn_local(writer.run(state.clone()));
		let mut authorizing_observed = false;
		if let Some((backend, changes)) = owners.history.take() {
			workers.spawn_local(history::worker(backend, changes));
		}
		// The operator's kept listeners come up once the loop can serve them.
		let writer = owners
			.operations
			.take()
			.ok_or_else(|| Error::refused("the operations writer was not opened"))?;
		operations::listeners::restore(&state, &writer.store()).await;
		super::irc::restore(&state, &writer.store()).await;
		let mut operating = tokio::task::spawn_local(writer.run());
		let mut operating_observed = false;
		tokio::pin!(halt);
		let outcome = 'serving: {
			let Some(listener) = owners.listener.clone() else {
				break 'serving Err(Error::refused("the peer was not fully opened"));
			};
			// A refused accept is asked again after a pause; only a closed
			// listener ends serving.
			let mut retry = Retry::default();
			let upload_admitted = state.borrow().upload_admitted.clone();
			loop {
				let (expiry, upload_deadline) = {
					let state = state.borrow();
					(
						state.policy.next_signaling_expiry().map(|at| state.instant(at)),
						state.rooms.next_upload_deadline().map(|at| state.instant(at)),
					)
				};
				tokio::select! {
					_ = &mut halt => break Ok(()),
					_ = upload_admitted.notified() => {},
					ended = &mut operating => {
						operating_observed = true;
						break Err(Error::refused(format!("the operations writer ended while serving: {ended:?}")));
					}
					ended = &mut authorizing => {
						authorizing_observed = true;
						break Err(Error::refused(format!("the authority writer ended while serving: {ended:?}")));
					}
					Some(ended) = workers.join_next() => {
						break match ended {
							Ok(Err(error)) => Err(error),
							Ok(Ok(())) => Err(Error::refused("a server worker ended while serving")),
							Err(join) => Err(Error::refused(format!("a server worker failed: {join}"))),
						};
					}
					accepted = listener.accept(), if connections.len() < CONNECTION_LIMIT && retry.ready() => match accepted {
						Ok(session) => { connections.spawn_local(served(state.clone(), session, report.clone())); }
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
					Some(work) = work.recv(), if tasks.len() < WORK_LIMIT => match work {
						Work::Task(task) => { tasks.spawn_local(task); }
						work => { tasks.spawn_local(deliver(state.clone(), work)); }
					},
					Some(ended) = std::future::poll_fn(|cx| state.borrow_mut().irc.tasks.poll_join_next(cx)), if !state.borrow().irc.tasks.is_empty() => {
						if let Err(join) = ended { report(Notice::Partner(PartnerNotice::TaskFailed(join))); }
					}
					Some(ended) = tasks.join_next(), if !tasks.is_empty() => {
						if let Err(join) = ended {
							report(Notice::Partner(PartnerNotice::TaskFailed(join)));
						}
					}
					_ = tokio::time::sleep_until(expiry.unwrap_or_else(Instant::now)), if expiry.is_some() => {
						let mut state = state.borrow_mut();
						let now = state.now();
						for dropped in state.policy.expire_signaling(now) {
							state.reject(dropped);
						}
					}
					_ = tokio::time::sleep_until(upload_deadline.unwrap_or_else(Instant::now)), if upload_deadline.is_some() => {
						let mut state = state.borrow_mut();
						let now = state.now();
						state.rooms.advance(now);
					}
				}
			}
		};
		state.borrow().operations.stop();
		if !operating_observed && let Err(join) = operating.await {
			report(Notice::Partner(PartnerNotice::TaskFailed(join)));
		}
		state.borrow().authority_writer.stop();
		if !authorizing_observed && let Err(join) = authorizing.await {
			report(Notice::Partner(PartnerNotice::TaskFailed(join)));
		}
		state.borrow_mut().irc.stop();
		while let Some(ended) = std::future::poll_fn(|cx| state.borrow_mut().irc.tasks.poll_join_next(cx)).await {
			if let Err(join) = ended {
				report(Notice::Partner(PartnerNotice::TaskFailed(join)));
			}
		}
		// The runtime listeners close first, so their accept tasks end; the
		// sessions they admitted retire with the Host below.
		let failures = {
			let rows = state.borrow_mut().listeners.drain();
			let mut failures = Vec::new();
			for listener in rows {
				if let Err(error) = listener.close().await {
					failures.push(error);
				}
			}
			failures
		};
		for failure in failures {
			report(Notice::Trouble {
				source: "could not close room listeners".into(),
				reason: failure.to_string(),
			});
		}
		state.borrow_mut().boot_listener = None;
		let closed = owners.close().await;
		while let Some(ended) = connections.join_next().await {
			if let Err(join) = ended {
				report(Notice::Partner(PartnerNotice::TaskFailed(join)));
			}
		}
		while let Some(ended) = tasks.join_next().await {
			if let Err(join) = ended {
				report(Notice::Partner(PartnerNotice::TaskFailed(join)));
			}
		}
		// The workers end once their queues close: the state's history sender
		// goes with the state, and authority admission was closed above.
		drop(work);
		state.borrow_mut().history = None;
		let mut outcome = Error::fold(outcome, closed);
		while let Some(ended) = workers.join_next().await {
			let ended = ended.unwrap_or_else(|join| Err(Error::refused(format!("a server worker failed: {join}"))));
			outcome = Error::fold(outcome, ended);
		}
		outcome
	}
	/// Retire without serving: the same order a finished `serve` uses.
	pub async fn close(self) -> Result<(), Error> {
		self.state.borrow_mut().boot_listener = None;
		self.owners.close().await
	}
}

/// The opening sequence. Each step parks what it opened in `owners` before
/// the next fallible step, so `Owners::close` can retire exactly what exists.
async fn assemble(
	config: &Config,
	owners: &mut Owners,
	work: mpsc::Sender<Work>,
	report: Report,
	mut halt: std::pin::Pin<&mut impl Future<Output = ()>>,
) -> Result<Option<(Rc<RefCell<State>>, Vec<Minted>)>, Error> {
	let server = document::open(config.state.clone()).await?;
	let operations_document = operations::document::read(config.state.clone()).await?;
	// The endpoint binds before the Host exists, so the tap covers every
	// session this process ever opens.
	let minted = operations::mint(&config.asked, config.state.as_deref()).await?;
	if futures_util::FutureExt::now_or_never(halt.as_mut()).is_some() {
		return Ok(None);
	}
	if let Some(trace) = minted.iter().find(|held| held.capability.id == "trace") {
		owners.trace = Some(
			operations::trace::Trace::start(
				config.trace_port,
				trace.swiss.clone(),
				config.trace_publish.clone(),
				config.trace_connect.clone(),
				report.clone(),
			)
			.await?,
		);
	}
	let host = Host::from_seed_with_options(*server.authority.identity_seed(), rooms_glowcap::host_options())?;
	owners.host = Some(host.clone());
	// Retention is a stated policy: nothing records until the operator says
	// so, and then listed rooms keep their last lines behind the state
	// directory, or in memory when there is none.
	let (index, history) = if config.history {
		let (backend, index) = match config.history_directory() {
			Some(directory) => {
				let (backend, index) = history::restore(directory).await?;
				(Some(backend), index)
			}
			None => (None, Index::default()),
		};
		let sender = backend.map(|backend| {
			let (sender, receiver) = mpsc::channel(history::QUEUE);
			owners.history = Some((backend, receiver));
			sender
		});
		(Some(index), sender)
	} else {
		(None, None)
	};
	let authority = server.authority.clone();
	let mut listener_keys = rooms_platform::serving::onion::KeyFile(server.directory());
	let registry = Registry::new();
	let (operations, writer) = operations::document::open(operations_document, server.directory());
	owners.operations = Some(writer);
	let (authority_writer, writer) = authority::queue::open(server);
	owners.authority = Some(writer);
	report(Notice::Admission(config.admission.summary()));
	let state = Rc::new(RefCell::new(State::new(
		host,
		authority,
		authority_writer,
		Rooms::new(index, FileLimits::default()),
		registry,
		operations,
		work,
		history,
		report,
		config.admission,
	)));
	State::share(&state);
	// The boot capabilities publish before the listener opens, so a reused
	// swiss never has a window answering `unknown swissnum`.
	operations::publish(&state, &minted)?;
	let host = state.borrow().host.clone();
	host.publish(DIRECTORY, || Box::new(behavior::root(state.clone())))?;
	let (listener, locator) = Listener::open(&config.transport, &host, &mut listener_keys).await?;
	let listener = Rc::new(listener);
	owners.listener = Some(listener.clone());
	owners.local_endpoint = rooms_platform::serving::endpoint::bound(&config.transport, &listener);
	{
		let mut state = state.borrow_mut();
		// A tcp seat is named by its bare address, the way the announce line
		// names it; every other transport by its complete locator.
		let unannounceable =
			|error: glowcap::Error| Error::refused(format!("the listener's locator cannot be announced: {error}"));
		let announced = if locator.transport == glowcap::TRANSPORT_TCP {
			locator.designator.clone()
		} else {
			glowcap::format_locator_uri(&locator).map_err(unannounceable)?
		};
		state.set_location(locator).map_err(unannounceable)?;
		state.boot_listener = Some(listener);
		operations::listeners::adopt_boot(
			&mut state,
			operations::listeners::boot_transport(&config.transport),
			announced,
		);
		state.restore_links().map_err(Error::refused)?;
	}
	if futures_util::FutureExt::now_or_never(halt.as_mut()).is_some() {
		return Ok(None);
	}
	Ok(Some((state, minted)))
}

/// Serve one accepted partner to its end. Admission shares the owner a first
/// turn may already have created. The end withdraws everything it held.
pub(super) async fn served(state: Rc<RefCell<State>>, session: Session, report: Report) {
	let session = session;
	let connection = state.borrow_mut().admit(session.borrowed());
	let ended = serve_partner(session).await;
	state.borrow_mut().closed(connection);
	if let Err(ended) = ended {
		report(Notice::Partner(PartnerNotice::Ended(ended)));
	}
}

/// One queued delivery, awaited outside any turn.
async fn deliver(state: Rc<RefCell<State>>, work: Work) {
	match work {
		Work::Offer {
			id,
			target,
			sdp,
			from,
			originator,
			reply,
		} => {
			let session = state.borrow().session(target.connection).map(Session::borrowed);
			signaling::deliver_offer(state, id, (session, target.capability), sdp, from, originator, reply).await;
		}
		Work::Introduce {
			target,
			caller,
			mut resolver,
			pending,
			offline,
		} => {
			let session = state.borrow().session(target.connection).map(Session::borrowed);
			let outcome = match session {
				Some(session) => Some(
					session
						.send(
							&target.inbox,
							rooms_application::room::inbox::NOTIFY,
							&super::state::notice_args(&target.notice),
						)
						.await,
				),
				// The member's connection has already gone: nobody to ask.
				None => None,
			};
			let reason = match outcome {
				Some(Ok(_)) => pending,
				Some(Err(cause)) => {
					state.borrow().report(Notice::DeliveryFailed {
						what: "inbox request",
						cause,
					});
					offline
				}
				None => offline,
			};
			if let Err(cause) = resolver.break_with(&reason)
				&& caller.is_open()
			{
				state.borrow().report(Notice::AnswerUndeliverable {
					verb: rooms_application::protocol_data::INTRODUCE,
					cause,
				});
			}
		}
		Work::Task(_) => unreachable!("the loop routes tasks before delivering"),
	}
}
