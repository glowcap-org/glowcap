//! HTTP has no authenticated Rooms identity. Apply a deployment envelope and,
//! only when configured, a budget for the actual socket address. Forwarded
//! headers never select a budget or confer trust.
use super::http::{Reply, response};
use rooms_application::admission::{Charge, Class, Policy, Profile, Rate, Registry, Settings};
use std::{cell::RefCell, net::IpAddr, rc::Rc, time::Instant};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
	Deployment,
	Address(IpAddr),
}
struct Rates {
	source: Profile,
	deployment: Profile,
}
impl Policy<Key> for Rates {
	fn rate(&self, key: Key, class: Class) -> Rate {
		match key {
			Key::Deployment => self.deployment.rate(class),
			Key::Address(_) => self.source.rate(class),
		}
	}
}
#[derive(Clone, Copy)]
pub(super) struct Config {
	pub settings: Settings,
	pub per_address: bool,
}
impl Config {
	pub fn read(
		options: &std::collections::BTreeMap<String, String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Self, String> {
		let value = |key: &str| {
			options
				.get(&format!("http-{key}"))
				.cloned()
				.or_else(|| env(&format!("GLOWCAP_ROOMS_HTTP_{}", key.replace('-', "_").to_uppercase())))
				.map(|s| s.trim().to_owned())
				.filter(|s| !s.is_empty())
		};
		let settings = Settings::parse_from(
			|key| {
				value(key).map(|v| {
					(
						v,
						if options.contains_key(&format!("http-{key}")) {
							rooms_application::admission::Source::Argument
						} else {
							rooms_application::admission::Source::Environment
						},
					)
				})
			},
			rooms_application::admission::HTTP_ROWS,
			rooms_application::admission::POOLED_AGGREGATE_SCALE,
		)?;
		let per_address = match value("admission-per-address").as_deref() {
			None | Some("" | "0" | "false" | "no") => false,
			Some("1" | "true" | "yes") => true,
			Some(_) => return Err("GLOWCAP_ROOMS_HTTP_ADMISSION_PER_ADDRESS must be a boolean".into()),
		};
		Ok(Self { settings, per_address })
	}
}
pub(super) struct Admission {
	registry: RefCell<Registry<Key, Rates>>,
	start: Instant,
	per_address: bool,
	settings: Settings,
}
impl Admission {
	pub fn new(config: Config) -> Rc<Self> {
		Rc::new(Self {
			registry: RefCell::new(Registry::new(
				Rates {
					source: config.settings.profile(),
					deployment: config.settings.aggregate(),
				},
				config.settings.rows(),
			)),
			start: Instant::now(),
			per_address: config.per_address,
			settings: config.settings,
		})
	}
	pub fn settings(&self) -> Settings {
		self.settings
	}
	pub fn start(&self, class: Class, address: Option<IpAddr>) -> Result<(), rooms_application::admission::Refusal> {
		let now = self.start.elapsed().as_millis().try_into().unwrap_or(u64::MAX);
		let mut charges = [Charge {
			key: Key::Deployment,
			class,
			amount: 1,
		}; 2];
		let count = if self.per_address {
			if let Some(address) = address {
				charges[1].key = Key::Address(address);
				2
			} else {
				1
			}
		} else {
			1
		};
		self.registry.borrow_mut().admit(&charges[..count], now)
	}
}

pub(super) fn reply(refusal: rooms_application::admission::Refusal) -> Reply {
	use rooms_application::admission::Refusal;
	let (status, retry) = match refusal {
		Refusal::Throttled { retry_ms, .. } => (hyper::StatusCode::TOO_MANY_REQUESTS, Some(retry_ms.div_ceil(1000))),
		Refusal::Capacity => (hyper::StatusCode::SERVICE_UNAVAILABLE, None),
		Refusal::TooLarge { .. } => (hyper::StatusCode::PAYLOAD_TOO_LARGE, None),
	};
	let mut result = response(
		status,
		"text/plain; charset=utf-8",
		refusal.reason_at(rooms_application::admission::Owner::Http).into(),
	);
	if let Some(seconds) = retry {
		result.headers_mut().insert("retry-after", seconds.into());
	}
	result
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn optional_socket_policy_is_additional_to_deployment_pressure() {
		let settings =
			Settings::parse(|key| (key == "admission-rates").then(|| "http-start=1/1".into()), 32, 8).unwrap();
		let policy = Admission::new(Config {
			settings,
			per_address: true,
		});
		let first = "127.0.0.1".parse().unwrap();
		let other = "127.0.0.2".parse().unwrap();
		policy.start(Class::HttpStart, Some(first)).unwrap();
		assert!(policy.start(Class::HttpStart, Some(first)).is_err());
		policy.start(Class::HttpStart, Some(other)).unwrap();
		let aggregate = Admission::new(Config {
			settings,
			per_address: false,
		});
		for _ in 0..8 {
			aggregate.start(Class::HttpStart, Some(first)).unwrap();
		}
		assert!(aggregate.start(Class::HttpStart, Some(other)).is_err());
	}
}
