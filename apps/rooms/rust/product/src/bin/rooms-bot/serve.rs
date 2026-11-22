//! `bot serve`: take the lease, settle the configuration and the session
//! link, reach the session, and run the loop until SIGINT, SIGTERM, or SIGHUP
//! ends it.
use super::{
	config::{self, Config},
	conversations::Conversations,
	engine::{self, Env},
	error::Error,
	harness, home, inbox,
	ledger::Ledger,
	link::{self, Link},
	opens,
	request::Request,
	rooms::{Rooms, captp},
	sessions::Sessions,
	status::Facts,
	store::Store,
};
#[cfg(feature = "test-support")]
use std::path::Path;
use tokio::{signal::unix, sync::watch};

/// Flags `serve` reads. `rooms-dir` selects the directory stand-in for a
/// session that process tests use, and exists only with the `test-support`
/// feature.
fn flags() -> Vec<&'static str> {
	let mut flags = config::FLAGS.to_vec();
	flags.extend([link::FLAG, link::REPLACE_FLAG]);
	#[cfg(feature = "test-support")]
	flags.push("rooms-dir");
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
	request.only(&flags())?;
	// The settings are also variables, so a container's `environment:` can
	// carry what its `command:` would. A variable never replaces a flag.
	let settings: Vec<&str> = config::FLAGS.iter().copied().chain([link::FLAG]).collect();
	let request = &request.with_environment(&settings, |name| std::env::var(name).ok());
	let store = Store::open(&request.state)?;
	let stored = Config::load(&store)?;
	let config = Config::resolve(stored.clone(), request)?;
	let harness =
		harness::lookup(&config.harness, &config.glowcap).map_err(|error| Error::Config(error.to_string()))?;
	harness::present(&*harness, std::env::var_os("PATH").as_deref()).map_err(Error::Config)?;
	let shutdown = stop_signal()?;
	let settled = link::settle(Link::load(store.root())?, request)?;
	#[cfg(feature = "test-support")]
	if let Some(directory) = request.single("rooms-dir")? {
		let rooms = super::rooms::files::Files::open(Path::new(directory));
		return serve(&rooms, &store, stored, &config, &*harness, shutdown, Carried::default()).await;
	}
	let Some(settled) = settled else {
		return Err(Error::Config(
			"--link is required the first time: pass the session link the session's owner issued".into(),
		));
	};
	let carried = match settled.replaced {
		Some(old) => hand_over(old, &store, &config, &*harness, &shutdown).await?,
		None => Carried::default(),
	};
	if *shutdown.borrow() {
		return Ok(());
	}
	if settled.save {
		settled.link.save(&store)?;
	}
	let rooms = captp::Attached::open(&store, settled.link)?;
	let served = serve(&rooms, &store, stored, &config, &*harness, shutdown, carried).await;
	rooms.close().await;
	served
}

/// What a replaced link's access gave up on, for `status` to count.
#[derive(Default)]
struct Carried {
	unconfirmed: u64,
	unsettled_opens: u64,
}

/// Let the replaced link's access settle the lines and the direct-message
/// opens it sent. The new link is saved only after, so a bot stopped here is
/// started again with both.
async fn hand_over(
	old: Link,
	store: &Store,
	config: &Config,
	harness: &dyn harness::Harness,
	shutdown: &watch::Receiver<bool>,
) -> Result<Carried, Error> {
	let Some(ledger) = Ledger::load(store)? else {
		return Ok(Carried::default());
	};
	let rooms = captp::Attached::open(store, old)?;
	let env = environment(&rooms, store, config, harness, ledger)?;
	let handed = engine::hand_over(&env, shutdown).await;
	let opens = match &handed {
		Ok(_) if !*shutdown.borrow() => opens::look(&rooms, store, true).await,
		_ => Ok(0),
	};
	rooms.close().await;
	Ok(Carried {
		unconfirmed: handed?,
		unsettled_opens: opens?,
	})
}

fn environment<'a, R: Rooms>(
	rooms: &'a R,
	store: &'a Store,
	config: &'a Config,
	harness: &'a dyn harness::Harness,
	ledger: Ledger,
) -> Result<Env<'a, R>, Error> {
	Ok(Env {
		rooms,
		store,
		config,
		harness,
		ledger: ledger.into(),
		sessions: Sessions::load(store)?.into(),
		conversations: Conversations::load(store)?.into(),
		facts: Facts {
			pid: std::process::id(),
			harness: config.harness.clone(),
			..Facts::default()
		}
		.into(),
		halted: tokio::sync::Notify::new(),
		access_changes: 0.into(),
	})
}

/// The ledger to serve from, or `None` when a stop came before a first start
/// reached the session. A first start, with no configuration and no
/// ledger, reads to the head of activity and starts there, so history from
/// before the bot was set up is never answered. A configured bot whose ledger
/// is gone is refused, because starting over would answer old messages again.
async fn ledger<R: Rooms>(
	rooms: &R,
	store: &Store,
	stored: Option<&Config>,
	shutdown: &watch::Receiver<bool>,
) -> Result<Option<Ledger>, Error> {
	match (Ledger::load(store)?, stored) {
		(Some(ledger), _) => Ok(Some(ledger)),
		(None, None) => {
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
	carried: Carried,
) -> Result<(), Error> {
	let Some(ledger) = ledger(rooms, store, stored.as_ref(), &shutdown).await? else {
		return Ok(());
	};
	if stored.as_ref() != Some(config) {
		config.save(store)?;
	}
	home::create(store.root())?;
	let env = environment(rooms, store, config, harness, ledger)?;
	{
		let mut facts = env.facts.borrow_mut();
		facts.unconfirmed = carried.unconfirmed;
		facts.unsettled_opens = carried.unsettled_opens;
	}
	inbox::sweep(store, &env.ledger.borrow().open());
	opens::settle(&env).await?;
	let name = harness.name();
	engine::serve(&env, shutdown, || {
		crate::announce::announce(&format!("ROOMS-BOT-SERVING {name}"));
	})
	.await
}
