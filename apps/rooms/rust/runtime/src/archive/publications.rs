//! Durable lookup names and revocable descendants follow committed share specs.
//! The worker owns every publication effect; callbacks only admit queued work.
use super::*;
use glowcap::{CaptpVersion, Host, Locator};
use rooms_application::archive::{
	shares::{protocol, Share},
	Access,
};
struct Published {
	spec: Share,
	name: String,
	active: Rc<Cell<bool>>,
}
pub(super) struct Publications {
	host: Host,
	root: [u8; Host::DURABLE_ENTROPY_BYTES],
	locator: Locator,
	root_name: Option<String>,
	rows: Vec<Published>,
	ready: Rc<Cell<bool>>,
}
impl Publications {
	pub(super) fn new(host: Host, root: [u8; Host::DURABLE_ENTROPY_BYTES], locator: Locator) -> Self {
		Self {
			host,
			root,
			locator,
			root_name: None,
			rows: Vec::new(),
			ready: Rc::new(Cell::new(false)),
		}
	}
	pub(super) fn suspend(&self) {
		self.ready.set(false);
	}
	fn link(&self, name: &str) -> Result<String, String> {
		glowcap::format_sturdyref(&self.locator, name.as_bytes(), CaptpVersion::V1_0).map_err(|e| e.to_string())
	}
	pub(super) fn root_link(&self) -> Result<String, String> {
		self.link(self.root_name.as_deref().ok_or("archive root is not published")?)
	}
	pub(super) fn share_link(&self, id: &str) -> Result<String, String> {
		let row = self
			.rows
			.iter()
			.find(|r| r.spec.id() == id && r.active.get())
			.ok_or("archive share is not published")?;
		self.link(&row.name)
	}
	pub(super) fn listing(&self, specs: &[Share]) -> Result<Argument, String> {
		let mut rows = Vec::with_capacity(specs.len());
		for spec in specs {
			rows.push(wire::share_row(spec, &self.share_link(spec.id())?).map_err(|e| e.to_string())?);
		}
		Ok(Argument::List(rows))
	}
	/// A failed effect retains its exact name for retry. Readiness prevents a
	/// partial restored set from answering, while issuer calls can retry it.
	pub(super) fn reconcile<P: Platform>(
		&mut self,
		specs: Vec<Share>,
		receiver: &Receiver<P>,
	) -> Result<Vec<Share>, String> {
		self.suspend();
		if specs.len() > rooms_application::archive::shares::MAX_ACTIVE {
			return Err("archive backend returned too many shares".into());
		}
		let mut ids = std::collections::BTreeSet::new();
		for spec in &specs {
			Share::new(spec.id().into(), spec.label().clone(), spec.filter().clone()).map_err(|e| e.to_string())?;
			if spec.revoked() || !ids.insert(spec.id()) {
				return Err("archive backend returned invalid active shares".into());
			}
			if self.rows.iter().any(|r| r.spec.id() == spec.id() && r.spec != *spec) {
				return Err("archive backend changed immutable share identity".into());
			}
		}
		for row in &self.rows {
			if !ids.contains(row.spec.id()) {
				row.active.set(false);
			}
		}
		let mut at = 0;
		while at < self.rows.len() {
			if !self.rows[at].active.get() {
				self.host
					.remove_durable(&self.rows[at].name)
					.map_err(|e| format!("archive share is revoked; publication cleanup failed: {e}"))?;
				self.rows.remove(at);
			} else {
				at += 1;
			}
		}
		for spec in &specs {
			if self.rows.iter().any(|r| r.spec.id() == spec.id()) {
				continue;
			}
			let active = Rc::new(Cell::new(true));
			let authority = Authority::Shared {
				active: active.clone(),
				ready: self.ready.clone(),
			};
			let facet = Facet::new(spec.filter().clone(), Access::Read).map_err(|e| e.to_string())?;
			let name = self.publish(receiver, spec.entropy(&self.root), facet, authority)?;
			self.rows.push(Published {
				spec: spec.clone(),
				name,
				active,
			});
		}
		if self.root_name.is_none() {
			self.root_name = Some(self.publish(
				receiver,
				self.root,
				Facet::new(Filter::default(), Access::ReadWrite).expect("whole archive"),
				Authority::Issuer,
			)?);
		}
		self.ready.set(true);
		Ok(specs)
	}
	fn publish<P: Platform>(
		&self,
		receiver: &Receiver<P>,
		entropy: [u8; Host::DURABLE_ENTROPY_BYTES],
		facet: Facet,
		authority: Authority,
	) -> Result<String, String> {
		let state = receiver.0.upgrade().ok_or("archive owner has ended")?;
		state.live()?;
		let permit = state.facet_permit(&facet)?;
		let receiver = receiver.clone();
		self.host
			.publish_durable_with_entropy(entropy, || {
				Box::new(move |verb, args| {
					let _held = &permit;
					receiver.receive(&facet, &authority, verb, args)
				})
			})
			.map_err(|e| format!("archive share state is committed; publication failed: {e}"))
	}
	pub(super) fn close(&mut self) -> Result<(), String> {
		self.suspend();
		for row in &self.rows {
			row.active.set(false);
		}
		let mut errors = Vec::new();
		self.rows.retain(|row| match self.host.remove_durable(&row.name) {
			Ok(_) => false,
			Err(e) => {
				errors.push(e.to_string());
				true
			}
		});
		if let Some(name) = &self.root_name {
			match self.host.remove_durable(name) {
				Ok(_) => {
					self.root_name.take();
				}
				Err(e) => errors.push(e.to_string()),
			}
		}
		if errors.is_empty() {
			Ok(())
		} else {
			Err(errors.join("; "))
		}
	}
}
impl Drop for Publications {
	fn drop(&mut self) {
		self.suspend();
	}
}
impl<B: Backend, P: Platform> Worker<B, P> {
	/// Configure once before running the worker. Publication failure preserves
	/// owned names for retry_publications; no partially restored share answers.
	pub async fn publish(
		&mut self,
		host: Host,
		root: [u8; Host::DURABLE_ENTROPY_BYTES],
		locator: Locator,
	) -> Result<String, String> {
		if self.publications.is_some() {
			return Err("archive publications already configured".into());
		}
		if !self.backend.durable_shares() {
			return Err("archive backend does not retain durable shares".into());
		}
		self.publications = Some(Publications::new(host, root, locator));
		self.retry_publications().await
	}
	pub async fn retry_publications(&mut self) -> Result<String, String> {
		self.reconcile_publications().await?;
		self.publications.as_ref().expect("configured publications").root_link()
	}
	async fn reconcile_publications(&mut self) -> Result<Vec<Share>, String> {
		let publications = self
			.publications
			.as_mut()
			.ok_or("archive has no durable share issuer")?;
		let specs = match self.backend.active_shares().await {
			Ok(specs) => specs,
			Err(error) => {
				publications.suspend();
				return Err(error);
			}
		};
		publications.reconcile(specs, &Receiver(Rc::downgrade(&self.state)))
	}
	pub(super) async fn share_request(&mut self, request: protocol::Request) -> Result<Argument, String> {
		use rooms_application::archive::shares::{Change, Command};
		if self.publications.is_none() {
			return Err("archive has no durable share issuer".into());
		}
		let (id, changed) = match request {
			protocol::Request::Issue(spec) => {
				let id = spec.id().to_owned();
				let change = self.backend.change_share(Command::Issue(spec)).await;
				(Some(id), change)
			}
			protocol::Request::Revoke(id) => (None, self.backend.change_share(Command::Revoke(id)).await),
			protocol::Request::List => {
				let specs = self.reconcile_publications().await?;
				return self
					.publications
					.as_ref()
					.expect("configured publications")
					.listing(&specs);
			}
		};
		let changed = match changed {
			Ok(v) => v,
			Err(e) => {
				self.publications.as_ref().expect("configured publications").suspend();
				// A policy refusal leaves storage usable. Reconcile that committed
				// state before the next queued call; uncertain storage stays closed.
				return match self.reconcile_publications().await {
					Ok(_) => Err(e),
					Err(recovery) => Err(format!("{e}; share publications unavailable: {recovery}")),
				};
			}
		};
		self.reconcile_publications().await?;
		if let Some(id) = id {
			self.publications
				.as_ref()
				.expect("configured publications")
				.share_link(&id)
				.map(Argument::String)
		} else {
			Ok(Argument::Boolean(changed == Change::Revoked))
		}
	}
}
