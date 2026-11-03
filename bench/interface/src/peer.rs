//! One TCP pair and one independently checked receipt actor for both clients.
use crate::meter::Meter;
#[cfg(feature = "allocation-metrics")]
use crate::meter::NativeAllocator;
use glowcap::{Argument, Host, HostOptions, HostProfile, Ref};
use std::{cell::RefCell, rc::Rc, sync::Arc};

#[derive(Default)]
pub struct Effects {
	pub queries: usize,
	pub submissions: usize,
	pub effects: usize,
	pub ordinary: usize,
	last: Option<(i64, String)>,
}
pub struct Pair {
	pub connection: crate::connection::Pair,
	pub target: Ref,
	pub effects: Rc<RefCell<Effects>>,
	observer: Option<crate::wire::Observer>,
}
impl Pair {
	pub async fn open(_meter: Arc<Meter>, observe: bool) -> Self {
		#[cfg(feature = "allocation-metrics")]
		let context = glowcap::Context::with_allocator(Box::new(NativeAllocator(_meter))).unwrap();
		let options = HostOptions::with_profile(HostProfile::Interop);
		#[cfg(feature = "allocation-metrics")]
		let host = Host::new_in(&context, options).unwrap();
		#[cfg(not(feature = "allocation-metrics"))]
		let host = Host::with_options(options).unwrap();
		let child = host
			.spawn(|verb, args| {
				assert_eq!(verb, Some("read"));
				assert!(args.is_empty());
				Ok(Argument::String("child".into()))
			})
			.unwrap();
		let effects = Rc::new(RefCell::new(Effects::default()));
		let received = effects.clone();
		host.publish("bench", move || {
			let child = child.clone();
			let received = received.clone();
			Box::new(move |verb, args| {
				let mut state = received.borrow_mut();
				match verb {
					None => {
						assert_eq!(args.len(), 1);
						assert_eq!(args[0].as_str(), Some("benchmark input"));
						state.ordinary += 1;
						Ok(Argument::String("benchmark reply".into()))
					}
					Some("mutation-sequence") => {
						assert!(args.is_empty());
						state.queries += 1;
						Ok(((state.effects + 1) as i64).into())
					}
					Some("mutate") => {
						assert_eq!(args.len(), 3);
						let sequence = args[0].as_i64().unwrap();
						assert_eq!(args[1].as_str(), Some("add"));
						assert_eq!(args[2].as_str(), Some("benchmark input"));
						state.submissions += 1;
						if let Some((previous, text)) = &state.last
							&& sequence == *previous
						{
							assert_eq!(args[2].as_str(), Some(text.as_str()));
							return Ok((&child).into());
						}
						assert_eq!(sequence, (state.effects + 1) as i64);
						state.effects += 1;
						state.last = Some((sequence, args[2].as_str().unwrap().to_owned()));
						Ok((&child).into())
					}
					_ => panic!("unexpected benchmark call"),
				}
			})
		})
		.unwrap();
		#[cfg(feature = "allocation-metrics")]
		let client_host = Host::new_in(&context, options).unwrap();
		#[cfg(not(feature = "allocation-metrics"))]
		let client_host = Host::with_options(options).unwrap();
		let (connection, observer) = if observe {
			let (pair, observer) = crate::wire::Observer::open(&host, &client_host).await;
			(pair, Some(observer))
		} else {
			(
				crate::connection::Pair::open_with_client(&host, &client_host).await,
				None,
			)
		};
		let negotiated = connection.client.profile().unwrap();
		assert_eq!(negotiated.codec, options.codec);
		assert_eq!(negotiated.captp_version, options.captp_version);
		let target = connection.client.fetch("bench").await.unwrap();
		Self {
			connection,
			target,
			effects,
			observer,
		}
	}
	pub fn start_wire(&self) {
		self.observer.as_ref().unwrap().start();
	}
	pub async fn close(self) -> Option<crate::wire::Counts> {
		drop(self.target);
		if let Some(observer) = &self.observer {
			observer.closing();
		}
		self.connection.close().await;
		match self.observer {
			Some(observer) => Some(observer.close().await),
			None => None,
		}
	}
}
