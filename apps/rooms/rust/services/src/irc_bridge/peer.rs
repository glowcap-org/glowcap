use super::{
	behavior,
	config::Config,
	feed,
	notice::{Notice, Report},
	outbound,
	state::{Shared, State},
};
use crate::irc::Tls;
use glowcap::{Host, PendingWork, Session};
use rooms_application::{directory::registration::Id, server::irc::room::Room};
use rooms_platform::serving::{self, Listener};
use std::{cell::RefCell, collections::BTreeSet, future::Future, rc::Rc};
use tokio::{sync::watch, task::JoinSet};
pub(super) const CONNECTIONS: usize = 512;

pub struct Ready {
	pub port: u16,
	pub room: String,
}
pub async fn run(
	config: Config,
	report: Report,
	halt: impl Future<Output = ()>,
	ready: impl FnOnce(&Ready),
) -> Result<(), String> {
	let tls = if config.tls { Some(Tls::system().await?) } else { None };
	let mut entropy = [0u8; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|e| e.to_string())?;
	let room = Room::new(
		&config.network,
		&config.channel,
		&config.nick,
		Id::from_entropy(entropy).as_str(),
		&config.network,
	)?;
	if room.line_bytes() == 0 {
		return Err("IRC channel leaves no room for a Rooms message".into());
	}
	let (posts, jobs) = outbound::open();
	let (changed, mut changes) = watch::channel(());
	let shared = Rc::new(RefCell::new(State::new(
		room,
		posts,
		changed,
		config.sasl.is_some(),
		report.clone(),
	)));
	let host = Host::with_options(rooms_glowcap::host_options()).map_err(|e| e.to_string())?;
	if let Err(error) = host.publish(rooms_application::directory::NAME, || {
		Box::new(behavior::directory(shared.clone()))
	}) {
		return crate::cleanup::combine(
			Err(error.to_string()),
			host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
		);
	}
	let (listener, locator) = match Listener::open(&config.transport, &host, &mut serving::onion::KeyFile(None)).await {
		Ok(opened) => opened,
		Err(error) => {
			return crate::cleanup::combine(
				Err(error.to_string()),
				host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			);
		}
	};
	let port = match locator.designator.rsplit_once(':').and_then(|(_, p)| p.parse().ok()) {
		Some(port) => port,
		None => {
			let result = crate::cleanup::combine(
				Err("IRC bridge listener returned no TCP port".into()),
				listener.close().await.map_err(|e| e.to_string()),
			);
			return crate::cleanup::combine(result, host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()));
		}
	};
	ready(&Ready {
		port,
		room: shared.borrow().room.name().into(),
	});
	let mut feeding = tokio::task::spawn_local(feed::run(shared.clone(), config, tls, jobs));
	let mut observed = false;
	let mut sessions = JoinSet::new();
	let mut closing = JoinSet::<(u64, glowcap::Result<()>)>::new();
	let mut closing_ids = BTreeSet::new();
	let mut retry = serving::Retry::default();
	tokio::pin!(halt);
	let mut result = loop {
		tokio::select! {
			_ = &mut halt => break Ok(()),
			ended = &mut feeding => {
				observed = true;
				break ended.map_err(|e| e.to_string()).and_then(|r| r)
					.and(Err("IRC feed owner ended while serving".into()));
			}
			accepted = listener.accept(), if sessions.len() < CONNECTIONS && retry.ready() => match accepted {
				Ok(session) => { sessions.spawn_local(serve(shared.clone(), session)); }
				Err(error) if serving::accept_ended(&error) => break Err(error.to_string()),
				Err(error) => {
					report(Notice::AcceptRefused(error.to_string()));
					retry.refused();
				}
			},
			_ = retry.wait() => {}
			Some(ended) = sessions.join_next(), if !sessions.is_empty() => {
				if let Err(error) = ended { break Err(error.to_string()); }
			}
			Some(ended) = closing.join_next(), if !closing.is_empty() => {
				match ended {
					Ok((id, result)) => {
						closing_ids.remove(&id);
						if let Err(error) = result { break Err(error.to_string()); }
					}
					Err(error) => break Err(error.to_string()),
				}
			}
			_ = changes.changed() => {
				let broken = std::mem::take(&mut shared.borrow_mut().broken);
				for id in broken {
					if closing_ids.contains(&id) { continue; }
					let session = shared.borrow().sessions.get(&id).map(Session::borrowed);
					if let Some(session) = session {
						closing_ids.insert(id);
						closing.spawn_local(async move { (id, session.close(PendingWork::Cancel).await) });
					}
				}
			}
		}
	};
	{
		let mut state = shared.borrow_mut();
		state.stopping = true;
		state.posts.stop();
		state.changed.send_replace(());
	}
	result = crate::cleanup::combine(result, listener.close().await.map_err(|e| e.to_string()));
	if !observed {
		result = crate::cleanup::combine(result, feeding.await.map_err(|e| e.to_string()).and_then(|r| r));
	}
	result = crate::cleanup::combine(result, host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()));
	while let Some(ended) = sessions.join_next().await {
		result = crate::cleanup::combine(result, ended.map_err(|e| e.to_string()));
	}
	while let Some(ended) = closing.join_next().await {
		result = crate::cleanup::combine(
			result,
			ended
				.map_err(|e| e.to_string())
				.and_then(|(_, r)| r.map_err(|e| e.to_string())),
		);
	}
	result
}
async fn serve(shared: Shared, session: Session) {
	let admitted = shared.borrow_mut().admit(session.borrowed());
	let id = match admitted {
		Ok(id) => id,
		Err(_) => {
			// tolerant: the partner was refused a seat; a close that fails
			// still drops the socket, and the bridge has nothing else to
			// do for a session it never admitted.
			let _ = session.close(PendingWork::Cancel).await;
			return;
		}
	};
	if let Err(error) = serving::serve_partner(session).await {
		(shared.borrow().report)(Notice::ConnectionEnded(error.to_string()));
	}
	shared.borrow_mut().closed(id);
}
