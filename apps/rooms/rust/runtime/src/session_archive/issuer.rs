//! Session-local durable share names published from the storage ledger.
use super::{share::Work, State};
use crate::platform::Platform;
use glowcap::{CaptpVersion, Host, Locator};
use rooms_application::archive::{shares::Share, Access, Facet};
use rooms_glowcap::client::archive::ShareView;
use std::{cell::Cell, rc::Rc};

struct Published {
	spec: Share,
	name: String,
	active: Rc<Cell<bool>>,
}

pub(super) struct Issuer {
	host: Host,
	locator: Locator,
	root: [u8; Host::DURABLE_ENTROPY_BYTES],
	rows: Vec<Published>,
}
impl Issuer {
	pub(super) fn new(host: Host, locator: Locator, root: [u8; Host::DURABLE_ENTROPY_BYTES]) -> Self {
		Self {
			host,
			locator,
			root,
			rows: Vec::new(),
		}
	}
	pub(super) fn issue<P: Platform>(&mut self, spec: &Share, state: &Rc<State<P>>) -> Result<String, String> {
		self.ensure(spec, state)?;
		self.link(spec.id())
	}
	pub(super) fn revoke(&mut self, id: &str) -> Result<bool, String> {
		let Some(index) = self.rows.iter().position(|row| row.spec.id() == id) else {
			return Ok(false);
		};
		self.rows[index].active.set(false);
		self.host
			.remove_durable(&self.rows[index].name)
			.map_err(|e| format!("archive share is revoked; publication cleanup failed: {e}"))?;
		self.rows.remove(index);
		Ok(true)
	}
	pub(super) fn listing(&self, specs: &[Share]) -> Result<Vec<ShareView>, String> {
		let mut rows = Vec::with_capacity(specs.len());
		for spec in specs {
			rows.push(ShareView {
				share: spec.clone(),
				sturdyref: self.link(spec.id())?,
			});
		}
		Ok(rows)
	}
	pub(super) fn reconcile<P: Platform>(&mut self, specs: Vec<Share>, state: &Rc<State<P>>) -> Result<(), String> {
		if specs.len() > rooms_application::archive::shares::MAX_ACTIVE {
			return Err("archive backend returned too many active shares".into());
		}
		let mut ids = std::collections::BTreeSet::new();
		for spec in &specs {
			Share::new(spec.id().into(), spec.label().clone(), spec.filter().clone()).map_err(|e| e.to_string())?;
			if spec.revoked() || !ids.insert(spec.id()) {
				return Err("archive backend returned invalid active shares".into());
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
		for spec in specs {
			self.ensure(&spec, state)?;
		}
		Ok(())
	}
	fn ensure<P: Platform>(&mut self, spec: &Share, state: &Rc<State<P>>) -> Result<(), String> {
		if self.rows.iter().any(|row| row.spec.id() == spec.id()) {
			return Ok(());
		}
		let active = Rc::new(Cell::new(true));
		let facet = Facet::new(spec.filter().clone(), Access::Read).map_err(|e| e.to_string())?;
		let permit = state
			.hosting
			.retain(facet.scope().retained_bytes() + core::mem::size_of::<Work<P>>())?;
		let archive = Work::local(state, active.clone());
		let host = self.host.clone();
		let name = self
			.host
			.publish_durable_with_entropy(spec.entropy(&self.root), || {
				Box::new(move |verb, args| {
					let _permit = &permit;
					archive.dispatch(&host, &facet, verb, args)
				})
			})
			.map_err(|e| format!("archive share state is committed; publication failed: {e}"))?;
		self.rows.push(Published {
			spec: spec.clone(),
			name,
			active,
		});
		Ok(())
	}
	pub(super) fn close(&mut self) -> u64 {
		for row in &self.rows {
			row.active.set(false);
		}
		self.rows.retain(|row| self.host.remove_durable(&row.name).is_err());
		self.rows.len() as u64
	}

	fn link(&self, id: &str) -> Result<String, String> {
		let row = self
			.rows
			.iter()
			.find(|row| row.spec.id() == id && row.active.get())
			.ok_or("archive share is not published")?;
		glowcap::format_sturdyref(&self.locator, row.name.as_bytes(), CaptpVersion::V1_0).map_err(|e| e.to_string())
	}
}

impl Drop for Issuer {
	fn drop(&mut self) {
		for row in &self.rows {
			row.active.set(false);
		}
	}
}
