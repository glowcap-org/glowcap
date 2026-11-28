//! `bot serve`: take the lease, settle the configuration and the session
//! link, reach the session, and run the loop until SIGINT, SIGTERM, or SIGHUP
//! ends it. Moving to a replacement link is `serve/replace.rs`, and the test
//! stand-in for a session is `serve/stand_in.rs`.
mod access;
mod replace;
mod stand_in;

use super::{
	config::{self, Config},
	conversations::Conversations,
	engine::{self, Core, Env, Publishing},
	error::{Error, LinkStage, START_FRESH},
	fault::{self, Kill},
	group, harness,
	harness_sessions::HarnessSessions,
	home, inbox,
	ledger::{Ledger, Unlisted},
	link::{self, Link, Linking},
	opens,
	request::Request,
	rooms::{Rooms, captp},
	status::Facts,
	store::Store,
	words,
};
use tokio::{signal::unix, sync::watch};

/// Flags `serve` reads, and the stand-in's when the build has one.
fn flags() -> Vec<&'static str> {
	let mut flags = config::variable_flags();
	flags.extend([link::REPLACE_FLAG, config::NO_INSTRUCTIONS]);
	flags.extend(stand_in::FLAGS);
	flags
}

fn stop_signal() -> Result<watch::Receiver<bool>, Error> {
	let mut interrupt = unix::signal(unix::SignalKind::interrupt()).map_err(Error::io("listening for SIGINT"))?;
	let mut terminate = unix::signal(unix::SignalKind::terminate()).map_err(Error::io("listening for SIGTERM"))?;
	let mut hangup = unix::signal(unix::SignalKind::hangup()).map_err(Error::io("listening for SIGHUP"))?;
	let (stop, stopping) = watch::channel(false);
	tokio::spawn(async move {
		tokio::select! {
			_ = interrupt.recv() => (),
			_ = terminate.recv() => (),
			_ = hangup.recv() => (),
		}
		stop.send_replace(true);
		// The receivers read a dropped sender as no stop, so keep it.
		std::future::pending::<()>().await;
	});
	Ok(stopping)
}

pub async fn run(request: &Request) -> Result<(), Error> {
	// The handler is installed before the store lease is taken, so a stop sent
	// to a process the status shows as running is always handled. A stop that
	// arrives while the serve is still starting is read when the loop begins.
	let shutdown = stop_signal()?;
	request.only(&flags())?;
	// The settings are also variables, so a container's `environment:` can
	// carry what its `command:` would. A variable never replaces a flag.
	let settings = config::variable_flags();
	let variables: Vec<_> = std::env::vars_os().collect();
	Request::refuse_unreadable_variables(&variables)?;
	let names = variables
		.iter()
		.filter_map(|(name, _)| name.to_str().map(str::to_owned));
	Request::refuse_unknown_variables(names, &settings, fault::VARIABLES)?;
	let request = &request.with_environment(&settings, |name| std::env::var(name).ok());
	let directory = stand_in::directory(request)?;
	let prepared = prepare(
		request,
		if directory.is_some() {
			Session::StandIn
		} else {
			Session::Linked
		},
	)?;
	// A build without the stand-in has no directory to match.
	#[cfg_attr(
		not(feature = "test-support"),
		allow(unreachable_code, reason = "the directory type is uninhabited")
	)]
	match directory {
		Some(directory) => stand_in::run(directory, prepared, shutdown).await,
		None => reach(prepared, shutdown).await,
	}
}

/// What a start settles before it reaches the session: the state, the
/// settings, the agent, and the link it was given.
struct Prepared {
	store: Store,
	/// The settings stored with the link, or none for a first start.
	stored: Option<Config>,
	config: Config,
	harness: Box<dyn harness::Harness>,
	/// The facts `status` reports, which the start has published since it took
	/// the lease.
	facts: Facts,
	linking: Option<Linking>,
}

/// Which session a start serves.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Session {
	/// The real session, reached through a stored link.
	Linked,
	/// The test stand-in for a session, which stores no link.
	StandIn,
}

/// Take the lease and settle the settings and the agent.
fn prepare(request: &Request, session: Session) -> Result<Prepared, Error> {
	let standing_in = session == Session::StandIn;
	let store = Store::open(&request.state)?;
	let link = Link::load(store.root())?;
	// The settings are stored first and the link last, so a stored link always
	// had its settings, and settings without a link are from a first start that
	// stopped between the two, which begins again. The stand-in stores no link,
	// so its stored config is complete without one.
	let loaded = Config::load(&store)?;
	if link.is_some() && loaded.is_none() && !standing_in {
		return Err(restore_config(&format!(
			"a session link is stored while {}",
			words::CONFIG_MISSING
		)));
	}
	let stored = loaded.filter(|_| link.is_some() || standing_in);
	let config = Config::resolve(stored.clone(), request)?;
	let harness =
		harness::lookup(&config.harness, &config.glowcap).map_err(|error| Error::Config(error.to_string()))?;
	harness::present(&*harness, std::env::var_os("PATH").as_deref()).map_err(Error::Config)?;
	// This process holds the lease, so the status says so before anything that
	// can wait: the previous process's facts, its access and pid, are gone, and
	// `ready` reads this one's access as unknown until the session answers. A
	// start that cannot write it serves nothing under the old one.
	let facts = Facts {
		pid: std::process::id(),
		harness: harness.name().to_owned(),
		model: config.model.clone(),
		permission: config.permission,
		..Facts::default()
	};
	facts.claim(&store)?;
	// A harness a killed serve left running may still act, so it ends before
	// anything reads the notes it could write. Its tool commands run in
	// sessions of their own and survive that, so a claim of an action is
	// judged by the process that wrote it (`opens::action`), never assumed
	// dead.
	group::reap_all(&store)?;
	let linking = link::resolve(link, request)?;
	Ok(Prepared {
		store,
		stored,
		config,
		harness,
		facts,
		linking,
	})
}

/// Reach the session with the link and serve. A replacement link is saved
/// only after the old access settled what it sent (`serve/replace.rs`).
async fn reach(prepared: Prepared, mut shutdown: watch::Receiver<bool>) -> Result<(), Error> {
	let Prepared {
		store,
		stored,
		config,
		harness,
		mut facts,
		linking,
	} = prepared;
	let Some(linking) = linking else {
		return Err(Error::Config(
			"--link is required the first time: pass the session link the session's owner issued".into(),
		));
	};
	let mut settled = None;
	if let Some(old) = linking.replaced() {
		settled = replace::replace_link(old.clone(), &store, &shutdown).await?;
	}
	if *shutdown.borrow() {
		return Ok(());
	}
	let rooms = captp::Attached::open(&store, linking.link().clone())?;
	let link = linking.link().clone();
	let start = match linking.stage() {
		LinkStage::Stored => Start::Stored,
		LinkStage::First => Start::First(Some(link)),
		LinkStage::Replacing => {
			let (ledger, unlisted) = match settled {
				Some(settled) => {
					facts.unconfirmed = settled.unconfirmed;
					(Some(settled.ledger), settled.unlisted)
				}
				None => (None, None),
			};
			Start::Replacing { link, ledger, unlisted }
		}
	};
	let (send, receive) = tokio::sync::mpsc::channel(1);
	let (ready, started) = tokio::sync::oneshot::channel();
	let serving = Serving {
		facts,
		start,
		checkins: receive,
		ready: Some(ready),
	};
	let grant = linking.link().fingerprint();
	// Both workers share the serving lifetime. Drain live harness processes
	// even when the clock's durable store fails while a turn is running.
	let (stop, stopping) = watch::channel(*shutdown.borrow());
	let main = serve(&rooms, &store, stored, &config, &*harness, stopping, serving);
	tokio::pin!(main);
	let served = tokio::select! {
		served = &mut main => served,
		() = engine::stopping(&mut shutdown) => {
			stop.send_replace(true);
			main.await
		}
		result = async {
			if started.await.is_err() { return std::future::pending().await; }
			super::reminders::run(store.root(), &rooms, &grant, config.conversation_limit, send).await
		} => {
			stop.send_replace(true);
			let drained = main.await;
			result.and(drained)
		}
	};
	rooms.close().await;
	if matches!(served, Err(Error::Access { .. })) {
		super::reminders::access_lost(store.root(), &grant)?;
	}
	served
}

/// What a start serves with once the session answers its link.
struct Serving {
	ready: Option<tokio::sync::oneshot::Sender<()>>,
	checkins: tokio::sync::mpsc::Receiver<super::reminders::CheckIn>,
	/// The facts `status` reports, which the serving loop publishes from here.
	facts: Facts,
	start: Start,
}

/// How a start reaches its link, and what it holds until the link is stored.
enum Start {
	/// A first link, stored once the session has answered it. The stand-in
	/// has no link to store.
	First(Option<Link>),
	/// A link that replaces the stored one, stored once the session has
	/// answered it, the ledger the old access settled, or none when the bot
	/// had no ledger yet, and why the old access could not list, which is
	/// recorded once the link is stored.
	Replacing {
		link: Link,
		ledger: Option<Ledger>,
		unlisted: Option<Unlisted>,
	},
	/// The stored link, which is already saved.
	Stored,
}

impl Start {
	fn stage(&self) -> LinkStage {
		match self {
			Self::First(_) => LinkStage::First,
			Self::Replacing { .. } => LinkStage::Replacing,
			Self::Stored => LinkStage::Stored,
		}
	}

	/// The link to store once the session has answered it.
	fn unsaved(&self) -> Option<&Link> {
		match self {
			Self::First(link) => link.as_ref(),
			Self::Replacing { link, .. } => Some(link),
			Self::Stored => None,
		}
	}

	/// Why the old access of a replacement could not list, to record once
	/// its link is stored, or none for a start that replaces nothing.
	fn unlisted(&self) -> Option<Option<Unlisted>> {
		match self {
			Self::Replacing { unlisted, .. } => Some(*unlisted),
			Self::First(_) | Self::Stored => None,
		}
	}

	/// The ledger the old access settled, which a start loads once.
	fn take_ledger(&mut self) -> Option<Ledger> {
		match self {
			Self::Replacing { ledger, .. } => ledger.take(),
			Self::First(_) | Self::Stored => None,
		}
	}
}

/// The refusal to start over from nothing: what was lost, and the two ways on.
fn restore_config(lost: &str) -> Error {
	Error::Config(format!("{lost}. {} {}", words::RESTORE_OR_START_FRESH, START_FRESH))
}

/// The ledger to serve from, or `None` when a stop came before a first start
/// reached the session. A refused or revoked first link is an error. A first
/// start, with no configuration stored, reads to the head of activity
/// and starts there, so history from before the bot was set up is never
/// answered. A configured bot whose ledger is gone is refused, because
/// starting over would answer old messages again.
async fn ledger<R: Rooms>(
	rooms: &R,
	store: &Store,
	stored: Option<&Config>,
	shutdown: &watch::Receiver<bool>,
) -> Result<Option<Ledger>, Error> {
	// A first start has sent nothing, so a note in opens/ is an earlier link's,
	// and looking at it under this access would act for one that never sent
	// it. A claim of an action sends nothing, and the list asks only about
	// what this access sent.
	if stored.is_none() && opens::held(store.root())? {
		return Err(restore_config(&format!(
			"config.json or session.link is missing while {}",
			words::OPENS_FROM_EARLIER_LINK
		)));
	}
	match (Ledger::load(store)?, stored) {
		(Some(ledger), Some(_)) => Ok(Some(ledger)),
		// A ledger that holds open turns is never discarded without a person.
		(Some(ledger), None) if !ledger.open().is_empty() => Err(restore_config(
			"config.json or session.link is missing while the ledger holds replies still to send, and starting over would drop them",
		)),
		// With no settings stored, a ledger on disk with no open turn is from a
		// first start that stopped before it stored them, so this start begins
		// again.
		(_, None) => {
			let Some(head) = engine::head(rooms, store, shutdown.clone()).await? else {
				return Ok(None);
			};
			store.log(&format!("first start: serving from the head of activity at {head:?}"));
			Ledger::start(store, head).map(Some)
		}
		(None, Some(_)) => Err(Ledger::invariant(
			"the bot is configured but its ledger is missing, and starting over would answer old messages",
		)),
	}
}

async fn serve<R: Rooms>(
	rooms: &R,
	store: &Store,
	stored: Option<Config>,
	config: &Config,
	harness: &dyn harness::Harness,
	shutdown: watch::Receiver<bool>,
	mut serving: Serving,
) -> Result<(), Error> {
	let ledger = match serving.start.take_ledger() {
		Some(ledger) => ledger,
		None => {
			let Some(ledger) = ledger(rooms, store, stored.as_ref(), &shutdown).await? else {
				return Ok(());
			};
			ledger
		}
	};
	home::create(store.root())?;
	// A first start has nothing sent to ask about.
	let mut leftovers = if stored.is_some() {
		let Some(leftovers) = access::ask(
			rooms,
			store,
			&ledger,
			serving.start.stage(),
			access::Paused::Wait(&mut serving.facts),
			&shutdown,
		)
		.await?
		else {
			return Ok(());
		};
		leftovers
	} else {
		access::Leftovers::default()
	};
	let mine = leftovers.take_mine();
	let core = Core::new(
		rooms,
		store,
		ledger,
		serving.facts,
		leftovers.take_by_echo(),
		Publishing::Status,
	);
	let env = Env::new(
		core,
		config,
		harness,
		HarnessSessions::load(store)?,
		Conversations::load(store)?,
	);
	inbox::sweep(store, &env.ledger.borrow().open());
	let name = harness.name();
	let served = engine::serve(&env, shutdown, serving.checkins, serving.start.stage(), || {
		// Every step is safe to repeat, because a write that fails is tried
		// again with the next read. The link is the one commit of a
		// replacement, so only why the old access went unlisted and the notes
		// the session's answers place follow it. A kill between the link and
		// that record loses the record, so status then says nothing of it.
		// No setting names the session, so a stop between the settings and the
		// link leaves a consistent pair: the next start has the settings it was
		// given and the link that was stored.
		if stored.as_ref() != Some(config) {
			config.save(store)?;
		}
		fault::hit(Kill::BeforeLink);
		fault::link_write()?;
		if let Some(link) = serving.start.unsaved() {
			link.save(store)?;
			fault::hit(Kill::AfterLink);
		}
		if let Some(unlisted) = serving.start.unlisted() {
			env.ledger.borrow_mut().record_unlisted(store, unlisted)?;
			env.publish();
		}
		leftovers.place(store, &mut env.ledger.borrow_mut())?;
		crate::announce::announce(&format!("ROOMS-BOT-SERVING {name}"));
		if let Some(ready) = serving.ready.take() {
			let _ = ready.send(());
		}
		Ok(())
	});
	// The opens' owner and the replaced lines' keeper run beside the loop and
	// end with it.
	tokio::select! {
		biased;
		served = served => served,
		never = opens::settle(&env) => match never {},
		never = engine::settle_replaced(&env, mine) => match never {},
	}
}
