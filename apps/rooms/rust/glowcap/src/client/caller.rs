//! Local and remote use share the same typed requests and exact custody.
use super::{Argument, Client, Deadline, Error, Future, Ref};
use glowcap::Host;

#[derive(Clone)]
pub(crate) enum Caller<D> {
	Remote(Client<D>),
	Local { host: Host, platform: D },
}
impl<D: Deadline> Caller<D> {
	pub fn host(&self) -> Host {
		match self {
			Self::Remote(client) => client.session().host(),
			Self::Local { host, .. } => host.clone(),
		}
	}
	pub fn platform(&self) -> &D {
		match self {
			Self::Remote(client) => client.platform(),
			Self::Local { platform, .. } => platform,
		}
	}
	pub fn session(&self) -> Option<&std::rc::Rc<super::Session>> {
		match self {
			Self::Remote(client) => Some(&client.session),
			Self::Local { .. } => None,
		}
	}
	pub fn tell(&self, source: &Ref, verb: &str, args: &[Argument]) -> Result<(), Error> {
		match self {
			Self::Remote(client) => client.session().tell(source, verb, args),
			Self::Local { host, .. } => host.tell(source, verb, args),
		}
		.map_err(Error::from)
	}
	/// Files may come from a third peer or a local managed facade. The Host
	/// routes the actual capability. Retaining the remote client still keeps
	/// its delivering connection alive without guessing a blob's exporter.
	pub fn call_reference(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
		milliseconds: u64,
	) -> impl Future<Output = Result<Argument, Error>> + use<'_, D> {
		let (host, platform) = match self {
			Self::Remote(client) => (client.session().host(), client.platform()),
			Self::Local { host, platform } => (host.clone(), platform),
		};
		let pending = host.send(source, verb, args);
		async move {
			platform
				.within(milliseconds, async move { pending.await })
				.await
				.ok_or(Error::Timeout(what))?
				.map_err(Error::from)
		}
	}
	pub fn call(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
	) -> impl Future<Output = Result<Argument, Error>> + use<'_, D> {
		// Both fronts admit the vow now. Temporary arguments retire before the
		// observation awaits; local requests create no transport or session.
		let pending = self.wait(source, verb, args);
		let platform = match self {
			Self::Remote(client) => client.platform(),
			Self::Local { platform, .. } => platform,
		};
		async move {
			platform
				.within(rooms_application::room::authority::REQUEST_TIMEOUT_MS, pending)
				.await
				.ok_or(Error::Timeout(what))?
		}
	}
	pub fn wait(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
	) -> impl Future<Output = Result<Argument, Error>> + use<D> {
		let pending = match self {
			Self::Remote(client) => Pending::Remote(client.session().send(source, verb, args)),
			Self::Local { host, .. } => Pending::Local(host.send(source, verb, args)),
		};
		async move {
			match pending {
				Pending::Remote(pending) => pending.await,
				Pending::Local(pending) => pending.await,
			}
			.map_err(Error::from)
		}
	}
}
enum Pending {
	Remote(glowcap::RemotePromise),
	Local(glowcap::HostPromise),
}
