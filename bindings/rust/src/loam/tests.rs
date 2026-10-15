//! Consumer lifecycle scenarios. Zig's managed access engine decides admission.
//! These tests exercise projection, callback custody, worker progress and reopen.
use super::*;
#[cfg(feature = "tcp")]
mod capacity;
#[cfg(feature = "tcp")]
mod continuation;
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_continuations.rs"]
mod continuations;
mod engines;
#[cfg(feature = "tcp")]
mod volatile;
#[cfg(feature = "tcp")]
use crate::ListenerIdentity;
#[cfg(feature = "tcp")]
use crate::Result as HostResult;
#[cfg(feature = "tcp")]
use crate::Session;
use crate::{Argument, PendingWork};
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_context.rs"]
mod context;
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_dependencies.rs"]
mod dependencies;
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_fields.rs"]
mod fields;
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_inventory.rs"]
mod inventory;
#[cfg(feature = "tcp")]
#[path = "../../../proofs/_support/loam_management.rs"]
mod management;

const SCHEMA: Schema = Schema {
	id: 7,
	version: 1,
	max_payload: 256,
	max_edges: 8,
};

#[test]
fn schema_size_query_counts_payload_prefixes_and_refuses_overflow() {
	let nine = Schema {
		max_payload: 9,
		..SCHEMA
	}
	.encoded_size_bound()
	.unwrap();
	let ten = Schema {
		max_payload: 10,
		..SCHEMA
	}
	.encoded_size_bound()
	.unwrap();
	assert_eq!(ten - nine, 2);
	assert!(
		Schema {
			max_payload: usize::MAX,
			..SCHEMA
		}
		.encoded_size_bound()
		.is_err()
	);
	assert!(
		Schema {
			max_edges: usize::MAX,
			..SCHEMA
		}
		.encoded_size_bound()
		.is_err()
	);
}
#[cfg(feature = "tcp")]
#[test]
fn reference_sizing_projects_owned_declarations_and_checked_refusal() {
	fields::sizing();
}

struct Text;
impl Content for Text {
	fn requirement(&self, input: super::Invocation<'_>) -> Result<Requirement> {
		let verb = input.verb;
		Requirement::new(
			&[if matches!(verb, "get" | "context" | "field" | "dependent") {
				10
			} else {
				20
			}],
			&[],
		)
	}
	fn references(&self, input: super::Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		let verb = input.verb;
		let args = input.args;
		#[cfg(feature = "tcp")]
		return fields::requests(verb, args);
		#[cfg(not(feature = "tcp"))]
		{
			let _ = (verb, args);
			Ok(Vec::new())
		}
	}
	fn dependent_requirement(&self, input: super::Invocation<'_>) -> Result<Requirement> {
		let verb = input.verb;
		if verb != "get" && verb != "context" {
			return Err(invalid("unsupported dependent method"));
		}
		self.requirement(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: super::Invocation<'_>) -> Result<Argument> {
		let payload = input.payload;
		let verb = input.verb;
		let args = input.args;
		#[cfg(feature = "tcp")]
		if verb == "context" {
			return Ok(context::reply(input));
		}
		#[cfg(feature = "tcp")]
		if fields::handles(verb) {
			return fields::invoke(call, verb, args);
		}
		match verb {
			"panic" => panic!("application panic stays inside Rust"),
			"get" => Ok(Argument::List(vec![Argument::Bytes(payload.to_vec())])),
			"set" => {
				let next = args
					.first()
					.and_then(Argument::as_bytes)
					.ok_or_else(|| invalid("expected bytes"))?;
				call.replace(next)?;
				Ok(Argument::Bytes(next.to_vec()))
			}
			_ => Err(invalid("unknown method")),
		}
	}
}
fn registration() -> Registration {
	let registration = Registration {
		graph: None,
		schema: SCHEMA.id,
		version: SCHEMA.version,
		methods: vec![
			Method {
				verb: "get".to_owned(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "panic".to_owned(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "set".to_owned(),
				retry: Retry::Receipt,
			},
		],
		content: Box::new(Text),
	};
	#[cfg(feature = "tcp")]
	{
		let mut registration = registration;
		registration.methods.extend(fields::methods());
		registration.methods.push(Method {
			verb: "context".into(),
			retry: Retry::ReadOnly,
		});
		registration
	}
	#[cfg(not(feature = "tcp"))]
	registration
}
type EngineFn<E> = fn(&std::path::Path, OpenMode, usize) -> E;
fn lmdb_engine(path: &std::path::Path, mode: OpenMode, bytes: usize) -> Lmdb {
	Lmdb {
		path: path.to_owned(),
		identity: [3; 16],
		mode,
		map_bytes: bytes,
	}
}
fn sqlite_engine(path: &std::path::Path, mode: OpenMode, bytes: usize) -> Sqlite {
	Sqlite {
		path: path.to_owned(),
		identity: [3; 16],
		mode,
		capacity_bytes: bytes,
	}
}
fn volatile_engine(_path: &std::path::Path, _mode: OpenMode, bytes: usize) -> Volatile {
	Volatile {
		identity: [3; 16],
		capacity_bytes: bytes,
	}
}
struct Directory(std::path::PathBuf);
impl Directory {
	fn new() -> Self {
		let mut nonce = [0u8; 8];
		getrandom::fill(&mut nonce).unwrap();
		let path = std::env::temp_dir().join(format!("glowcap-loam-{:x}", u64::from_be_bytes(nonce)));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Directory {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}

#[cfg(feature = "tcp")]
async fn create_share_edit_restart_and_cold_reopen<E: Engine>(engine: EngineFn<E>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), async {
				let directory = Directory::new();
				let policy = dependencies::descriptor();
				let mut store = Store::open(
					engine(&directory.0, OpenMode::Create, 256 * 1024 * 1024),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store.create_resource(&policy, SCHEMA, 1, b"initial", 2).unwrap();
				let saved_resource = resource.encode();
				let host = Host::from_seed([8; 32]).unwrap();
				let mut attachment = store.attach(&host, vec![registration()]).unwrap();
				attachment.start_live(None, 2).unwrap();
				assert!(attachment.live_marker().unwrap().is_none());
				let (use_ref, control) = attachment.restore(resource).unwrap();
				let (use_copy, control_copy) = (use_ref.clone(), control.clone());
				host.publish("resource", move || {
					let pair = vec![
						Argument::Reference(use_copy.clone()),
						Argument::Reference(control_copy.clone()),
					];
					Box::new(move |_, _| Ok(Argument::List(pair.clone())))
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let catalog = client.fetch("resource").await.unwrap();
				let pair = client.send(&catalog, "open", &[]).await.unwrap();
				let pair = pair.as_list().unwrap();
				let root = Ref::try_from(&pair[0]).unwrap();
				let management = Ref::try_from(&pair[1]).unwrap();
				assert!(client.send(&root, "panic", &[]).await.is_err());
				let failures = host.take_failures().unwrap();
				assert_eq!(failures.len(), 1);
				assert_eq!(failures[0].operation, "loam-content.invoke-panic");
				assert_eq!(failures[0].primary_message, "application panic stays inside Rust");
				assert_text(&client, &root, b"initial").await;
				let terms = policy.value(&[10, 20], &[]).unwrap();
				let shared = client
					.send(&root, "derive", &terms.derive_arguments(1, Scope::Object, 0))
					.await
					.unwrap();
				let shared = Ref::try_from(&shared).unwrap();
				let swiss = client
					.send(&shared, "durable-name", &[])
					.await
					.unwrap()
					.as_str()
					.unwrap()
					.to_owned();
				let read_only = client
					.send(
						&root,
						"derive",
						&policy.value(&[10], &[]).unwrap().derive_arguments(2, Scope::Object, 0),
					)
					.await
					.unwrap();
				let read_only = Ref::try_from(&read_only).unwrap();
				assert_text(&client, &read_only, b"initial").await;
				let (field_name, initial_context) =
					fields::exercise(&client, &root, &read_only, &shared, &management, &catalog).await;
				fields::live(&client, &root, &catalog).await;
				let live_marker = attachment.live_marker().unwrap().unwrap();
				let live_incarnation = attachment.live_incarnation().unwrap().unwrap();
				assert!(
					client
						.send(
							&read_only,
							"mutate",
							&[
								Argument::Integer(1),
								Argument::String("set".to_owned()),
								Argument::Bytes(b"denied".to_vec())
							]
						)
						.await
						.is_err()
				);
				let request = vec![
					Argument::Integer(1),
					Argument::String("set".to_owned()),
					Argument::Bytes(b"edited".to_vec()),
				];
				assert_eq!(
					client.send(&shared, "mutate", &request).await.unwrap().as_bytes(),
					Some(b"edited".as_slice())
				);
				assert_eq!(
					client.send(&shared, "mutate", &request).await.unwrap().as_bytes(),
					Some(b"edited".as_slice()),
					"exact receipt replay"
				);
				assert!(
					client
						.send(
							&shared,
							"mutate",
							&[
								Argument::Integer(1),
								Argument::String("set".to_owned()),
								Argument::Bytes(b"conflict".to_vec())
							]
						)
						.await
						.is_err()
				);
				client
					.send(
						&management,
						"pause",
						&[Argument::Bytes(
							crate::loam::control_revision(&client.host(), &management)
								.await
								.unwrap()
								.to_be_bytes()
								.to_vec(),
						)],
					)
					.await
					.unwrap();
				assert!(client.send(&shared, "get", &[]).await.is_err());
				client
					.send(
						&management,
						"resume",
						&[Argument::Bytes(
							crate::loam::control_revision(&client.host(), &management)
								.await
								.unwrap()
								.to_be_bytes()
								.to_vec(),
						)],
					)
					.await
					.unwrap();
				assert_text(&client, &shared, b"edited").await;
				let inventory_name = inventory::exercise(&client, &management, &policy).await;
				let managed_name = management::exercise(&client, &root, &management, &policy).await;
				dependencies::exercise(&client, &root, &management, &policy).await;
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(attachment);
				drop(use_ref);
				drop(control);
				store.close().unwrap();
				drop(store);

				let mut store = Store::open(
					engine(&directory.0, OpenMode::Open, 256 * 1024 * 1024),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let attachment = store.attach(&host, vec![registration()]).unwrap();
				attachment.start_live(Some(live_marker), 2).unwrap();
				let (restored, restored_control) = attachment.restore(Resource::decode(saved_resource)).unwrap();
				host.publish("control", move || {
					let control = restored_control.clone();
					Box::new(move |_, _| Ok(Argument::Reference(control.clone())))
				})
				.unwrap();
				host.publish("root", move || {
					let root = restored.clone();
					Box::new(move |_, _| Ok(Argument::Reference(root.clone())))
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let reopened = client.fetch(&swiss).await.unwrap();
				assert_text(&client, &reopened, b"edited").await;
				assert_eq!(
					client.send(&reopened, "mutate", &request).await.unwrap().as_bytes(),
					Some(b"edited".as_slice()),
					"durable mutation receipt survives restart"
				);
				let entry = client.fetch("root").await.unwrap();
				let root = client.send(&entry, "open", &[]).await.unwrap();
				let entry = client.fetch("control").await.unwrap();
				let control = client.send(&entry, "open", &[]).await.unwrap();
				dependencies::exercise(
					&client,
					&Ref::try_from(&root).unwrap(),
					&Ref::try_from(&control).unwrap(),
					&policy,
				)
				.await;
				fields::reopen(&client, &Ref::try_from(&root).unwrap(), &field_name, &initial_context).await;
				fields::expired_live(&client, &Ref::try_from(&root).unwrap()).await;
				assert_eq!(attachment.live_marker().unwrap(), Some(live_marker));
				assert_ne!(attachment.live_incarnation().unwrap(), Some(live_incarnation));
				inventory::reopen(&client, &Ref::try_from(&control).unwrap(), &policy, &inventory_name).await;
				management::reopen(&client, &Ref::try_from(&root).unwrap(), &policy, &managed_name).await;
				assert_text(&client, &reopened, b"edited").await;
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				// Host close retires its idle Loam borrows before storage release.
				host.close(PendingWork::Cancel).await.unwrap();
				assert!(attachment.inner().is_err());
				store.close().unwrap();
				drop(attachment);
				store.close().unwrap();
			})
			.await
			.expect("lifecycle has a finite CapTP budget");
		})
		.await;
}
#[cfg(feature = "tcp")]
async fn assert_text(client: &crate::Session, target: &Ref, text: &[u8]) {
	let value = client.send(target, "get", &[]).await.unwrap();
	assert_eq!(value.as_list().unwrap()[0].as_bytes(), Some(text));
}

#[cfg(feature = "tcp")]
async fn connect(
	host: &Host,
) -> (
	crate::Session,
	crate::tcp::Server,
	crate::Runtime,
	tokio::task::JoinHandle<Result<()>>,
) {
	let server = crate::tcp::listen(
		"127.0.0.1",
		0,
		crate::tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = crate::Runtime::open(crate::RuntimeConfig::providers([crate::tcp::provider(
		Default::default(),
	)]))
	.await
	.unwrap();
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(
		runtime.connect(&locator, crate::ConnectOptions::default()),
		server.accept()
	);
	let serving = tokio::task::spawn_local(async move { accepted.unwrap().serve().await });
	(client.unwrap(), server, runtime, serving)
}

struct DropProbe(Rc<Cell<usize>>);
impl Drop for DropProbe {
	fn drop(&mut self) {
		self.0.set(self.0.get() + 1);
	}
}
impl Content for DropProbe {
	fn requirement(&self, input: super::Invocation<'_>) -> Result<Requirement> {
		Text.requirement(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: super::Invocation<'_>) -> Result<Argument> {
		Text.invoke(call, input)
	}
}
async fn refused_registration_and_host_close_release_callback_custody<E: Engine>(engine: EngineFn<E>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			let directory = Directory::new();
			let mut store = Store::open(
				engine(&directory.0, OpenMode::Create, 256 * 1024 * 1024),
				&[SCHEMA],
				Limits::default(),
			)
			.unwrap();
			let host = Host::from_seed([8; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let mut invalid_registration = registration();
			invalid_registration.content = Box::new(DropProbe(Rc::clone(&drops)));
			invalid_registration.methods.push(Method {
				verb: "get".to_owned(),
				retry: Retry::ReadOnly,
			});
			assert!(store.attach(&host, vec![invalid_registration]).is_err());
			assert_eq!(
				drops.get(),
				1,
				"a refused registration retains no callback or Host borrow"
			);
			let mut valid = registration();
			valid.content = Box::new(DropProbe(Rc::clone(&drops)));
			let mut attachment = store.attach(&host, vec![valid]).unwrap();
			assert_eq!(store.close().unwrap_err().code(), crate::sys::WOULD_BLOCK);
			assert_eq!(drops.get(), 1);
			host.close(PendingWork::Cancel).await.unwrap();
			assert_eq!(drops.get(), 2, "Host close ends storage use before dropping contexts");
			store.close().unwrap();
			attachment.close().await.unwrap();
			attachment.close().await.unwrap();
			drop(attachment);
			assert_eq!(drops.get(), 2);
		})
		.await;
}
fn physical_map_budget_refuses_writes_without_losing_the_store<E: Engine>(engine: EngineFn<E>) {
	let directory = Directory::new();
	let schema = Schema {
		max_payload: 32 * 1024,
		..SCHEMA
	};
	let policy = Policy::new([5; 16], &[10, 20], &[]).unwrap();
	let mut store = Store::open(
		engine(&directory.0, OpenMode::Create, 1024 * 1024),
		&[schema],
		Limits::default(),
	)
	.unwrap();
	let payload = vec![0u8; schema.max_payload];
	let mut created = 0;
	let failure = loop {
		match store.create_resource(&policy, schema, 1, &payload, 0) {
			Ok(_) => {
				created += 1;
				assert!(
					created < 64,
					"the explicit 1 MiB budget must refuse before 2 MiB of payload"
				);
			}
			Err(error) => break error,
		}
	};
	assert!(created > 0);
	assert_eq!(failure.code(), UNCHANGED);
	assert!(failure.message().unwrap().contains("StorageCapacity"));
	store.close().unwrap();
	let mut reopened = Store::open(
		engine(&directory.0, OpenMode::Open, 4 * 1024 * 1024),
		&[schema],
		Limits::default(),
	)
	.unwrap();
	reopened.create_resource(&policy, schema, 1, &payload, 0).unwrap();
	reopened.close().unwrap();
}

fn collect_runs_bounded_steps_until_the_cycle_ends<E: Engine>(engine: EngineFn<E>) {
	let directory = Directory::new();
	let policy = Policy::new([5; 16], &[10, 20], &[]).unwrap();
	let store = Store::open(
		engine(&directory.0, OpenMode::Create, 64 * 1024 * 1024),
		&[SCHEMA],
		Limits::default(),
	)
	.unwrap();
	for _ in 0..2 {
		store.create_resource(&policy, SCHEMA, 1, b"payload", 0).unwrap();
	}
	let mut steps = 0;
	while store.collect(2).unwrap() {
		steps += 1;
		assert!(steps < 10_000, "collection must end within a bounded number of steps");
	}
}

fn collect_refuses_while_a_creation_is_staged_and_leaves_it_intact<E: Engine>(engine: EngineFn<E>) {
	let directory = Directory::new();
	let policy = Policy::new([5; 16], &[10, 20], &[]).unwrap();
	let store = Store::open(
		engine(&directory.0, OpenMode::Create, 64 * 1024 * 1024),
		&[SCHEMA],
		Limits::default(),
	)
	.unwrap();
	let staged = store
		.stage_resource(&policy, SCHEMA, 1, b"payload", 0, [9; 16])
		.unwrap();
	assert_eq!(
		store.collect(1).unwrap_err().code(),
		crate::sys::WOULD_BLOCK,
		"a staged creation owns the store's batch"
	);
	staged.commit().unwrap();
}

#[test]
fn policy_keys_and_bounds_use_the_shared_algebra() {
	let policy = Policy::new([5; 16], &[10, 20], &[(30, Operator::UpperBound)]).unwrap();
	assert!(policy.value(&[10], &[(30, 8)]).is_ok());
	assert!(policy.value(&[99], &[]).is_err());
	assert!(policy.value(&[10, 10], &[]).is_err());
	assert!(policy.value(&[10], &[(99, 8)]).is_err());
	assert!(Policy::new([5; 16], &[10, 10], &[]).is_err());
	let dependent = Policy::with_dependencies([5; 16], &[10, 20], &[], &[(20, 10)]).unwrap();
	assert!(dependent.value(&[20], &[]).is_err());
	assert!(dependent.value(&[10, 20], &[]).is_ok());
	assert!(Policy::with_dependencies([5; 16], &[10, 20], &[], &[(20, 20)]).is_err());
	assert!(Policy::with_dependencies([5; 16], &[10, 20], &[], &[(20, 99)]).is_err());
	assert!(Policy::with_dependencies([5; 16], &[10, 20], &[], &[(20, 10), (20, 10)]).is_err());
}
