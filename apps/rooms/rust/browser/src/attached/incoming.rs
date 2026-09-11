//! A registered tab answers cold WebRTC connections on its existing Host.
//! Directory loss stops new offers; accepted connections keep serving until
//! their own transport closes or the application retires the Host.
use super::{driver::Driver, Result};
use crate::{ice, platform::Platform, signaling::Listener};
use glowcap::PendingWork;
use rooms_glowcap::client::directory::{registration::Registration, Directory};
use std::{cell::RefCell, future::poll_fn, rc::Rc};
use tokio::{sync::watch, task::JoinSet};

pub(super) struct Incoming {
	stop: watch::Sender<bool>,
	listening: watch::Receiver<Option<Result<()>>>,
}
impl Incoming {
	pub async fn open(
		driver: &Driver,
		directory: Directory<Platform>,
		mut registration: Registration<Platform>,
		ice: ice::Source,
	) -> Result<Self> {
		let listener = Listener::open(directory, glowcap::HANDSHAKE_TIMEOUT)
			.await
			.map_err(|e| e.to_string())?;
		let (stop, mut stopping) = watch::channel(false);
		let pressure = stop.clone();
		let registration_stop = stop.clone();
		let failure = Rc::new(RefCell::new(Ok(())));
		let observed = failure.clone();
		let (finished, listening) = watch::channel(None);
		driver.background(0, move |environment| async move {
			let admission = environment.incoming.admission();
			let workers = Rc::new(RefCell::new(JoinSet::new()));
			let accepting = workers.clone();
			let failures = observed.clone();
			let serve = listener.serve(
				move || { let ice = ice.clone(); async move { ice.configuration().await.map_err(|_| crate::signaling::Error::Admission("Rooms could not obtain ICE configuration")) } },
				async move { if !*stopping.borrow() { let _ = stopping.changed().await; } },
				move |accepted| {
					let session = match accepted {
						Ok(session) => session,
						Err(error) => { *failures.borrow_mut() = Err(error.to_string()); return; }
					};
					if let Err(refused) = admission.offer(session) {
						let session = refused.session;
						pressure.send_replace(true);
						if refused.capacity { *failures.borrow_mut() = Err("Rooms incoming connection capacity is exhausted".into()); }
						// A single overflow stops this listener before it can deliver
						// another session. Its close stays owned until observed.
						accepting.borrow_mut().spawn_local(async move { session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()) });
					}
				},
			);
			tokio::pin!(serve);
			let notifications = async { while registration.next().await.map_err(|e| e.to_string())?.is_some() {} Ok::<_, String>(()) };
			tokio::pin!(notifications);
			let mut notices = true;
			let result = loop {
				tokio::select! {
					result = &mut serve => break result.map_err(|e| e.to_string()),
					result = &mut notifications, if notices => { notices = false; registration_stop.send_replace(true); if let Err(error) = result { *observed.borrow_mut() = Err(error); } },
					Some(result) = poll_fn(|cx| workers.borrow_mut().poll_join_next(cx)) => {
						let result = result.map_err(|e| e.to_string()).and_then(|result| result);
						if let Err(error) = result { *observed.borrow_mut() = Err(error); }
					},
				}
			};
			finished.send_replace(Some(result.clone()));
			if let Err(error) = result { *observed.borrow_mut() = Err(error); }
			while let Some(result) = poll_fn(|cx| workers.borrow_mut().poll_join_next(cx)).await {
				if let Err(error) = result.map_err(|e| e.to_string()).and_then(|result| result) { *observed.borrow_mut() = Err(error); }
			}
			observed.borrow().clone().map(|()| wasm_bindgen::JsValue::UNDEFINED)
		})?;
		Ok(Self { stop, listening })
	}
	pub fn outcome(&self) -> Result<()> {
		match self.listening.borrow().as_ref() {
			None if self.listening.has_changed().is_err() => Err("Rooms signaling listener lost its worker".into()),
			None => Ok(()),
			Some(Ok(())) => Err("Rooms signaling listener ended".into()),
			Some(Err(error)) => Err(error.clone()),
		}
	}
	pub fn listening(&self) -> watch::Receiver<Option<Result<()>>> {
		self.listening.clone()
	}
}
impl Drop for Incoming {
	fn drop(&mut self) {
		self.stop.send_replace(true);
	}
}
