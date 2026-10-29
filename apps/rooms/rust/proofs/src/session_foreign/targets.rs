//! One surviving exporter owns two disjoint populations across source restarts.
use super::FIELDS;
use futures_util::{StreamExt, stream};
use glowcap::{Argument, CaptpVersion, Host, Locator, PendingWork, Ref, Session, format_sturdyref};
use std::{collections::HashSet, time::Duration};

pub struct Target {
	pub reference: Ref,
	pub uri: String,
}
pub struct Targets {
	pub host: Host,
	pub locator: Locator,
	pub uris: [Vec<String>; 2],
}
impl Targets {
	pub fn new() -> Self {
		let host = Host::from_seed([91; 32]).unwrap();
		let locator = Locator::bare("tcp", "127.0.0.1:9010");
		Self::publish(host, locator)
	}
	#[cfg(target_arch = "wasm32")]
	pub fn browser() -> Self {
		let host = Host::from_seed([91; 32]).unwrap();
		let locator = Locator::bare("webrtc", &host.designator().unwrap());
		Self::publish(host, locator)
	}
	fn publish(host: Host, locator: Locator) -> Self {
		host.set_advertised_locator(&locator).unwrap();
		let uris = core::array::from_fn(|population| {
			(0..FIELDS)
				.map(|field| {
					let identity = population * FIELDS + field;
					let swiss = host
						.publish_durable(move || {
							Box::new(move |verb, args| {
								let verb = verb.ok_or("fixture requires a method")?;
								assert_eq!((verb, args.len()), ("identity", 0));
								Ok(Argument::Integer(identity as i64))
							})
						})
						.unwrap();
					format_sturdyref(&locator, swiss.as_bytes(), CaptpVersion::V1_0).unwrap()
				})
				.collect()
		});
		Self { host, locator, uris }
	}
	pub async fn connect(&self, source: &Host) -> (Session, Session) {
		let (left, right) = tokio::io::duplex(4096);
		let budget = Some(Duration::from_secs(2));
		let (dialed, accepted) = tokio::join!(
			Session::dial_over(source, &self.locator, left, budget),
			Session::accept_over(&self.host, "tcp", "127.0.0.1:9010", "127.0.0.1:9010", right, budget)
		);
		(dialed.unwrap(), accepted.unwrap())
	}
	pub async fn population(&self, session: &Session, index: usize) -> Vec<Target> {
		population(session, &self.uris[index]).await
	}
	pub async fn close(self) {
		self.host.close(PendingWork::Cancel).await.unwrap();
	}
}

pub async fn population(session: &Session, uris: &[String]) -> Vec<Target> {
	let mut targets = Vec::with_capacity(uris.len());
	let mut seen = HashSet::with_capacity(uris.len());
	for (uri, reference) in uris.iter().zip(references(session, uris).await) {
		assert!(seen.insert(reference.clone()), "foreign population aliases a target");
		targets.push(Target {
			reference,
			uri: uri.clone(),
		});
	}
	targets
}
pub async fn references(session: &Session, uris: &[String]) -> Vec<Ref> {
	// Independent expected-identity lookups are bounded separately from
	// Loam's preparation. They run only after a cold read has settled.
	stream::iter(uris.iter().map(|uri| async { session.enliven(uri).await.unwrap() }))
		.buffered(32)
		.collect()
		.await
}
