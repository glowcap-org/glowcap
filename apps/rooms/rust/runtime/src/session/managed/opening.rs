//! Shared session composition over either physical Loam backend. Trusted
//! startup metadata names the private root and independent live marker only.
use super::Session;
use glowcap::{
	Argument, CaptpVersion, Host, Locator, Ref, Result,
	loam::{self, Attachment, ControlPowers, LiveMarker, Resource, Scope, Store},
};
use rooms_application::content::session;
use rooms_glowcap::client::{Deadline, Tasks, access::Control, workspace::Workspace};
use std::{future::Future, num::NonZeroUsize};

/// Private embedding metadata, separate from exported workspace intent. These
/// names select the actual committed root. They contain no grant inventory,
/// bearer links, endpoint reconstruction recipe or policy mirror.
#[derive(Clone, Copy)]
pub struct StartupAnchor {
	pub resource: Resource,
	pub marker: Option<LiveMarker>,
}
impl StartupAnchor {
	pub const BYTES: usize = 133;
	pub fn encode(self) -> [u8; Self::BYTES] {
		let mut bytes = [0; Self::BYTES];
		bytes[..99].copy_from_slice(&self.resource.encode());
		if let Some(marker) = self.marker {
			bytes[99] = 1;
			bytes[100..].copy_from_slice(&marker.encode());
		}
		bytes
	}
	pub fn decode(bytes: [u8; Self::BYTES]) -> Result<Self> {
		let marker = match bytes[99] {
			0 if bytes[100..].iter().all(|byte| *byte == 0) => None,
			1 => Some(LiveMarker::decode(
				bytes[100..]
					.try_into()
					.map_err(|_| loam::refusal("invalid private session startup anchor"))?,
			)),
			_ => return Err(loam::refusal("invalid private session startup anchor")),
		};
		Ok(Self {
			resource: Resource::decode(
				bytes[..99]
					.try_into()
					.map_err(|_| loam::refusal("invalid private session startup anchor"))?,
			),
			marker,
		})
	}
}

/// One owner for the callback, workers, attachment and Store. Transport and
/// Host lifetime stay with the embedding. Public use and control are separate
/// children. The private root never leaves this owner.
pub struct Opened<P: Tasks + Deadline + Clone + 'static> {
	store: Store,
	attachment: Attachment,
	session: Session<P>,
	host: Host,
	platform: P,
	access: Option<(Ref, Ref)>,
	anchor: StartupAnchor,
	activity: Option<super::WorkspaceActivity<P>>,
}
impl<P: Tasks + Deadline + Clone + 'static> Opened<P> {
	/// The embedding commits the returned marker in its trusted bootstrap owner
	/// before this method exposes public custody. Failure closes the complete
	/// composition. No grant set is restored and no independent worker is added.
	pub async fn open<F: Future<Output = Result<()>>>(
		store: Store,
		host: Host,
		platform: P,
		anchor: StartupAnchor,
		reply_bytes: NonZeroUsize,
		live_capacity: u32,
		persist: impl FnOnce(StartupAnchor) -> F,
	) -> Result<Self> {
		let session = Session::new(host.clone(), platform.clone(), reply_bytes);
		let attachment = store.attach(&host, vec![session.registration()])?;
		let mut owner = Self {
			store,
			attachment,
			session,
			host,
			platform,
			access: None,
			anchor,
			activity: None,
		};
		if let Err(error) = owner.start(live_capacity, persist).await {
			return Err(error.with_cleanup(owner.close().await));
		}
		Ok(owner)
	}
	async fn start<F: Future<Output = Result<()>>>(
		&mut self,
		live_capacity: u32,
		persist: impl FnOnce(StartupAnchor) -> F,
	) -> Result<()> {
		let (root, private_control) = self.attachment.restore(self.anchor.resource).await?;
		self.session.bind(root.clone(), private_control)?;
		self.attachment.start_live(self.anchor.marker, live_capacity)?;
		// This ordinary private call drives the attachment's existing storage
		// lane. It adds neither a polling timer nor a second startup scheduler.
		self.session.initialize().await?;
		// start_live establishes a fresh Host lifetime. Directory registrations
		// and direct routes still select callbacks owned by its predecessor.
		// Retire them atomically before a viewer can mistake saved fields for
		// readiness while supervisors install and register the new callbacks.
		self.session
			.state
			.writer
			.mutate("retire-host-registrations", &[])
			.await?;
		self.anchor.marker = Some(
			self.attachment
				.live_marker()?
				.ok_or_else(|| loam::refusal("session lifetime is still pending; publication is unavailable"))?,
		);
		self.session.activity().bind_incarnation(
			self.attachment
				.live_incarnation()?
				.ok_or_else(|| loam::refusal("session incarnation is pending"))?,
		)?;
		persist(self.anchor).await?;
		let policy = rooms_glowcap::policy::descriptor()?;
		let wide = policy.value_for_kind(
			session::KIND,
			&session::SUPPORTED
				.iter()
				.map(|permission| permission.key())
				.collect::<Vec<_>>(),
			&[],
		)?;
		let powers = ControlPowers {
			inspect: true,
			issue_ceiling: Some(wide),
			delegate_control: true,
			pause: true,
			resume: true,
			revoke: true,
			policy_ceiling: Some(wide),
		};
		// The private root derives exactly one public branch. Sequence one and
		// immutable terms recover the same receipt on every physical reopen;
		// clients issue descendants through the returned control, never this root.
		let reply = self
			.host
			.send(
				&root,
				"derive-managed",
				&wide.managed_derive_arguments(1, Scope::Object, 3, powers),
			)
			.await?;
		let Some([Argument::Reference(access), Argument::Reference(control)]) = reply.as_list() else {
			return Err(loam::refusal("session startup returned no public branch"));
		};
		self.access = Some((access.clone(), control.clone()));
		Ok(())
	}
	pub fn session(&self) -> &Session<P> {
		&self.session
	}
	pub fn workspace(&self) -> Result<Workspace<P>> {
		Ok(Workspace::local(
			self.host.clone(),
			self.platform.clone(),
			self.access()?.clone(),
		))
	}
	pub fn management(&self) -> Result<Control<P>> {
		Ok(Control::local(
			self.host.clone(),
			self.platform.clone(),
			self.control()?.clone(),
		))
	}
	pub fn access(&self) -> Result<&Ref> {
		self.access
			.as_ref()
			.map(|held| &held.0)
			.ok_or_else(|| loam::refusal("session is closed"))
	}
	pub fn control(&self) -> Result<&Ref> {
		self.access
			.as_ref()
			.map(|held| &held.1)
			.ok_or_else(|| loam::refusal("session is closed"))
	}
	pub fn anchor(&self) -> StartupAnchor {
		self.anchor
	}
	/// Retain the workspace observer alongside its attachment. The embedding
	/// supplies its reachable member route and owns synchronous presentation.
	/// Every membership still uses its saved original initiating source.
	pub fn supervise_workspace<E: crate::entropy::Entropy + 'static>(
		&mut self,
		locator: &str,
		entropy: E,
		kinds: super::MembershipKinds,
		receive: impl FnMut(&super::MembershipTarget) -> super::MembershipReceiver + 'static,
		report: impl FnMut(Result<&super::MembershipReport>) + 'static,
	) -> Result<&super::WorkspaceActivity<P>> {
		if self.activity.is_some() {
			return Err(loam::refusal("Workspace realization is already owned"));
		}
		let activity = self
			.session
			.supervise_workspace(self.access()?, locator, entropy, kinds, receive, report)?;
		Ok(self.activity.insert(activity))
	}
	pub fn activity(&self) -> Option<&super::WorkspaceActivity<P>> {
		self.activity.as_ref()
	}
	/// Failure retains the exact activity and cancellation custody for retry.
	pub async fn stop_activity(&mut self) -> Result<()> {
		if let Some(activity) = self.activity.as_mut() {
			activity.close().await?;
			self.activity.take();
		}
		Ok(())
	}
	/// Shared publication state is persisted on demand. Locator formatting
	/// neither restores a grant inventory nor derives authority from a name.
	pub async fn publish(&self, locator: &Locator) -> Result<String> {
		self.publish_reference(locator, self.access()?).await
	}
	pub async fn publish_management(&self, locator: &Locator) -> Result<String> {
		self.publish_reference(locator, self.control()?).await
	}
	async fn publish_reference(&self, locator: &Locator, reference: &Ref) -> Result<String> {
		let name = self.host.send(reference, "durable-name", &[]).await?;
		let name = name
			.as_str()
			.ok_or_else(|| loam::refusal("session returned no publication name"))?;
		glowcap::format_sturdyref(locator, name.as_bytes(), CaptpVersion::V1_0)
	}
	/// A failed worker or storage close remains owned for exact recovery and a
	/// later close attempt. Closing follows effect, attachment, Store order.
	pub async fn close(&mut self) -> Result<()> {
		self.stop_activity()
			.await
			.map_err(|error| error.with_context("closing workspace activity"))?;
		self.session
			.close()
			.await
			.map_err(|error| error.with_context("closing session workers"))?;
		self.access.take();
		self.attachment
			.close()
			.await
			.map_err(|error| error.with_context("closing session attachment"))?;
		#[cfg(not(target_arch = "wasm32"))]
		self.store
			.close()
			.map_err(|error| error.with_context("closing session storage"))?;
		#[cfg(target_arch = "wasm32")]
		self.store
			.close()
			.await
			.map_err(|error| error.with_context("closing session storage"))?;
		Ok(())
	}
}
