//! The shared IRC identity. Receipts survive select cancellation; every socket
//! worker is joined before a replacement is opened.
use super::{config::Config, outbound::Pending, state::Shared};
use crate::irc::{Connection, Delivery, Event, Tls, WriteError, WriteReceipt};
use futures_util::{stream::FuturesUnordered, StreamExt};
use rooms_application::server::irc::{protocol, registration::Role, relay::Action};
use std::{future::Future, pin::Pin, time::Duration};
use tokio::{
	sync::{mpsc, watch},
	time::Instant,
};
type Receipt = Pin<Box<dyn Future<Output = Result<(), WriteError>>>>;
fn receipt(value: WriteReceipt) -> Receipt {
	Box::pin(value.wait())
}

pub(super) async fn run(
	shared: Shared,
	config: Config,
	tls: Option<Tls>,
	mut jobs: mpsc::Receiver<Pending>,
) -> Result<(), String> {
	let mut changed = shared.borrow().changed.subscribe();
	let mut current = None;
	let mut delay = Duration::from_secs(1);
	let mut result = Ok(());
	while !shared.borrow().stopping {
		let (connection, worker, mut events) = match Connection::open(
			config.endpoint.clone(),
			tls.clone(),
			Role::Feed,
			&config.nick,
			config.sasl.clone(),
			Duration::from_millis(1200),
		) {
			Ok(opened) => opened,
			Err(reason) => {
				result = Err(reason);
				break;
			}
		};
		let mut task = tokio::task::spawn_local(worker.run());
		let mut observed = false;
		let mut writing: Option<Receipt> = None;
		let mut controls = FuturesUnordered::<Receipt>::new();
		let mut deadline: Option<(u64, Instant)> = None;
		let mut registered_at: Option<Instant> = None;
		let mut reason = 'connected: loop {
			if shared.borrow().stopping {
				break "the IRC bridge is stopping".to_owned();
			}
			if let Some(reason) = shared.borrow_mut().failure.take() {
				break reason;
			}
			while let Some(action) = { shared.borrow_mut().actions.pop_front() } {
				match action {
					Action::Send(bytes) => match connection.write(bytes) {
						Ok(written) => {
							controls.push(receipt(written));
						}
						Err(error) => break 'connected error.reason,
					},
					Action::ArmJoinTimer(generation) => {
						deadline = Some((generation, Instant::now() + Duration::from_secs(30)))
					}
					Action::Fail(reason) => break 'connected reason,
				}
			}
			if writing.is_none() && current.is_some() && shared.borrow_mut().room.relay().joined() {
				// Keep the bounded original until its receipt proves delivery. A
				// retry may copy at most one IRC frame (512 bytes), never a queue.
				match connection.write(current.as_ref().map(|p: &Pending| p.bytes.clone()).unwrap()) {
					Ok(written) => writing = Some(receipt(written)),
					Err(error) => break error.reason,
				}
			}
			tokio::select! {
				biased;
				result = async { writing.as_mut().unwrap().await }, if writing.is_some() => {
					writing = None;
					if let Err(reason) = settle(&shared, &mut current, result) {
						break reason;
					}
				}
				ended = &mut task => {
					observed = true;
					break ended.unwrap_or_else(|e| Err(e.to_string()))
						.err().unwrap_or_else(|| "IRC connection ended".into());
				}
				Some(result) = controls.next(), if !controls.is_empty() => {
					if let Err(error) = result { break error.reason; }
				}
				_ = changed.changed() => {},
				post = jobs.recv(), if current.is_none() => { current = post; },
				event = events.next() => match event {
					Some(event) => {
						if let Err(reason) = observe(&shared, event, &mut registered_at, &mut deadline) {
							break reason;
						}
					}
					None => break "IRC event stream ended".into(),
				},
				_ = tokio::time::sleep_until(deadline.map(|(_, at)| at).unwrap_or_else(Instant::now)), if deadline.is_some() => {
					let (generation, _) = deadline.take().unwrap();
					let mut state = shared.borrow_mut();
					let actions = state.room.relay().join_timed_out(generation);
					state.actions(actions);
				}
			}
		};
		connection.stop();
		if !observed {
			let _ = task.await;
		}
		if let Some(writing) = writing {
			let _ = settle(&shared, &mut current, writing.await);
		}
		while controls.next().await.is_some() {}
		// EOF can complete the worker before its last decoded message is
		// selected. Deliver its bounded event tail before resetting the roster.
		while let Some(event) = events.next().await {
			if let Err(error) = observe(&shared, event, &mut registered_at, &mut deadline) {
				reason = format!("{reason}; {error}");
				break;
			}
		}
		{
			let mut state = shared.borrow_mut();
			state.actions.clear();
			state.failure = None;
			let effects = state.room.disconnected(&|_| None);
			state.apply(effects);
		}
		if shared.borrow().stopping {
			break;
		}
		eprintln!("rooms IRC bridge: {reason}; reconnecting");
		if registered_at.is_some_and(|at| at.elapsed() >= Duration::from_secs(30)) {
			delay = Duration::from_secs(1);
		}
		pause(&shared, &mut changed, delay).await;
		delay = (delay * 2).min(Duration::from_secs(30));
	}
	jobs.close();
	if let Some(post) = current {
		post.finish(&shared, Err("the IRC bridge stopped before delivery".into()));
	}
	while let Some(post) = jobs.recv().await {
		post.finish(&shared, Err("the IRC bridge stopped before delivery".into()));
	}
	result
}
fn observe(
	shared: &Shared,
	event: Event,
	registered_at: &mut Option<Instant>,
	deadline: &mut Option<(u64, Instant)>,
) -> Result<(), String> {
	let mut state = shared.borrow_mut();
	match event {
		Event::Registered { .. } => {
			*registered_at = Some(Instant::now());
			let actions = state.room.relay().connected();
			state.actions(actions);
		}
		Event::Message(message) => {
			if protocol::refused_channel(&message)
				.is_some_and(|c| protocol::fold(c) == protocol::fold(state.room.channel()))
			{
				return Err(format!(
					"IRC refused {}: {}",
					state.room.channel(),
					message.last().unwrap_or(&message.command)
				));
			}
			let effects = state.room.observe(&message, &|_| false, &|_| None)?;
			state.apply(effects);
			if state.room.relay().joined() {
				*deadline = None;
			}
		}
	}
	Ok(())
}

fn settle(shared: &Shared, current: &mut Option<Pending>, result: Result<(), WriteError>) -> Result<(), String> {
	match result {
		Ok(()) => {
			current.take().unwrap().finish(shared, Ok(()));
			Ok(())
		}
		Err(error) => {
			if error.delivery == Delivery::Uncertain {
				current
					.take()
					.unwrap()
					.finish(shared, Err(format!("IRC delivery is uncertain: {}", error.reason)));
			}
			Err(error.reason)
		}
	}
}
async fn pause(shared: &Shared, changed: &mut watch::Receiver<()>, delay: Duration) {
	let sleep = tokio::time::sleep(delay);
	tokio::pin!(sleep);
	while !shared.borrow().stopping {
		tokio::select! {
			_ = &mut sleep => break,
			_ = changed.changed() => {},
		}
	}
}
