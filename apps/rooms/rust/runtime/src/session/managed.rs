//! One Loam session record and a bounded executor for its committed receipts.
//! Callbacks hold only a weak owner. Workers survive caller cancellation.
mod activity;
mod admission;
mod bootstrap;
mod incoming;
pub use activity::{Activity, ActivityDelivery, Event};
mod bundle;
mod content;
mod coordination;
pub use coordination::{
	MembershipEvent, MembershipKinds, MembershipReceiver, MembershipReport, MembershipTarget, Memberships,
};
mod discovery;
mod signaling;
pub use signaling::SignalingRegistration;
mod executor;
mod imports;
mod inbox;
pub use discovery::DirectoryWatch;
pub use inbox::{Inbox, InboxOrigin};
mod allocation;
mod archive_sharing;
mod authority;
mod bridge;
mod outgoing;
mod received_lines;
mod recording;
pub use received_lines::{LineMemory, LineReceiver, LineResize, ReceivedLine};
mod changes;
pub use changes::Wake as SessionChanges;
mod opening;
mod profile;
pub mod realization;
mod retained;
mod supervision;
mod watching;
pub use profile::{production_limits, reader_limits, storage_limits};
pub use supervision::Membership;
pub use watching::WorkspaceActivity;
mod introductions;
mod records;
mod results;
mod uploads;
pub use bootstrap::{Bootstrap, BootstrapOptions};
pub use bundle::OperationsBundle;
use glowcap::{
	Host, Ref, Result,
	loam::{ControlPowers, PolicyValue, Registration, Schema},
};
pub use imports::Import;
pub use opening::{Opened, StartupAnchor};
use rooms_application::content::session::{custody, records as codec};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	num::NonZeroUsize,
	rc::Rc,
};
use tokio::sync::Notify;

/// The embedding retains this owner through worker close, attachment close,
/// and storage close, in that order. There is no Rust authority ledger.
pub struct Session<P: Tasks + Deadline + Clone + 'static> {
	state: Rc<State<P>>,
}
struct State<P: Tasks + Deadline + Clone + 'static> {
	admission: RefCell<admission::Admission>,
	platform: P,
	reply_bytes: NonZeroUsize,
	writer: Rc<executor::Writer>,
	closing: Cell<bool>,
	jobs: RefCell<BTreeMap<String, executor::Job<P>>>,
	changed: Notify,
	inboxes: Rc<inbox::Budget>,
	memberships: Rc<supervision::Budget<P>>,
	workspace_observers: Rc<supervision::Budget<P>>,
	discovery_observers: Rc<supervision::Budget<P>>,
	discovery_refresh: Rc<watching::Refresh>,
	signaling_observers: Rc<supervision::Budget<P>>,
	changes: changes::Owner<P>,
	lines: Rc<supervision::Budget<P>>,
	line_bytes: Rc<Cell<usize>>,
	next_line: Cell<u64>,
	activity: Rc<Activity<P>>,
	effect_reader: RefCell<Option<Ref>>,
	recording: RefCell<Option<Rc<dyn recording::Sink>>>,
	credentials: RefCell<Option<Rc<bridge::credentials::Credentials>>>,
	credential_retention: RefCell<Option<Rc<bridge::retention::Owner<P>>>>,
	introductions: RefCell<introductions::PendingCalls<P>>,
	trace: RefCell<Option<Rc<dyn crate::trace::Status>>>,
}
impl<P: Tasks + Deadline + Clone + 'static> State<P> {
	fn running(&self, id: &str) -> bool {
		self.jobs.borrow().get(id).is_some_and(|job| job.failure.is_none())
	}
	fn receipt_running(&self, id: &str, erasure: Option<&rooms_application::session::state::OperationId>) -> bool {
		self.running(id)
			|| (erasure.is_some_and(|operation| operation.text().as_str() == Some(id))
				&& self.recording.borrow().as_ref().is_some_and(|sink| sink.erasing()))
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Scalar wake notifications contain no authority. Consumers recheck their
	/// original source. All use the existing two parked shared observations.
	pub fn changes(&self) -> Result<SessionChanges> {
		self.state.changes.subscribe(&self.state)
	}
	/// Install startup policy before serving collaborators. Running accounting
	/// cannot be replaced while depleted grants are retained.
	pub fn configure_admission(&self, settings: rooms_application::admission::Settings) -> Result<()> {
		let mut admission = self.state.admission.borrow_mut();
		if !admission.is_unused() || self.state.closing.get() {
			return Err(glowcap::loam::refusal("admission policy is already in use or closing"));
		}
		self.state.inboxes.configure_admission(settings)?;
		*admission = admission::Admission::new(settings);
		Ok(())
	}
	pub fn configure_trace(&self, trace: Rc<dyn crate::trace::Status>) -> Result<()> {
		let mut held = self.state.trace.borrow_mut();
		if held.is_some() || self.state.closing.get() {
			return Err(glowcap::loam::refusal("trace publisher is already owned or closing"));
		}
		*held = Some(trace);
		Ok(())
	}
	/// The embedding admits the owning reply allowance independently of record
	/// codec limits. Oversized target replies stay unresolved. They never justify
	/// another target call. EffectExecution::result_size_bound accounts for this
	/// allowance's shared and C projection ownership.
	pub fn new(host: Host, platform: P, reply_bytes: NonZeroUsize) -> Self {
		let writer = Rc::new(executor::Writer::new(host.clone()));
		let inboxes = Rc::new(inbox::Budget::new(Rc::downgrade(&writer)));
		Self {
			state: Rc::new(State {
				admission: RefCell::new(admission::Admission::default()),
				activity: Rc::new(Activity::new(host, platform.clone())),
				effect_reader: RefCell::new(None),
				recording: RefCell::new(None),
				credentials: RefCell::new(None),
				credential_retention: RefCell::new(None),
				introductions: RefCell::new(BTreeMap::new()),
				trace: RefCell::new(None),
				platform,
				reply_bytes,
				writer,
				closing: Cell::new(false),
				jobs: RefCell::new(BTreeMap::new()),
				changed: Notify::new(),
				inboxes,
				memberships: Rc::new(supervision::Budget::default()),
				workspace_observers: Rc::new(supervision::Budget::default()),
				discovery_observers: Rc::new(supervision::Budget::default()),
				discovery_refresh: Rc::new(watching::Refresh::default()),
				signaling_observers: Rc::new(supervision::Budget::default()),
				changes: changes::Owner::default(),
				lines: Rc::new(supervision::Budget::default()),
				line_bytes: Rc::new(Cell::new(0)),
				next_line: Cell::new(1),
			}),
		}
	}
	pub fn registration(&self) -> Registration {
		content::registration(Rc::downgrade(&self.state))
	}
	/// Install the embedding's failure owner before starting effects or callbacks.
	/// The reporter borrows terminal evidence and must not retain this session.
	/// Reporting cannot settle a receipt or authorize retry.
	pub fn on_trouble(&self, report: impl Fn(&str, &glowcap::Error) + 'static) -> Result<()> {
		let mut reporter = self.state.writer.trouble.borrow_mut();
		if reporter.is_some()
			|| !self.state.jobs.borrow().is_empty()
			|| !self.state.introductions.borrow().is_empty()
			|| self.state.inboxes.active() != 0
			|| self.state.workspace_observers.active() != 0
			|| self.state.discovery_observers.active() != 0
			|| self.state.changes.started()
			|| self.state.closing.get()
		{
			return Err(glowcap::loam::refusal(
				"failure owner must be installed before effects or callbacks",
			));
		}
		*reporter = Some(Box::new(report));
		Ok(())
	}
	/// Bind private use and management after attachment restoration. Public
	/// children are derived from these roots. Neither private endpoint is published.
	pub fn bind(&self, root: Ref, control: Ref) -> Result<()> {
		self.state.writer.bind(root, control)
	}
	pub async fn initialize(&self) -> Result<()> {
		self.state.writer.mutate("initialize", &[]).await?;
		self.state
			.activity
			.reader(&self.state.writer.host, self.state.platform.clone())?;
		content::receipt_observation::initialize(&self.state)?;
		Ok(())
	}
	/// Derive public use and independently held management. The private root is
	/// never exposed to a client or reconstructed from a publication name.
	pub async fn derive(&self, terms: PolicyValue, depth: u16, powers: ControlPowers) -> Result<(Ref, Ref)> {
		if self.state.closing.get() {
			return Err(glowcap::loam::refusal("session is closing"));
		}
		self.state.writer.derive(terms, depth, powers).await
	}
	pub async fn replace_workspace(
		&self,
		intent: &rooms_application::content::session::workspace::Intent,
	) -> Result<()> {
		let intent = serde_json::to_string(intent).map_err(|_| glowcap::loam::refusal("invalid workspace intent"))?;
		self.state
			.writer
			.mutate("replaceWorkspace", &[intent.into()])
			.await
			.map(|_| ())
	}
	/// Import one committed result through the actual original source. Current
	/// command admission and ManageCustody are required. Equal policies or the
	/// private root cannot substitute for that source. The destination keeps the
	/// result's role and exact saved recipe, including its dependent live facet.
	pub async fn import_result(
		&self,
		source: &Ref,
		operation: &str,
		intent: &str,
		result: custody::Coordinate,
		destination: custody::Coordinate,
	) -> Result<()> {
		let coordinate = |field: custody::Coordinate| {
			serde_json::to_string(&field).map_err(|_| glowcap::loam::refusal("invalid result coordinate"))
		};
		self.state
			.writer
			.idempotent_through(
				source,
				"import-result",
				&[
					operation.into(),
					intent.into(),
					coordinate(result)?.into(),
					coordinate(destination)?.into(),
				],
			)
			.await
			.map(|_| ())
	}
	/// Resume retained confirmation, execution observation or private settlement.
	/// The stored phase prevents this method from issuing a second target call.
	pub fn resume_pending(&self) -> Result<()> {
		if let Some(retention) = self.state.credential_retention.borrow().as_ref() {
			retention.retry();
		}
		if let Some(recording) = self.state.recording.borrow().as_ref() {
			recording.retry();
		}
		introductions::resume(&self.state);
		let pending: Vec<_> = self
			.state
			.jobs
			.borrow()
			.iter()
			.filter(|(_, job)| job.failure.is_some())
			.map(|(id, _)| id.clone())
			.collect();
		for id in pending {
			executor::resume(&self.state, &id)?;
		}
		Ok(())
	}
	/// Wait for actual workers, retaining private results if settlement refuses.
	/// Failure leaves the owner open for recovery. Callers must not close storage.
	pub async fn close(&self) -> Result<()> {
		self.state.closing.set(true);
		let drained = async {
			loop {
				let changed = self.state.changed.notified();
				tokio::pin!(changed);
				changed.as_mut().enable();
				if let Some(error) = introductions::failure(&self.state.introductions.borrow()) {
					return Err(error);
				}
				if self.state.introductions.borrow().is_empty() {
					return Ok::<(), glowcap::Error>(());
				}
				changed.await;
			}
		};
		if !self.state.introductions.borrow().is_empty() {
			self.state
				.platform
				.within(20_000, drained)
				.await
				.ok_or_else(|| glowcap::loam::refusal("direct transition admission remains pending; retry close"))??;
		}
		let recording = self.state.recording.borrow().clone();
		if let Some(recording) = recording {
			recording.close().await?;
		}
		self.state.activity.close(&self.state.platform).await?;
		self.state.discovery_observers.close_all().await?;
		self.state.signaling_observers.close_all().await?;
		self.close_received_lines().await?;
		self.state.memberships.retry_closing();
		self.state.workspace_observers.retry_closing();
		// Once callbacks have drained and every membership has entered cleanup,
		// no consumer uses the scalar wake feeds. Retire those independent calls
		// even when an unknown upstream result still owns a membership barrier.
		// The exact admission/retirement receivers remain in that worker.
		if self.state.inboxes.active() == 0
			&& self.state.memberships.all_closing()
			&& self.state.workspace_observers.active() == 0
		{
			self.state.changes.close().await?;
		}
		if self.state.inboxes.active() != 0
			|| self.state.memberships.active() != 0
			|| self.state.workspace_observers.active() != 0
			|| self.state.discovery_observers.active() != 0
		{
			return Err(glowcap::loam::refusal(
				"close session callback owners before closing their attachment",
			));
		}
		self.state.changes.close().await?;
		loop {
			let changed = self.state.changed.notified();
			tokio::pin!(changed);
			changed.as_mut().enable();
			if self.state.jobs.borrow().is_empty() {
				let retention = self.state.credential_retention.borrow().clone();
				if let Some(retention) = retention {
					retention.close().await?;
				}
				return Ok(());
			}
			if let Some(error) = self.state.jobs.borrow().values().find_map(|job| job.failure.clone()) {
				return Err(error);
			}
			changed.await;
		}
	}
}
/// Register every family on both physical backends before creating or restoring
/// the resource. Record limits and capability custody are separate budgets.
pub fn schemas() -> Vec<Schema> {
	codec::SCHEMAS
		.iter()
		.map(|schema| Schema {
			id: schema.id,
			version: schema.version,
			max_payload: schema.max_payload,
			max_edges: schema.max_edges,
		})
		.collect()
}
/// Creation starts with bounded empty intent. Initialization installs the
/// complete graph transactionally before public use is derived or published.
pub fn initial_payload(connection: rooms_application::content::session::workspace::Connection) -> Result<Vec<u8>> {
	let mut intent = rooms_application::content::session::workspace::Intent::empty();
	intent.connection = connection;
	let mut pages =
		codec::encode_workspace(&intent).map_err(|_| glowcap::loam::refusal("initial session exceeds its profile"))?;
	Ok(pages.remove(0))
}
const MAX_JOBS: usize = custody::MAX_EFFECTS;
