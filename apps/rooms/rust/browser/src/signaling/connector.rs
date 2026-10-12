//! Runtime composition for directory-scoped WebRTC. The page's directory
//! owner resolves routes. Each connector attempt captures one held client.
use super::dial;
use crate::ice;
use glowcap::{Connector, DialOrigin};
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};
use std::io;

/// Select from the application's existing directory inventory before starting
/// any awaited effect. For a handoff, the selected client must belong to the
/// introducing session. An explicit dial needs an explicitly selected route.
/// The connector never guesses from peer designators or other active attempts.
/// Keep and close the ICE source with the application that owns the Runtime.
pub fn connector<D, F>(select: F, ice: ice::Source) -> glowcap::Result<Connector>
where
	D: Deadline + Tasks + Clone + 'static,
	F: Fn(&glowcap::Locator, &DialOrigin) -> Result<Route<D>, String> + 'static,
{
	Connector::new(
		&[glowcap::TRANSPORT_WEBRTC],
		move |host, locator, origin, options, timeout| {
			let selected = (|| {
				if options.is_some() {
					return Err("Rooms WebRTC has no per-operation byte options".into());
				}
				let timeout = timeout
					.filter(|budget| !budget.is_zero())
					.ok_or("Rooms WebRTC requires a finite handshake budget")?;
				let directory = select(locator, &origin)?;
				if !directory.host().same_host(&host) || directory.session().is_some_and(|session| !session.is_open()) {
					return Err("Rooms signaling directory is not open on the dialing Host".into());
				}
				if let DialOrigin::Pending {
					introducer: Some(source),
				} = &origin
				{
					if directory.session().is_none_or(|session| !session.same_session(source)) {
						return Err("Rooms signaling directory differs from the introducing session".into());
					}
				}
				Ok((directory, timeout))
			})();
			let ice = ice.clone();
			Box::pin(async move {
				let (directory, timeout) = selected.map_err(|reason: String| {
					glowcap::Error::from(io::Error::new(io::ErrorKind::InvalidInput, reason))
				})?;
				let config = ice
					.configuration()
					.await
					.map_err(|error| io::Error::other(error.to_string()))?;
				dial(&directory, locator, &config, timeout)
					.await
					.map_err(|error| match error {
						super::Error::Binding(error) => error,
						other => io::Error::other(other.to_string()).into(),
					})
			})
		},
	)
}
