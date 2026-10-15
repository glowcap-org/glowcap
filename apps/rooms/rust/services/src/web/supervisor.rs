//! One directory identity across child incarnations. An attached TCP server
//! remains externally owned. Loss of that server triggers verified takeover.
use super::{
	notice::{Notice, Report},
	process::{Process, Temporary},
};
use crate::server::readiness::Announcement;
use rooms_platform::serving::endpoint::Endpoint;
struct Config {
	server: PathBuf,
	server_args: Vec<String>,
	room: crate::server::Config,
}
use crate::{cleanup, server::Transport};
use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_glowcap::client::{Client, directory::Directory};
use rooms_platform::HostPlatform;
use std::{path::PathBuf, time::Duration};
use tokio::{process::Command, sync::watch, time::Instant};

pub(super) struct Supervisor {
	config: Config,
	state: PathBuf,
	temporary: Temporary,
	forward: Option<Temporary>,
	child: Option<Process>,
	started: Instant,
	report: Report,
}
impl Supervisor {
	pub async fn open(
		server: PathBuf,
		server_args: Vec<String>,
		room: crate::server::Config,
		stop: watch::Receiver<bool>,
		report: Report,
	) -> Result<Option<(Self, Announcement)>, String> {
		if *stop.borrow() {
			return Ok(None);
		}
		let config = Config {
			server,
			server_args,
			room,
		};
		let (state, temporary) = Temporary::state(config.room.state.clone()).await?;
		let mut owner = Self {
			config,
			state,
			temporary,
			forward: None,
			child: None,
			started: Instant::now(),
			report,
		};
		let started = owner.attempt(stop).await;
		match started {
			Ok(Some(locator)) => Ok(Some((owner, locator))),
			Ok(None) => {
				owner.close().await?;
				Ok(None)
			}
			Err(error) => Err(cleanup::failed(error, owner.close().await)),
		}
	}

	async fn attempt(&mut self, mut stop: watch::Receiver<bool>) -> Result<Option<Announcement>, String> {
		// Acquisition finishes into this owner before announcement may be
		// cancelled. No dropped observer can abandon a socket directory or child.
		let attached = self.attached(stop.clone()).await?;
		if *stop.borrow() {
			return Ok(None);
		}
		if attached.is_some() {
			return Ok(attached);
		}
		let deadline = self.spawn().await?;
		let child = self.child.as_mut().ok_or("server child was not started")?;
		tokio::select! {
			biased;
			_ = super::stopped(&mut stop) => Ok(None),
			ready = child.announcement(deadline) => ready.map(Some),
		}
	}

	fn attach_target(&self) -> Option<(String, u16)> {
		match &self.config.room.transport {
			Transport::Tcp { bind, port, .. } if *port != 0 => Some((bind.clone(), *port)),
			Transport::Onion(config) if config.port != 0 => Some(("127.0.0.1".into(), config.port)),
			_ => None,
		}
	}
	async fn attached(&self, mut stop: watch::Receiver<bool>) -> Result<Option<Announcement>, String> {
		let Some((bind, port)) = self.attach_target() else {
			return Ok(None);
		};
		// Match the host listener's first resolved address, then retain that
		// concrete route independently of the public address it advertises.
		let resolving = async {
			tokio::net::lookup_host((bind.trim_matches(['[', ']']), port))
				.await
				.map_err(|e| e.to_string())?
				.next()
				.ok_or_else(|| "directory bind address resolved to nothing".to_owned())
		};
		let address = tokio::select! {
			biased;
			_ = super::stopped(&mut stop) => return Ok(None),
			result = tokio::time::timeout(Duration::from_secs(5), resolving) =>
				result.map_err(|_| "resolving the directory bind address timed out")??,
		};
		match tokio::net::TcpListener::bind(address).await {
			Ok(listener) => {
				drop(listener);
				return Ok(None);
			}
			Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {}
			Err(error) => return Err(format!("checking the directory listener failed: {error}")),
		}
		if matches!(self.config.room.transport, Transport::Onion(_)) {
			return Err(format!(
				"onion forward port {port} is already held; choose a free room port"
			));
		}
		let endpoint = Endpoint::tcp(&address.ip().to_string(), address.port());
		let locator = match probe(&endpoint, stop.clone()).await {
			Ok(locator) => locator,
			Err(_) if *stop.borrow() => return Ok(None),
			Err(error) => {
				return Err(format!(
					"port {port} is held by a service that does not answer as a Rooms directory: {error}"
				));
			}
		};
		(self.report)(Notice::AttachedDirectory(locator.clone()));
		let trace = if self.config.room.asked.trace {
			if self.config.room.trace_port == 0 {
				return Err("an attached directory needs an explicit timeline port".into());
			}
			Some(self.config.room.trace_port)
		} else {
			None
		};
		let mut announcement = Announcement::new(locator, trace, Some(endpoint));
		announcement.trace_locator = trace
			.map(|port| {
				crate::server::trace_locator(
					port,
					self.config.room.trace_publish.clone(),
					self.config.room.trace_connect.clone(),
				)
				.and_then(|locator| glowcap::format_locator_uri(&locator).map_err(crate::server::Error::from))
				.map_err(|e| e.to_string())
			})
			.transpose()?;
		Ok(Some(announcement))
	}
	async fn spawn(&mut self) -> Result<Duration, String> {
		if let Some(previous) = self.forward.take() {
			previous.close().await?;
		}
		let mut command = Command::new(&self.config.server);
		command
			.args(&self.config.server_args)
			.env("GLOWCAP_ROOMS_STATE", &self.state)
			.env("GLOWCAP_ROOMS_SUPERVISED", "1")
			.env("GLOWCAP_ROOMS_READY_FORMAT", "json");
		if matches!(&self.config.room.transport, Transport::Onion(config) if config.port == 0 && config.forward.is_none())
		{
			let (directory, owner) = Temporary::create(Temporary::plan()?).await?;
			self.forward = Some(owner);
			command.arg(format!(
				"--onion-forward={}",
				directory.join("directory.sock").display()
			));
		}
		self.started = Instant::now();
		self.child = Some(Process::spawn(&mut command, "Rooms server", self.report.clone())?);
		let deadline = if matches!(self.config.room.transport, Transport::Onion(_)) {
			60
		} else {
			10
		};
		Ok(Duration::from_secs(deadline))
	}
	pub async fn run(
		mut self,
		location: watch::Sender<Option<Announcement>>,
		mut stop: watch::Receiver<bool>,
	) -> Result<(), String> {
		let mut backoff = Duration::ZERO;
		let result = loop {
			if *stop.borrow() {
				break Ok(());
			}
			let current = location.borrow().clone();
			if let Some(child) = &mut self.child {
				let status = tokio::select! {
					_ = super::stopped(&mut stop) => break Ok(()),
					result = child.child.wait() => result,
				};
				location.send_replace(None);
				match status {
					Ok(status) => {
						self.child = None;
						(self.report)(Notice::DirectoryExited(status.to_string()));
					}
					Err(error) => break Err(format!("observing the Rooms server failed: {error}")),
				}
				backoff = restart_wait(backoff, self.started.elapsed());
			} else if let Some(mut announcement) = current {
				tokio::select! {
					_ = super::stopped(&mut stop) => break Ok(()),
					_ = tokio::time::sleep(Duration::from_secs(2)) => {},
				}
				if let Some(endpoint) = &announcement.local_endpoint
					&& let Ok(advertised) = probe(endpoint, stop.clone()).await
				{
					if advertised != announcement.location {
						announcement.location = advertised;
						location.send_replace(Some(announcement));
					}
					continue;
				}
				location.send_replace(None);
				(self.report)(Notice::AttachedDirectoryEnded);
			}
			if !backoff.is_zero() {
				tokio::select! { _ = super::stopped(&mut stop) => break Ok(()), _ = tokio::time::sleep(backoff) => {} }
			}
			let opened = self.attempt(stop.clone()).await;
			match opened {
				Ok(None) => break Ok(()),
				Ok(Some(locator)) => {
					location.send_replace(Some(locator));
				}
				Err(error) => {
					if let Some(child) = &mut self.child
						&& let Err(retirement) = child.close().await
					{
						break Err(cleanup::failed(error, Err(retirement)));
					}
					self.child = None;
					backoff = restart_wait(backoff, Duration::ZERO);
					(self.report)(Notice::DirectoryRestartFailed {
						cause: error,
						delay_ms: backoff.as_millis(),
					});
				}
			}
		};
		location.send_replace(None);
		cleanup::combine(result, self.close().await)
	}
	pub async fn close(mut self) -> Result<(), String> {
		let result = match self.child.take() {
			Some(mut child) => child.close().await,
			None => Ok(()),
		};
		// Failed retirement is not evidence that deleting the child's files is
		// safe. Keep temporary state available for diagnosis in that case.
		if result.is_ok() {
			let forward = match self.forward.take() {
				Some(forward) => forward.close().await,
				None => Ok(()),
			};
			cleanup::combine(forward, self.temporary.close().await)
		} else {
			result
		}
	}
}

fn restart_wait(previous: Duration, ran: Duration) -> Duration {
	if ran >= Duration::from_secs(5) {
		Duration::ZERO
	} else if previous.is_zero() {
		Duration::from_millis(500)
	} else {
		(previous * 2).min(Duration::from_secs(30))
	}
}
async fn probe(endpoint: &Endpoint, mut stop: watch::Receiver<bool>) -> Result<String, String> {
	if *stop.borrow() {
		return Err("directory probe stopped".into());
	}
	let Endpoint::Tcp { host, port } = endpoint else {
		return Err("only TCP directories support external attachment".into());
	};
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.map_err(|e| e.to_string())?;
	let check = async {
		let session = runtime
			.connect(&tcp::locator(host, *port), ConnectOptions::default())
			.await
			.map_err(|e| e.to_string())?;
		let directory = Directory::fetch(Client::new(session, HostPlatform))
			.await
			.map_err(|e| e.to_string())?;
		directory.list(None).await.map_err(|e| e.to_string())?;
		let advertised = directory.advertised_location().await.map_err(|e| e.to_string())?;
		let locator = rooms_glowcap::routes::locator(&advertised).ok_or("directory advertised an invalid location")?;
		glowcap::format_locator_uri(&locator).map_err(|e| e.to_string())
	};
	let served = tokio::select! {
		biased;
		_ = super::stopped(&mut stop) => Err("directory probe stopped".into()),
		result = tokio::time::timeout(Duration::from_secs(5), check) =>
			result.map_err(|_| "directory probe timed out".to_owned()).and_then(|r| r),
	};
	let retired = runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string());
	match served {
		Ok(locator) => retired.map(|()| locator),
		Err(error) => Err(cleanup::failed(error, retired)),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn restart_pressure_is_bounded_and_a_stable_incarnation_resets_it() {
		let mut wait = Duration::ZERO;
		for _ in 0..16 {
			let next = restart_wait(wait, Duration::ZERO);
			assert!(next >= wait && next <= Duration::from_secs(30));
			wait = next;
		}
		assert_eq!(wait, Duration::from_secs(30));
		assert_eq!(restart_wait(wait, Duration::from_secs(5)), Duration::ZERO);
		assert_eq!(restart_wait(Duration::ZERO, Duration::ZERO), Duration::from_millis(500));
	}
}
