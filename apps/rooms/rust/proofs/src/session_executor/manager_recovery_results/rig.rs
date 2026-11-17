//! Fixtures for the manager recovery proofs: fake exporter peers that count
//! every call, and one rig that holds the session, store and connection.
use super::super::{requests::coordinate, *};
use super::{
	super::{
		failure::AbortAfterAdmission,
		membership_results::{self, MEMBER},
	},
	dependent,
};
use glowcap::{CaptpVersion, Locator, Session};
use rooms_glowcap::client::workspace::{ResultImport, Workspace};
use std::cell::RefCell;

pub(super) const IDENTITY: &str = "manager-identity";

/// What one scenario's peers have been asked, and what they answer.
#[derive(Clone)]
pub(super) struct Peers {
	pub(super) operator_calls: Rc<Cell<usize>>,
	pub(super) operator_args: Rc<RefCell<Vec<Vec<String>>>>,
	pub(super) seat_reads: Rc<Cell<usize>>,
	pub(super) entrance_calls: Rc<Cell<usize>>,
	/// The seat's answer to its identity read.
	pub(super) identity: Rc<RefCell<std::result::Result<String, String>>>,
	/// What the issued manager says it governs.
	pub(super) governs: Rc<RefCell<String>>,
	/// How many times the issued manager was asked what it governs.
	pub(super) governs_calls: Rc<Cell<usize>>,
	/// Parks the session's next outbound write once the named peer has answered.
	pub(super) gate: gate::Gate,
	pub(super) park: Rc<Cell<Option<Stage>>>,
}
/// The peer whose answer is the last before the session's next call is parked.
#[derive(Clone, Copy, PartialEq)]
pub(super) enum Stage {
	Seat,
	Operator,
}
impl Peers {
	pub(super) fn park_after(&self, stage: Stage) {
		if self.park.get() == Some(stage) {
			self.gate.block();
		}
	}
	pub(super) fn new(gate: gate::Gate) -> Self {
		Self {
			gate,
			park: Rc::default(),
			operator_calls: Rc::default(),
			operator_args: Rc::default(),
			seat_reads: Rc::default(),
			entrance_calls: Rc::default(),
			identity: Rc::new(RefCell::new(Ok(IDENTITY.into()))),
			governs: Rc::new(RefCell::new(IDENTITY.into())),
			governs_calls: Rc::default(),
		}
	}
	pub(super) fn answer(&self, identity: impl Into<String>) {
		*self.identity.borrow_mut() = Ok(identity.into());
	}
}
/// What an exported fixture object answers to each verb.
pub(super) type Handler = Rc<dyn Fn(&str, &[Argument]) -> std::result::Result<Argument, String>>;
/// Where an exported object lives relative to the session.
#[derive(Clone, Copy, PartialEq)]
pub(super) enum Home {
	Remote,
	/// A second exporter on its own session, distinct from `Remote`.
	Other,
	Local,
}
#[derive(Clone, Copy)]
pub(super) struct Spec {
	pub(super) operator: Home,
	pub(super) seat: Home,
	pub(super) entrance: bool,
	/// The row is entered through its directory's public entry, not a held link.
	pub(super) public: bool,
	/// Holds the member fixture that joins a room and returns a live seat.
	pub(super) member: bool,
}
impl Spec {
	pub(super) const REMOTE: Self = Self {
		operator: Home::Remote,
		seat: Home::Remote,
		entrance: true,
		public: false,
		member: false,
	};
}
pub(super) const OPERATOR: Schema = Schema {
	id: 0x4d52_4f50_0001,
	version: 1,
	max_payload: 64,
	max_edges: 1,
};
/// An operator held as local Loam content, so it is local to the session's Host.
pub(super) struct LocalOperator(Handler);
impl Content for LocalOperator {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		(self.0)(input.verb, input.args).map_err(loam::refusal)
	}
}
/// An object exported by `home`: a recipe the session enlivens over its
/// connection, or a reference local to the session's own Host.
pub(super) async fn export(
	session: &Host,
	exporters: [(&Host, &Locator); 2],
	home: Home,
	handler: Handler,
) -> (Ref, Option<String>) {
	let exporter = exporters[usize::from(home == Home::Other)];
	if home == Home::Local {
		let reference = session
			.spawn(move |verb, args| handler(verb.ok_or("fixture requires a method")?, args))
			.unwrap();
		return (reference, None);
	}
	let uri = publish(exporter.0, exporter.1, handler);
	(session.enliven(&uri).await.unwrap(), Some(uri))
}
pub(super) fn publish(exporter: &Host, locator: &Locator, handler: Handler) -> String {
	let swiss = exporter
		.publish_durable(move || {
			let handler = handler.clone();
			Box::new(move |verb, args| handler(verb.ok_or("fixture requires a method")?, args))
		})
		.unwrap();
	glowcap::format_sturdyref(locator, swiss.as_bytes(), CaptpVersion::V1_0).unwrap()
}
pub(super) struct Rig {
	pub(super) host: Host,
	pub(super) owner: managed::Session<Platform>,
	pub(super) root: Ref,
	pub(super) peers: Peers,
	pub(super) reports: Rc<RefCell<Vec<String>>>,
	pub(super) operator: custody::Coordinate,
	pub(super) seat: custody::Coordinate,
	pub(super) access: Option<custody::Coordinate>,
	pub(super) intent: Intent,
	pub(super) manager_uri: String,
	pub(super) database: Database,
	pub(super) store: loam::Store,
	pub(super) attachment: loam::Attachment,
	pub(super) sessions: Vec<Session>,
	pub(super) exporter: Host,
	pub(super) other: Host,
	/// The seat's remote reference as the session first enlivened it.
	pub(super) seat_ref: Ref,
	/// The member fixture's entrance, when `Spec::member` holds one.
	pub(super) member: Option<(Ref, Rc<Cell<usize>>)>,
	/// While set, the private settlement callback refuses after the worker ran.
	pub(super) refuse_settlement: Rc<Cell<bool>>,
	pub(super) entrance_uri: String,
	pub(super) schemas: Vec<Schema>,
	pub(super) limits: loam::Limits,
	pub(super) resource: loam::Resource,
	pub(super) last_base: Cell<u64>,
	pub(super) directory: custody::Coordinate,
	pub(super) public: bool,
	pub(super) platform: Platform,
	pub(super) gate: gate::Gate,
}
pub(super) fn room_json(
	access: Option<custody::Coordinate>,
	seat: Option<custody::Coordinate>,
	public: Option<custody::Coordinate>,
) -> serde_json::Value {
	serde_json::json!({
		"publicEntry": public.map(|entry| serde_json::json!({"access": entry.key})),
		"publication": public.map(|_| "published"),
		"kind": "room", "id": "room", "directory": "directory", "name": "room",
		"access": access.map(|entry| entry.key), "seat": seat.map(|entry| entry.key),
		"reconnect": "requested", "standing": null, "draft": ""
	})
}
impl Rig {
	pub(super) async fn open(name: &str, spec: Spec) -> Self {
		let database = Database::new(name);
		let exporter = Host::from_seed([140; 32]).unwrap();
		let locator = Locator::bare("tcp", "127.0.0.1:9011");
		exporter.set_advertised_locator(&locator).unwrap();
		let other = Host::from_seed([142; 32]).unwrap();
		let other_locator = Locator::bare("tcp", "127.0.0.1:9012");
		other.set_advertised_locator(&other_locator).unwrap();
		let exporters = [(&exporter, &locator), (&other, &other_locator)];
		let mut schemas = managed::schemas();
		schemas.push(OPERATOR);
		schemas.push(MEMBER);
		let mut limits = managed::reader_limits(crate::session_storage::limits_for(
			16,
			8,
			loam::ValueBounds {
				values: 32,
				capabilities: 8,
				bytes: 1 << 17,
				..Default::default()
			},
		))
		.unwrap();
		limits.max_leases = limits.max_leases.checked_mul(limits.max_operations).unwrap();
		let store = database.open(true, &schemas, limits).await;
		let policy = rooms_glowcap::policy::descriptor().unwrap();
		let resource = environment::create(
			&store,
			&policy,
			schemas[0],
			&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(),
			2,
		)
		.await;
		let host = Host::from_seed([141; 32]).unwrap();
		let platform = Platform::default();
		let gate = gate::Gate::default();
		let (dialed, accepted) = super::results::connect(&host, &exporter, &locator, gate.clone()).await;
		let mut sessions = vec![dialed, accepted];
		if [spec.operator, spec.seat].contains(&Home::Other) {
			let (dialed, accepted) = super::results::connect(&host, &other, &other_locator, gate.clone()).await;
			sessions.extend([dialed, accepted]);
		}
		let owner = managed::Session::new(
			host.clone(),
			platform.clone(),
			std::num::NonZeroUsize::new(1 << 17).unwrap(),
		);
		let reports = Rc::new(RefCell::new(Vec::<String>::new()));
		owner
			.on_trouble({
				let reports = reports.clone();
				move |_, cause| reports.borrow_mut().push(cause.to_string())
			})
			.unwrap();
		let peers = Peers::new(gate.clone());
		let manager_uri = publish(&exporter, &locator, {
			let peers = peers.clone();
			Rc::new(move |verb, _| match verb {
				"governs" => {
					peers.governs_calls.set(peers.governs_calls.get() + 1);
					Ok(Argument::String(peers.governs.borrow().clone()))
				}
				_ => Err(format!("the manager fixture has no method {verb}")),
			})
		});
		let operator_handler: Handler = {
			let (peers, manager) = (peers.clone(), manager_uri.clone());
			Rc::new(move |verb, args| {
				assert_eq!(verb, "giveManager");
				peers.operator_calls.set(peers.operator_calls.get() + 1);
				peers.operator_args.borrow_mut().push(
					args.iter()
						.map(|value| value.as_str().unwrap_or("<non-text>").to_owned())
						.collect(),
				);
				peers.park_after(Stage::Operator);
				Ok(Argument::String(manager.clone()))
			})
		};
		let local_operator = (spec.operator == Home::Local).then(|| Registration {
			schema: OPERATOR.id,
			version: 1,
			graph: None,
			methods: vec![Method {
				verb: "giveManager".into(),
				retry: Retry::ReadOnly,
			}],
			content: Box::new(LocalOperator(operator_handler.clone())),
		});
		let operator_resource = environment::create(&store, &policy, OPERATOR, b"operator", 1).await;
		let refuse_settlement = Rc::new(Cell::new(false));
		let mut content = owner.registration();
		content.content = Box::new(AbortAfterAdmission {
			inner: content.content,
			refuse: Rc::new(Cell::new(false)),
			refuse_settlement: refuse_settlement.clone(),
		});
		let mut registrations = vec![content];
		registrations.extend(local_operator);
		let joins = Rc::new(Cell::new(0));
		let seat_uri = Rc::new(RefCell::new(None));
		if spec.member {
			let mut member = membership_results::registration(joins.clone(), Rc::default(), Rc::default(), 0);
			member.content = Box::new(dependent::RemoteSeat {
				inner: member.content,
				uri: seat_uri.clone(),
			});
			registrations.push(member);
		}
		let member_resource = if spec.member {
			Some(environment::create(&store, &policy, MEMBER, b"entrance", 2).await)
		} else {
			None
		};
		let attachment = store.attach(&host, registrations).unwrap();
		environment::start_live(&attachment, None, 32).await;
		let (root, root_control) = environment::restore(&attachment, resource).await;
		owner.bind(root.clone(), root_control).unwrap();
		owner.initialize().await.unwrap();
		let (seat_ref, exported) = export(&host, exporters, spec.seat, {
			let peers = peers.clone();
			Rc::new(move |verb, _| {
				assert_eq!(verb, "managedRoomIdentity");
				peers.seat_reads.set(peers.seat_reads.get() + 1);
				peers.park_after(Stage::Seat);
				peers.identity.borrow().clone().map(Argument::String)
			})
		})
		.await;
		let entrance_uri = publish(&exporter, &locator, {
			let peers = peers.clone();
			Rc::new(move |_, _| {
				peers.entrance_calls.set(peers.entrance_calls.get() + 1);
				Err("the entrance is never invoked".into())
			})
		});
		let operator = coordinate(custody::Role::Operator, 1);
		let seat = coordinate(custody::Role::RoomSeat, 1);
		let access = (spec.entrance && !spec.public).then(|| coordinate(custody::Role::RoomAccess, 1));
		let directory = coordinate(custody::Role::DirectoryAccess, 1);
		let entry = coordinate(custody::Role::DirectoryAccess, 2);
		let (operator_ref, operator_uri) = if spec.operator == Home::Local {
			(environment::restore(&attachment, operator_resource).await.0, None)
		} else {
			let (home, locator) = exporters[usize::from(spec.operator == Home::Other)];
			let uri = publish(home, locator, operator_handler);
			(host.enliven(&uri).await.unwrap(), Some(uri))
		};
		owner.import(operator, operator_ref, operator_uri).await.unwrap();
		*seat_uri.borrow_mut() = exported;
		owner.import(seat, seat_ref.clone(), None).await.unwrap();
		let member = match member_resource {
			Some(resource) => Some((environment::restore(&attachment, resource).await.0, joins)),
			None => None,
		};
		let entrance_uri_kept = entrance_uri.clone();
		let entrance = host.enliven(&entrance_uri).await.unwrap();
		owner
			.import(directory, entrance.clone(), Some(entrance_uri.clone()))
			.await
			.unwrap();
		if let Some(access) = access {
			owner
				.import(access, entrance.clone(), Some(entrance_uri.clone()))
				.await
				.unwrap();
		}
		if spec.public {
			owner.import(entry, entrance, Some(entrance_uri)).await.unwrap();
		}
		let mut intent = Intent::empty();
		intent.operators = List::new(vec![operator.key.retag()]).unwrap();
		intent.directories = serde_json::from_value(serde_json::json!([{
			"id": "directory", "access": directory.key, "home": true, "nick": "peer",
			"nickAllocation": "exact", "standing": null
		}]))
		.unwrap();
		intent.conversations = serde_json::from_str(
			&serde_json::json!([room_json(access, Some(seat), spec.public.then_some(entry))]).to_string(),
		)
		.unwrap();
		owner.replace_workspace(&intent).await.unwrap();
		Self {
			host,
			owner,
			root,
			peers,
			reports,
			operator,
			seat,
			access,
			intent,
			manager_uri,
			database,
			store,
			attachment,
			sessions,
			exporter,
			other,
			seat_ref,
			member,
			refuse_settlement,
			entrance_uri: entrance_uri_kept,
			schemas,
			limits,
			resource,
			last_base: Cell::new(0),
			directory: entry,
			public: spec.public,
			platform,
			gate,
		}
	}
	/// The request's operator and witness text for the room row as it stands now.
	pub(super) fn arguments(&self, access: Option<custody::Coordinate>, seat: custody::Coordinate) -> Vec<String> {
		let witness = serde_json::json!({
			"id": "room", "directory": "directory", "seat": seat.key,
			"access": access.map(|entry| entry.key),
			"publicEntry": self.public.then(|| serde_json::json!({"access": self.directory.key})),
			"publication": self.public.then_some("published")
		});
		vec![serde_json::to_string(&self.operator.key).unwrap(), witness.to_string()]
	}
	pub(super) async fn base(&self) -> i64 {
		self.host
			.send(&self.root, "snapshot", &[])
			.await
			.unwrap()
			.as_list()
			.unwrap()[0]
			.as_i64()
			.unwrap()
	}
	/// Submit the effect and wait for its settled status.
	pub(super) async fn recover(&self, id: &str, rest: &[String]) -> std::result::Result<Argument, glowcap::Error> {
		self.submit(id, rest).await?;
		Ok(finished(&self.host, &self.root, id, &self.root).await)
	}
	pub(super) async fn status(&self, id: &str) -> Argument {
		self.host
			.send(
				&self.root,
				"effect-status",
				&[id.into(), Argument::Reference(self.root.clone())],
			)
			.await
			.unwrap()
	}
	pub(super) async fn submit(&self, id: &str, rest: &[String]) -> std::result::Result<(), glowcap::Error> {
		let base = self.base().await;
		self.last_base.set(u64::try_from(base).unwrap());
		let mut args = vec![id.into(), base.into(), "recoverRoomManager".into()];
		args.extend(rest.iter().cloned().map(Argument::from));
		mutate(&self.host, &self.root, "command", &args).await.map(|_| ())
	}
	/// Take the committed result into the room row the way a viewer does: one
	/// transaction naming the manager result, its destination and the candidate.
	/// `edit` rewrites the candidate's room row, and `releases` drops custody.
	pub(super) async fn land(
		&self,
		id: &str,
		rest: &[String],
		releases: &[custody::Coordinate],
		edit: impl FnOnce(&mut Intent),
	) -> std::result::Result<(), rooms_glowcap::client::Error> {
		let workspace = Workspace::local(self.host.clone(), Platform::default(), self.root.clone());
		let command = workspace
			.prepare_command(id, self.last_base.get(), "recoverRoomManager", rest)
			.await?;
		let snapshot = workspace.snapshot().await?;
		let mut candidate = snapshot.intent;
		edit(&mut candidate);
		let result = coordinate(custody::Role::RoomControl, 1);
		let mappings = [ResultImport {
			result,
			destination: coordinate(custody::Role::RoomControl, 9),
		}];
		let request =
			command.prepare_result_acquisition_with_source(snapshot.revision, &mappings, releases, &candidate, None)?;
		request.submit().await.map(|_| ())
	}
	/// Hold another capability at `role`/`slot`, then replace the room row.
	pub(super) async fn replace_row(
		&self,
		spare: Option<custody::Coordinate>,
		edit: impl FnOnce(&mut session::workspace::Room),
	) {
		if let Some(spare) = spare {
			let reference = self.host.enliven(&self.manager_uri).await.unwrap();
			self.owner
				.import(spare, reference, Some(self.manager_uri.clone()))
				.await
				.unwrap();
		}
		let mut intent = self.intent.clone();
		edit(first_room(&mut intent));
		self.owner.replace_workspace(&intent).await.unwrap();
	}
	pub(super) async fn room(&self) -> session::workspace::Room {
		let workspace = Workspace::local(self.host.clone(), Platform::default(), self.root.clone());
		let intent = workspace.snapshot().await.unwrap().intent;
		let session::workspace::Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
			panic!("room row")
		};
		room.as_ref().clone()
	}
	/// Replace the custody at `coordinate` with a different authority, then hold
	/// the original workspace row again. `None` restores what was there.
	pub(super) async fn swap_custody(&self, coordinate: custody::Coordinate, held: Option<(Ref, Option<String>)>) {
		self.rehold(coordinate, held, &self.intent).await;
	}
	/// Export the workspace configuration, which carries no seat, then hold the
	/// entrance again from its link and take the exported rows back in.
	pub(super) async fn restore_exported(&self, entrance: custody::Coordinate) {
		let workspace = Workspace::local(self.host.clone(), Platform::default(), self.root.clone());
		let (exported, _) = workspace.export_configuration().await.unwrap();
		let mut exported = exported.intent;
		assert!(first_room(&mut exported).seat.is_none(), "an export carried a seat");
		self.rehold(entrance, None, &exported).await;
	}
	async fn rehold(&self, coordinate: custody::Coordinate, held: Option<(Ref, Option<String>)>, intent: &Intent) {
		let released = serde_json::to_string(&Intent::empty()).unwrap();
		mutate(
			&self.host,
			&self.root,
			"release",
			&[serde_json::to_string(&coordinate).unwrap().into(), released.into()],
		)
		.await
		.unwrap();
		let (reference, uri) = match held {
			Some(held) => held,
			None => (
				self.host.enliven(&self.entrance_uri).await.unwrap(),
				Some(self.entrance_uri.clone()),
			),
		};
		self.owner.import(coordinate, reference, uri).await.unwrap();
		self.owner.replace_workspace(intent).await.unwrap();
	}
	/// A second, different capability a recipe can name.
	pub(super) async fn another(&self) -> (Ref, Option<String>) {
		(
			self.host.enliven(&self.manager_uri).await.unwrap(),
			Some(self.manager_uri.clone()),
		)
	}
	/// Close every session to the exporters, so each reference taken from them is stale.
	pub(super) async fn sever(&mut self) {
		for session in self.sessions.drain(..) {
			session.close(PendingWork::Cancel).await.unwrap();
		}
	}
	pub(super) async fn close(mut self) {
		self.owner.close().await.unwrap();
		self.attachment.close().await.unwrap();
		for session in self.sessions {
			session.close(PendingWork::Cancel).await.unwrap();
		}
		self.host.close(PendingWork::Cancel).await.unwrap();
		drop(self.owner);
		environment::close(&mut self.store).await;
		drop(self.store);
		self.exporter.close(PendingWork::Cancel).await.unwrap();
		self.other.close(PendingWork::Cancel).await.unwrap();
		self.database.remove();
	}
}
macro_rules! scenario {
	($name:ident, $body:expr) => {
		#[tokio::test]
		async fn $name() {
			tokio::task::LocalSet::new()
				.run_until(async {
					environment::within(20_000, $body)
						.await
						.expect("bounded progress")
				})
				.await;
		}
	};
}

impl Rig {
	/// Time out observation once the gate parks a write, so the effect settles
	/// unknown while its work stays retained.
	pub(super) fn observe_briefly(&self) {
		self.platform.deadline_ms.set(Some(100));
		self.platform.deadline_after_parking.replace(Some(self.gate.clone()));
	}
	pub(super) fn observe_fully(&self) {
		self.platform.deadline_ms.set(None);
		self.platform.deadline_after_parking.replace(None);
	}
	/// Resume retained work until it settles committed.
	pub(super) async fn finish(&self, id: &str) -> Argument {
		self.gate.open();
		self.observe_fully();
		loop {
			self.owner.resume_pending().unwrap();
			let status = finished(&self.host, &self.root, id, &self.root).await;
			if status.as_str() != Some("unknown") {
				return status;
			}
			environment::yield_turn().await;
		}
	}
}
pub(super) fn first_room(intent: &mut Intent) -> &mut session::workspace::Room {
	let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
		panic!("room row")
	};
	room
}
pub(super) fn manager() -> custody::FieldKey<custody::RoomControl> {
	coordinate(custody::Role::RoomControl, 9).key.retag()
}
