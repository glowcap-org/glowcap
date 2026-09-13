//! Read scheduling for the six operations views. Tickets bind replies to the
//! credential and filter that admitted them. Refreshes coalesce without queues.
use crate::{server::operations::BOOT_CAPABILITIES, session::snapshot::Snapshot, text::DocumentText};
use alloc::{string::String, vec::Vec};

use crate::server::operations::operator::{Category, view::inventory::Inventory};

mod target;
pub use target::Target;

pub const VIEWS: usize = 6;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Kind(usize);
impl Kind {
	pub fn parse(name: &str) -> Option<Self> {
		BOOT_CAPABILITIES.iter().position(|cap| cap.id == name).map(Self)
	}
	pub fn name(self) -> &'static str {
		BOOT_CAPABILITIES[self.0].id
	}
	pub fn index(self) -> usize {
		self.0
	}
	pub fn all() -> impl Iterator<Item = Self> {
		(0..VIEWS).map(Self)
	}
}
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Filter {
	pub search: String,
	pub reference: Option<crate::server::operations::operator::ReferenceKind>,
}
#[derive(Default)]
struct Slot {
	target: Option<(String, String)>,
	epoch: u64,
	requested: u64,
	completed: u64,
	active: bool,
	filter: Filter,
	page: Option<(Category, u64)>,
}
pub struct Read {
	pub kind: Kind,
	pub scope: Option<String>,
	pub filter: Filter,
	pub version: u64,
	pub page: Option<(Category, u64)>,
	epoch: u64,
}
#[derive(Default)]
pub struct Operations {
	pub operator: Option<Inventory>,
	slots: [Slot; VIEWS],
	connected: Vec<DocumentText>,
	issues: Vec<(DocumentText, DocumentText)>,
}
fn bump(value: &mut u64) -> Result<(), &'static str> {
	*value = value
		.checked_add(1)
		.ok_or("Rooms operations read generation exhausted")?;
	Ok(())
}
fn relevant(subject: &DocumentText) -> bool {
	subject
		.as_str()
		.is_some_and(|s| s == "session" || s.starts_with("capability:") || s.starts_with("peering:"))
}
impl Operations {
	pub fn observe(&mut self, snapshot: &Snapshot) -> Result<[bool; VIEWS], &'static str> {
		let mut cleared = [false; VIEWS];
		let connection_changed = !self.connected.iter().eq(snapshot
			.connected_directories
			.as_slice()
			.iter()
			.map(|field| field.text()));
		let issues_changed = !self.issues.iter().map(|(a, b)| (a, b)).eq(snapshot
			.issues
			.as_slice()
			.iter()
			.filter(|(a, _)| relevant(a.text()))
			.map(|(a, b)| (a.text(), b.text())));
		if connection_changed {
			self.connected = snapshot
				.connected_directories
				.as_slice()
				.iter()
				.map(|field| field.text().clone())
				.collect();
		}
		if issues_changed {
			self.issues = snapshot
				.issues
				.as_slice()
				.iter()
				.filter(|(a, _)| relevant(a.text()))
				.map(|(a, b)| (a.text().clone(), b.text().clone()))
				.collect();
		}
		for kind in Kind::all() {
			let target = target::selected(snapshot, kind);
			let slot = &mut self.slots[kind.0];
			let changed = slot
				.target
				.as_ref()
				.map(|(scope, swiss)| (scope.as_str(), swiss.as_str()))
				!= target.as_ref().map(|c| (c.scope, c.swiss));
			if changed {
				cleared[kind.0] = true;
				if kind.name() == "operator" {
					self.operator = None;
				}
				slot.target = target.map(|c| (c.scope.into(), c.swiss.into()));
				bump(&mut slot.epoch)?;
			}
			if changed || connection_changed || issues_changed {
				slot.page = None;
				bump(&mut slot.requested)?;
			}
		}
		Ok(cleared)
	}
	pub fn invalidate(&mut self, scope: &str) -> Result<(), &'static str> {
		for slot in &mut self.slots {
			if slot.target.as_ref().is_some_and(|(target, _)| target == scope) {
				slot.page = None;
				bump(&mut slot.requested)?;
			}
		}
		Ok(())
	}
	pub fn scope(&self, kind: Kind) -> Option<&str> {
		self.slots[kind.0].target.as_ref().map(|(scope, _)| scope.as_str())
	}
	pub fn filter(&self, kind: Kind) -> &Filter {
		&self.slots[kind.0].filter
	}
	pub fn request(&mut self, kind: Kind, filter: Option<Filter>) -> Result<u64, &'static str> {
		let slot = &mut self.slots[kind.0];
		if filter.as_ref().is_some_and(|filter| {
			filter
				.search
				.encode_utf16()
				.take(crate::server::operations::operator::MAX_QUERY + 1)
				.count() > crate::server::operations::operator::MAX_QUERY
		}) {
			return Err("Rooms operator search exceeds its text limit");
		}
		if let Some(filter) = filter
			&& slot.filter != filter
		{
			slot.filter = filter;
			if kind.name() == "operator" {
				self.operator = None;
			}
			bump(&mut slot.epoch)?;
		}
		slot.page = None;
		bump(&mut slot.requested)?;
		Ok(slot.requested)
	}
	pub fn pending(&self, kind: Kind) -> Option<u64> {
		let slot = &self.slots[kind.0];
		(slot.active || slot.requested != slot.completed).then_some(slot.requested)
	}
	pub fn request_page(&mut self, category: Category) -> Result<Option<u64>, &'static str> {
		let kind = Kind::parse("operator").expect("operator inventory");
		if self.pending(kind).is_some() {
			return Err("Operator refresh has not settled");
		}
		let inventory = self
			.operator
			.as_ref()
			.ok_or("The operator inventory is not available")?;
		let Some(cursor) = inventory.cursor(category) else {
			return Ok(None);
		};
		let slot = &mut self.slots[kind.0];
		bump(&mut slot.requested)?;
		slot.page = Some((category, cursor));
		Ok(Some(slot.requested))
	}
	pub fn begin(&mut self, kind: Kind) -> Option<Read> {
		let slot = &mut self.slots[kind.0];
		if slot.active || slot.requested == slot.completed {
			return None;
		}
		slot.active = true;
		Some(Read {
			kind,
			scope: slot.target.as_ref().map(|(scope, _)| scope.clone()),
			filter: slot.filter.clone(),
			version: slot.requested,
			epoch: slot.epoch,
			page: slot.page.take(),
		})
	}
	pub fn finish(&mut self, read: &Read) -> bool {
		let slot = &mut self.slots[read.kind.0];
		slot.active = false;
		// A refresh requests another observation; it does not revoke the
		// authority of an answer already being read. Publish that progress while
		// leaving newer work pending. Credential/filter replacement does revoke
		// the old answer, and page cursors still require an unchanged inventory.
		if slot.epoch != read.epoch || (read.page.is_some() && slot.requested != read.version) {
			return false;
		}
		slot.completed = read.version;
		true
	}
	pub fn retire(&mut self) -> Result<(), &'static str> {
		self.operator = None;
		for slot in &mut self.slots {
			slot.page = None;
			bump(&mut slot.epoch)?;
			bump(&mut slot.requested)?;
		}
		Ok(())
	}
}

#[cfg(test)]
#[path = "operations_tests.rs"]
mod tests;
