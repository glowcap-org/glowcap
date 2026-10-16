//! One session codec graph trace, run through each disk engine and browser IndexedDB.
mod content;
pub(crate) mod graph;
mod profile;
#[cfg(target_arch = "wasm32")]
mod recovery;
#[cfg(all(test, not(target_arch = "wasm32")))]
use glowcap::loam::OpenMode;
use glowcap::{
	Argument, Host, Locator, PendingWork, Ref, Session,
	loam::{Policy, Resource, Schema, Store},
};
pub use profile::limits;
pub(crate) use profile::limits_for;
pub(crate) use profile::limits_for_input;
use rooms_application::content::session::{self, records};
use std::{cell::Cell, rc::Rc, time::Duration};

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
extern "C" {
	#[wasm_bindgen(js_namespace = globalThis, js_name = refuseRoomsGraphWrite)]
	fn refuse_write(after: usize);
}

pub fn schemas() -> Vec<Schema> {
	records::SCHEMAS
		.iter()
		.map(|schema| Schema {
			id: schema.id,
			version: schema.version,
			max_payload: schema.max_payload,
			max_edges: schema.max_edges,
		})
		.collect()
}
async fn pair(server: &Host) -> (Host, Session, Session) {
	let caller = Host::from_seed([79; 32]).unwrap();
	let (left, right) = tokio::io::duplex(4096);
	let locator = Locator::bare("tcp", "127.0.0.1:9000");
	let budget = Some(Duration::from_secs(2));
	let (dialed, accepted) = tokio::join!(
		Session::dial_over(&caller, &locator, left, budget),
		Session::accept_over(server, "tcp", "127.0.0.1:9000", "127.0.0.1:9000", right, budget)
	);
	(caller, dialed.unwrap(), accepted.unwrap())
}
pub async fn create(store: &Store) -> [u8; 99] {
	let policy = Policy::new([83; 16], &[10, 20], &[]).unwrap();
	let schema = schemas()[0];
	#[cfg(not(target_arch = "wasm32"))]
	let resource = store
		.create_resource(&policy, schema, session::KIND, &content::initial(), 2)
		.unwrap();
	#[cfg(target_arch = "wasm32")]
	let resource = store
		.create_resource(&policy, schema, session::KIND, &content::initial(), 2)
		.await
		.unwrap();
	exercise(store, resource, true).await;
	resource.encode()
}
pub async fn reopen(store: &Store, resource: [u8; 99]) {
	exercise(store, Resource::decode(resource), false).await;
}
async fn exercise(store: &Store, resource: Resource, writing: bool) {
	let host = Host::from_seed([78; 32]).unwrap();
	let invocations = Rc::new(Cell::new(0));
	let mut attachment = store
		.attach(&host, vec![content::registration(Rc::clone(&invocations))])
		.unwrap();
	#[cfg(not(target_arch = "wasm32"))]
	let (use_ref, control) = attachment.restore(resource).unwrap();
	#[cfg(target_arch = "wasm32")]
	let (use_ref, control) = attachment.restore(resource).await.unwrap();
	host.publish("session", move || {
		let pair = Argument::List(vec![
			Argument::Reference(use_ref.clone()),
			Argument::Reference(control.clone()),
		]);
		Box::new(move |_, _| Ok(pair.clone()))
	})
	.unwrap();
	let (caller, client, server) = pair(&host).await;
	let catalog = client.fetch("session").await.unwrap();
	let pair = client.send(&catalog, "open", &[]).await.unwrap();
	let pair = pair.as_list().unwrap();
	let root = Ref::try_from(&pair[0]).unwrap();
	let control = Ref::try_from(&pair[1]).unwrap();
	let mutation = vec![
		Argument::Integer(1),
		Argument::String("write".into()),
		Argument::Reference(control.clone()),
		Argument::Integer(1),
	];
	if writing {
		let reply = client.send(&root, "mutate", &mutation).await.unwrap();
		assert!(
			reply.as_i64().unwrap() > limits().max_leases as i64,
			"graph exceeds what the Store can hold at once"
		);
		assert_eq!(invocations.get(), 1);
		let mut replacement = mutation.clone();
		replacement[0] = Argument::Integer(2);
		replacement[3] = Argument::Integer(2);
		#[cfg(target_arch = "wasm32")]
		{
			// Pages and root reach IndexedDB before the first managed row
			// refuses. The transaction must preserve the complete old graph.
			refuse_write(reply.as_i64().unwrap() as usize + 2);
			let failure = client.send(&root, "mutate", &replacement).await.unwrap_err();
			assert_eq!(failure.kind(), glowcap::ErrorKind::Broken);
			assert_eq!(failure.message(), Some("WriteNotCommitted"));
			assert_eq!(
				client.send(&root, "mutation-sequence", &[]).await.unwrap().as_i64(),
				Some(2)
			);
			let old = client.send(&root, "read", &[Argument::Integer(1)]).await.unwrap();
			assert_eq!(Ref::try_from(&old).unwrap(), control);
		}
		#[cfg(not(target_arch = "wasm32"))]
		client.send(&root, "mutate", &replacement).await.unwrap();
		#[cfg(target_arch = "wasm32")]
		recovery::replace(
			&client,
			&root,
			&control,
			&replacement,
			reply.as_i64().unwrap() as usize,
			&invocations,
		)
		.await;
		#[cfg(not(target_arch = "wasm32"))]
		let expected = 2;
		#[cfg(target_arch = "wasm32")]
		let expected = 6;
		assert_eq!(
			invocations.get(),
			expected,
			"complete replacement prepares old and new field populations"
		);
	}
	client.send(&root, "mutate", &mutation).await.unwrap();
	#[cfg(not(target_arch = "wasm32"))]
	let expected = 2;
	#[cfg(target_arch = "wasm32")]
	let expected = 6;
	assert_eq!(
		invocations.get(),
		usize::from(writing) * expected,
		"receipt replay does not invoke content, including after reopen"
	);
	let result = client.send(&root, "read", &[Argument::Integer(2)]).await.unwrap();
	let returned = Ref::try_from(&result).unwrap();
	assert_eq!(
		returned, control,
		"saved result retains the original capability identity"
	);
	client
		.send(
			&returned,
			"pause",
			&[Argument::Bytes(
				glowcap::loam::control_revision(&client.host(), &returned)
					.await
					.unwrap()
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	assert!(client.send(&root, "read", &[Argument::Integer(2)]).await.is_err());
	client
		.send(
			&control,
			"resume",
			&[Argument::Bytes(
				glowcap::loam::control_revision(&client.host(), &control)
					.await
					.unwrap()
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	assert_eq!(
		client.send(&root, "read", &[Argument::Integer(2)]).await.unwrap(),
		result
	);
	client.close(PendingWork::Cancel).await.unwrap();
	server.close(PendingWork::Cancel).await.unwrap();
	caller.close(PendingWork::Cancel).await.unwrap();
	attachment.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn session_graph_sqlite_commit_and_cold_reopen() {
	commit_and_cold_reopen(crate::disk::Disk::Sqlite).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn session_graph_lmdb_commit_and_cold_reopen() {
	commit_and_cold_reopen(crate::disk::Disk::Lmdb).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
async fn commit_and_cold_reopen(disk: crate::disk::Disk) {
	tokio::task::LocalSet::new()
		.run_until(async {
			let nonce = std::time::SystemTime::now()
				.duration_since(std::time::UNIX_EPOCH)
				.unwrap()
				.as_nanos();
			let path =
				std::env::temp_dir().join(format!("rooms-session-graph-{disk:?}-{}-{nonce:x}", std::process::id()));
			std::fs::create_dir(&path).unwrap();
			let mut store = disk
				.open(path.clone(), [81; 16], OpenMode::Create, &schemas(), limits())
				.unwrap();
			let resource = create(&store).await;
			store.close().unwrap();
			drop(store);
			let mut store = disk
				.open(path.clone(), [81; 16], OpenMode::Open, &schemas(), limits())
				.unwrap();
			reopen(&store, resource).await;
			store.close().unwrap();
			drop(store);
			std::fs::remove_dir_all(path).unwrap();
		})
		.await;
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn rooms_session_graph_create() -> Vec<u8> {
	tokio::task::LocalSet::new()
		.run_until(async {
			let mut store = Store::open("rooms-session-graph", [81; 16], true, &schemas(), limits())
				.await
				.unwrap();
			let resource = create(&store).await;
			store.close().await.unwrap();
			resource.to_vec()
		})
		.await
}
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn rooms_session_graph_reopen(resource: &[u8]) {
	tokio::task::LocalSet::new()
		.run_until(async {
			let resource = <[u8; 99]>::try_from(resource).unwrap();
			let mut store = Store::open("rooms-session-graph", [81; 16], false, &schemas(), limits())
				.await
				.unwrap();
			reopen(&store, resource).await;
			store.close().await.unwrap();
		})
		.await
}
