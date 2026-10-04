//! The browser projects Loam lifecycle and custody. Zig owns managed admission
//! and transaction outcomes; Chromium owns IndexedDB scheduling and Web Locks.
use glowcap::loam::{
	Call, Content, ControlPowers, Limits, Method, Policy, ReferenceRequest, Registration, Requirement, Resource, Retry,
	Schema, Store, refusal,
};
use glowcap::{Argument, Host, Locator, PendingWork, Ref, Result as HostResult, Session};
use std::{
	cell::Cell,
	future::Future,
	rc::Rc,
	task::{Context, Waker},
	time::Duration,
};
use wasm_bindgen::prelude::*;
#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(js_namespace = globalThis, js_name = blockLoamStorage)]
	fn block_storage() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = unblockLoamStorage)]
	fn unblock_storage();
	#[wasm_bindgen(js_namespace = globalThis, js_name = refuseLoamWrite)]
	fn refuse_storage();
}
#[path = "../../../_support/loam_dependencies.rs"]
mod dependencies;
#[path = "../../../_support/loam_fields.rs"]
mod fields;
#[path = "../../../_support/loam_management.rs"]
mod management;
const NAME: &str = "glowcap-loam-browser-proof";
const SCHEMA: Schema = Schema {
	id: 7,
	version: 1,
	max_payload: 256,
	max_edges: 8,
};
struct Text(Rc<Cell<usize>>);
impl Drop for Text {
	fn drop(&mut self) {
		self.0.set(self.0.get() + 1);
	}
}
impl Content for Text {
	fn requirement(&self, _: &[u8], verb: &str, _: &[Argument]) -> glowcap::Result<Requirement> {
		Requirement::new(
			&[if matches!(verb, "get" | "field" | "dependent") {
				10
			} else {
				20
			}],
			&[],
		)
	}
	fn references(
		&self,
		_: &[u8],
		_: usize,
		verb: &str,
		args: &[Argument],
	) -> glowcap::Result<Vec<glowcap::loam::ReferenceRequest>> {
		fields::requests(verb, args)
	}
	fn dependent_requirement(&self, payload: &[u8], verb: &str, args: &[Argument]) -> glowcap::Result<Requirement> {
		if verb != "get" {
			return Err(refusal("unsupported dependent method"));
		}
		self.requirement(payload, verb, args)
	}
	fn invoke(&self, call: &mut Call<'_>, payload: &[u8], verb: &str, args: &[Argument]) -> glowcap::Result<Argument> {
		if fields::handles(verb) {
			return fields::invoke(call, verb, args);
		}
		if verb == "get" {
			return Ok(Argument::List(vec![Argument::Bytes(payload.to_vec())]));
		}
		let next = args[0].as_bytes().unwrap();
		call.replace(next)?;
		Ok(Argument::Bytes(next.to_vec()))
	}
}
fn registration(drops: &Rc<Cell<usize>>) -> Registration {
	let mut registration = Registration {
		schema: 7,
		version: 1,
		methods: vec![
			Method {
				verb: "get".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "set".into(),
				retry: Retry::Receipt,
			},
		],
		content: Box::new(Text(Rc::clone(drops))),
	};
	registration.methods.extend(fields::methods());
	registration
}
fn policy() -> Policy {
	Policy::with_dependencies([5; 16], &[10, 20], &[], &[(20, 10)]).unwrap()
}
fn message(error: impl core::fmt::Display) -> JsValue {
	JsValue::from_str(&error.to_string())
}
async fn pair(server: &Host) -> (Host, Session, Session) {
	let caller = Host::from_seed([9; 32]).unwrap();
	let (left, right) = tokio::io::duplex(4096);
	let locator = Locator::bare("tcp", "127.0.0.1:9000");
	let budget = Some(Duration::from_secs(2));
	let (dialed, accepted) = tokio::join!(
		Session::dial_over(&caller, &locator, left, budget),
		Session::accept_over(server, "tcp", "127.0.0.1:9000", "127.0.0.1:9000", right, budget)
	);
	(caller, dialed.unwrap(), accepted.unwrap())
}
async fn text(session: &Session, reference: &Ref, expected: &[u8]) {
	let value = session.send(reference, "get", &[]).await.unwrap();
	assert_eq!(value.as_list().unwrap()[0].as_bytes(), Some(expected));
}
fn mutation() -> Vec<Argument> {
	vec![
		Argument::Integer(1),
		Argument::String("set".into()),
		Argument::Bytes(b"edited".to_vec()),
	]
}

#[wasm_bindgen]
pub async fn create() -> Result<String, JsValue> {
	tokio::task::LocalSet::new().run_until(async {
		let mut store = Store::open(NAME, [3; 16], true, &[SCHEMA], Limits::default()).await.map_err(message)?;
		assert!(Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default()).await.is_err(), "another tab/owner cannot steal the Web Lock");
        let resource = store.create_resource(&policy(), SCHEMA, 1, b"initial", 2).await.map_err(message)?;
		let host = Host::from_seed([8; 32]).unwrap();
		let drops = Rc::new(Cell::new(0));
		let mut attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
		let (root, control) = attachment.restore(resource).await.unwrap();
		assert!(store.close().is_err(), "live attachment preserves Store and database custody");
		assert_eq!(drops.get(), 0);
		let (use_copy, control_copy) = (root.clone(), control.clone());
        host.publish_giftable("resource", move || {
			let pair = vec![Argument::Reference(use_copy.clone()), Argument::Reference(control_copy.clone())];
			Box::new(move |_, _| Ok(Argument::List(pair.clone())))
        }).unwrap();
        host.publish_giftable("echo", || Box::new(|_, _| Ok(Argument::String("responsive".into())))).unwrap();
		let (caller, session, accepted) = pair(&host).await;
		let entry = session.fetch("resource").await.unwrap();
		let values = session.send(&entry, "open", &[]).await.unwrap();
		let values = values.as_list().unwrap();
		let use_ref = Ref::try_from(&values[0]).unwrap();
		let management = Ref::try_from(&values[1]).unwrap();
		text(&session, &use_ref, b"initial").await;
		let shared = session.send(&use_ref, "derive", &policy().value(&[10, 20], &[]).unwrap().derive_arguments(1, 0)).await.unwrap();
		let shared = Ref::try_from(&shared).unwrap();
		let swiss = session.send(&shared, "durable-name", &[]).await.unwrap().as_str().unwrap().to_owned();
		let limited = session.send(&use_ref, "derive", &policy().value(&[10], &[]).unwrap().derive_arguments(2, 0)).await.unwrap();
		let limited = Ref::try_from(&limited).unwrap();
		let field_name = fields::exercise(&session, &use_ref, &limited, &shared, &management, &entry).await;
		assert!(session.send(&limited, "mutate", &mutation()).await.is_err());
		assert_eq!(session.send(&shared, "mutate", &mutation()).await.unwrap().as_bytes(), Some(b"edited".as_slice()));
		assert_eq!(session.send(&shared, "mutate", &mutation()).await.unwrap().as_bytes(), Some(b"edited".as_slice()));
		session.send(&management, "pause", &[]).await.unwrap();
		assert!(session.send(&shared, "get", &[]).await.is_err());
        session.send(&management, "resume", &[]).await.unwrap();
        text(&session, &shared, b"edited").await;
        let managed_name = management::exercise(&session, &use_ref, &management, &policy()).await;
        dependencies::exercise(&session, &use_ref, &management, &policy()).await;
        let echo = session.fetch("echo").await.unwrap();
        wasm_bindgen_futures::JsFuture::from(block_storage()).await.unwrap();
        let mut next = mutation();
        next[0] = Argument::Integer(2);
        let editing = session.send(&shared, "mutate", &next);
        let unrelated = async {
            assert_eq!(session.send(&echo, "echo", &[]).await.unwrap().as_str(), Some("responsive"));
            unblock_storage();
        };
        let (edited, ()) = tokio::join!(editing, unrelated);
        assert_eq!(edited.unwrap().as_bytes(), Some(b"edited".as_slice()));
        refuse_storage();
        next[0] = Argument::Integer(3);
        assert!(session.send(&shared, "mutate", &next).await.is_err());
        assert_eq!(session.send(&echo, "echo", &[]).await.unwrap().as_str(), Some("responsive"));
        assert_eq!(glowcap::take_runtime_failures().len(), 1, "the owning mutation refuses while its physical cause remains observable");
        assert_eq!(session.send(&shared, "mutate", &next).await.unwrap().as_bytes(), Some(b"edited".as_slice()), "known abort preserves receipt retry");
		session.close(PendingWork::Cancel).await.unwrap();
		accepted.close(PendingWork::Cancel).await.unwrap();
		caller.close(PendingWork::Cancel).await.unwrap();
		attachment.close().await.unwrap();
		assert_eq!(drops.get(), 1, "detach ends callback custody exactly once");
		host.close(PendingWork::Cancel).await.unwrap();
		let costs = store.storage_statistics();
        assert!(costs.peak_snapshot_bytes + costs.peak_overlay_bytes <= 8 * 1024 * 1024);
        store.close().unwrap();
        assert!(glowcap::take_runtime_failures().is_empty());
		Ok(serde_json::json!({ "resource": resource.encode().to_vec(), "swiss": swiss, "managed": managed_name, "field": field_name, "costs": { "transactions": costs.transactions, "planning_passes": costs.planning_passes, "database_rows": costs.database_rows, "copied_bytes": costs.copied_bytes, "peak_snapshot_bytes": costs.peak_snapshot_bytes, "peak_overlay_bytes": costs.peak_overlay_bytes } }).to_string())
	}).await
}

#[wasm_bindgen]
pub async fn reopen(saved: &str) -> Result<(), JsValue> {
	let saved: serde_json::Value = serde_json::from_str(saved).map_err(message)?;
	let bytes: Vec<u8> = saved["resource"]
		.as_array()
		.unwrap()
		.iter()
		.map(|v| v.as_u64().unwrap() as u8)
		.collect();
	let resource = Resource::decode(bytes.try_into().unwrap());
	let swiss = saved["swiss"].as_str().unwrap().to_owned();
	tokio::task::LocalSet::new()
		.run_until(async {
			assert!(
				Store::open(NAME, [3; 16], true, &[SCHEMA], Limits::default())
					.await
					.is_err(),
				"creation cannot reset committed authority"
			);
			assert!(
				Store::open(NAME, [4; 16], false, &[SCHEMA], Limits::default())
					.await
					.is_err(),
				"identity mismatch cannot recreate storage"
			);
			let mut store = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.map_err(message)?;
			let host = Host::from_seed([8; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
			// The durable name resolves cold before any explicit resource restoration.
			let (caller, session, accepted) = pair(&host).await;
			let shared = session.fetch(&swiss).await.unwrap();
			text(&session, &shared, b"edited").await;
			assert_eq!(
				session.send(&shared, "mutate", &mutation()).await.unwrap().as_bytes(),
				Some(b"edited".as_slice()),
				"receipt survives actual page reload"
			);
			let (rooted, rooted_control) = attachment.restore(resource).await.unwrap();
			host.publish_giftable("control", move || {
				let control = rooted_control.clone();
				Box::new(move |_, _| Ok(Argument::Reference(control.clone())))
			})
			.unwrap();
			host.publish_giftable("root", move || {
				let root = rooted.clone();
				Box::new(move |_, _| Ok(Argument::Reference(root.clone())))
			})
			.unwrap();
			let entry = session.fetch("root").await.unwrap();
			let root = session.send(&entry, "open", &[]).await.unwrap();
			let entry = session.fetch("control").await.unwrap();
			let control = session.send(&entry, "open", &[]).await.unwrap();
			dependencies::exercise(
				&session,
				&Ref::try_from(&root).unwrap(),
				&Ref::try_from(&control).unwrap(),
				&policy(),
			)
			.await;
			fields::reopen(
				&session,
				&Ref::try_from(&root).unwrap(),
				saved["field"].as_str().unwrap(),
			)
			.await;
			management::reopen(
				&session,
				&Ref::try_from(&root).unwrap(),
				&policy(),
				saved["managed"].as_str().unwrap(),
			)
			.await;
			text(&session, &shared, b"edited").await;
			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			caller.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			assert_eq!(drops.get(), 1);
			store.close().unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(())
		})
		.await
}

#[wasm_bindgen]
pub async fn cancelled_creation() -> Result<(), JsValue> {
	let mut store = Store::open("glowcap-loam-cancel-proof", [3; 16], true, &[SCHEMA], Limits::default())
		.await
		.map_err(message)?;
	let policy = policy();
	let mut creation = Box::pin(store.create_resource(&policy, SCHEMA, 1, b"retained", 2));
	assert!(
		creation
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	drop(creation);
	let resource = store.recover_creation().await.map_err(message)?;
	assert_ne!(resource.encode(), [0; 99]);
	store.close().unwrap();
	Ok(())
}

#[wasm_bindgen]
pub async fn aborted_creation() -> Result<(), JsValue> {
	let mut store = Store::open("glowcap-loam-abort-proof", [3; 16], false, &[SCHEMA], Limits::default())
		.await
		.map_err(message)?;
	assert!(
		store
			.create_resource(&policy(), SCHEMA, 1, b"refused", 2)
			.await
			.is_err()
	);
	assert!(
		store
			.recover_creation()
			.await
			.is_err_and(|error| error.code() == glowcap::loam::UNCHANGED)
	);
	store.close().unwrap();
	Ok(())
}

#[wasm_bindgen]
pub async fn empty_store() -> Result<(), JsValue> {
	let mut store = Store::open("glowcap-loam-abort-proof", [3; 16], true, &[SCHEMA], Limits::default())
		.await
		.map_err(message)?;
	store.close().unwrap();
	Ok(())
}
