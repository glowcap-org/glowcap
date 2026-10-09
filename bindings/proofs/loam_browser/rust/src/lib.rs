//! The browser projects Loam lifecycle and custody. Zig owns managed admission
//! and transaction outcomes; Chromium owns IndexedDB scheduling and Web Locks.
use glowcap::loam::{
	Call, Content, ControlPowers, Delivery, EffectExecution, EffectResult, Graph, Invocation, InvocationBounds,
	KindRule, Limits, Method, PendingContinuation, Policy, ReferenceRequest, Registration, Requirement, Resource,
	Retry, Schema, StagingBounds, Store, UNCHANGED, ValueBounds, parse_control_revision, refusal,
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
	fn block_storage(observe_restore: bool) -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = unblockLoamStorage)]
	fn unblock_storage();
	#[wasm_bindgen(js_namespace = globalThis, js_name = waitLoamRestoreQueued)]
	fn wait_restore_queued() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = waitLoamRestoreRetired)]
	fn wait_restore_retired() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = refuseLoamWrite)]
	fn refuse_storage();
}
#[path = "../../../_support/loam_context.rs"]
mod context;
#[path = "../../../_support/loam_continuations.rs"]
mod continuations;
#[path = "../../../_support/loam_dependencies.rs"]
mod dependencies;
#[path = "../../../_support/loam_fields.rs"]
mod fields;
#[path = "../../../_support/loam_management.rs"]
mod management;

#[path = "../../../_support/loam_inventory.rs"]
mod inventory;
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
	fn requirement(&self, input: glowcap::loam::Invocation<'_>) -> glowcap::Result<Requirement> {
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
	fn references(
		&self,
		input: glowcap::loam::Invocation<'_>,
	) -> glowcap::Result<Vec<glowcap::loam::ReferenceRequest>> {
		let verb = input.verb;
		let args = input.args;
		fields::requests(verb, args)
	}
	fn dependent_requirement(&self, input: glowcap::loam::Invocation<'_>) -> glowcap::Result<Requirement> {
		let verb = input.verb;
		if verb != "get" && verb != "context" {
			return Err(refusal("unsupported dependent method"));
		}
		self.requirement(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: glowcap::loam::Invocation<'_>) -> glowcap::Result<Argument> {
		let payload = input.payload;
		let verb = input.verb;
		let args = input.args;
		if verb == "context" {
			return Ok(context::reply(input));
		}
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
		graph: None,
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
	registration.methods.push(Method {
		verb: "context".into(),
		retry: Retry::ReadOnly,
	});
	registration
}
fn policy() -> Policy {
	dependencies::descriptor()
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
		let continuation_state = Rc::new(continuations::State::default());
		let attachment = store.attach(&host, vec![continuations::wrap(registration(&drops), &continuation_state)]).unwrap();
		attachment.start_live(None, 2).unwrap();
		let (root, control) = attachment.restore(resource).await.unwrap();
		continuation_state.target.borrow_mut().replace(root.clone());
		assert!(store.close().await.is_err(), "live attachment preserves Store and database custody");
		assert_eq!(drops.get(), 0);
		let (use_copy, control_copy) = (root.clone(), control.clone());
        host.publish("resource", move || {
			let pair = vec![Argument::Reference(use_copy.clone()), Argument::Reference(control_copy.clone())];
			Box::new(move |_, _| Ok(Argument::List(pair.clone())))
        }).unwrap();
        host.publish("echo", || Box::new(|_, _| Ok(Argument::String("responsive".into())))).unwrap();
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
		let (field_name, initial_context) = fields::exercise(&session, &use_ref, &limited, &shared, &management, &entry).await;
		fields::live(&session, &use_ref, &entry).await;
		let live_marker = attachment.live_marker().unwrap().unwrap();
		assert!(session.send(&limited, "mutate", &mutation()).await.is_err());
		assert_eq!(session.send(&shared, "mutate", &mutation()).await.unwrap().as_bytes(), Some(b"edited".as_slice()));
		assert_eq!(session.send(&shared, "mutate", &mutation()).await.unwrap().as_bytes(), Some(b"edited".as_slice()));
		session.send(&management, "pause", &[Argument::Bytes(management::revision(&session, &management).await.to_be_bytes().to_vec())]).await.unwrap();
		assert!(session.send(&shared, "get", &[]).await.is_err());
        session.send(&management, "resume", &[Argument::Bytes(management::revision(&session, &management).await.to_be_bytes().to_vec())]).await.unwrap();
        text(&session, &shared, b"edited").await;
        let inventory_name = inventory::exercise(&session, &management, &policy()).await;
        let managed_name = management::exercise(&session, &use_ref, &management, &policy()).await;
        dependencies::exercise(&session, &use_ref, &management, &policy()).await;
        let echo = session.fetch("echo").await.unwrap();
        wasm_bindgen_futures::JsFuture::from(block_storage(false)).await.unwrap();
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
        let sequence = session.send(&use_ref, "mutation-sequence", &[]).await.unwrap().as_i64().unwrap();
        wasm_bindgen_futures::JsFuture::from(block_storage(false)).await.unwrap();
        let release_commit = async {
            continuation_state.wait_for_confirmation_park().await;
            unblock_storage();
        };
        tokio::join!(continuations::exercise(&session, &use_ref, &management, &continuation_state, sequence, true), release_commit);
        drop(attachment);
        assert_eq!(drops.get(), 1, "local callback Drop retires before another Host verb");
		session.close(PendingWork::Cancel).await.unwrap();
		accepted.close(PendingWork::Cancel).await.unwrap();
		caller.close(PendingWork::Cancel).await.unwrap();
		host.close(PendingWork::Cancel).await.unwrap();
		let costs = store.storage_statistics();
        assert!(costs.peak_input_bytes <= costs.input_capacity_bytes);
        assert!(costs.input_capacity_bytes < Limits::default().record_bytes + 1024);
        store.close().await.unwrap();
        assert!(glowcap::take_runtime_failures().is_empty());
		Ok(serde_json::json!({ "resource": resource.encode().to_vec(), "live_marker": live_marker.encode().to_vec(), "swiss": swiss, "managed": managed_name, "inventory": inventory_name, "field": field_name, "context": initial_context, "costs": { "transactions": costs.transactions, "planning_passes": costs.planning_passes, "database_rows": costs.database_rows, "emitted_writes": costs.emitted_writes, "copied_bytes": costs.copied_bytes, "peak_input_bytes": costs.peak_input_bytes, "input_capacity_bytes": costs.input_capacity_bytes, "max_transaction_write_bytes": costs.max_transaction_write_bytes } }).to_string())
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
			let marker: Vec<u8> = saved["live_marker"]
				.as_array()
				.unwrap()
				.iter()
				.map(|v| v.as_u64().unwrap() as u8)
				.collect();
			let marker = glowcap::loam::LiveMarker::decode(marker.try_into().unwrap());
			attachment.start_live(Some(marker), 2).unwrap();
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
			host.publish("control", move || {
				let control = rooted_control.clone();
				Box::new(move |_, _| Ok(Argument::Reference(control.clone())))
			})
			.unwrap();
			host.publish("root", move || {
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
				&serde_json::from_value(saved["context"].clone()).unwrap(),
			)
			.await;
			fields::expired_live(&session, &Ref::try_from(&root).unwrap()).await;
			assert_eq!(attachment.live_marker().unwrap(), Some(marker));
			management::reopen(
				&session,
				&Ref::try_from(&root).unwrap(),
				&policy(),
				saved["managed"].as_str().unwrap(),
			)
			.await;

			inventory::reopen(
				&session,
				&Ref::try_from(&control).unwrap(),
				&policy(),
				saved["inventory"].as_str().unwrap(),
			)
			.await;
			text(&session, &shared, b"edited").await;
			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			caller.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			assert_eq!(drops.get(), 1);
			store.close().await.unwrap();
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
	store.close().await.unwrap();
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
	store.close().await.unwrap();
	Ok(())
}

#[wasm_bindgen]
pub async fn empty_store() -> Result<(), JsValue> {
	let mut store = Store::open("glowcap-loam-abort-proof", [3; 16], true, &[SCHEMA], Limits::default())
		.await
		.map_err(message)?;
	store.close().await.unwrap();
	Ok(())
}

#[wasm_bindgen]
pub async fn record_bound() -> Result<(), JsValue> {
	tokio::task::LocalSet::new()
		.run_until(async {
			let schema = Schema {
				id: 17,
				max_payload: 64 * 1024,
				..SCHEMA
			};
			let payload = vec![b'B'; schema.max_payload];
			let name = "glowcap-loam-record-bound-proof";
			let mut small = Store::open(name, [5; 16], true, &[schema], Limits::default())
				.await
				.map_err(message)?;
			let error = small
				.create_resource(&policy(), schema, 1, &payload, 2)
				.await
				.err()
				.expect("payload plus envelope exceeds the default record limit");
			assert!(error.to_string().contains("RecordTooLarge"));
			small.close().await.unwrap();
			let limits = Limits {
				record_bytes: schema.encoded_size_bound().map_err(message)?,
				call_bytes: 256 * 1024,
				..Limits::default()
			};
			let mut store = Store::open(name, [5; 16], false, &[schema], limits)
				.await
				.map_err(message)?;
			let resource = store
				.create_resource(&policy(), schema, 1, &payload, 2)
				.await
				.map_err(message)?;
			store.close().await.unwrap();
			let mut store = Store::open(name, [5; 16], false, &[schema], limits)
				.await
				.map_err(message)?;
			let host = Host::from_seed([8; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let mut content = registration(&drops);
			content.schema = schema.id;
			let mut attachment = store.attach(&host, vec![content]).unwrap();
			let (root, control) = attachment.restore(resource).await.unwrap();
			host.publish("large", move || {
				let root = root.clone();
				Box::new(move |_, _| Ok(Argument::Reference(root.clone())))
			})
			.unwrap();
			let (caller, session, accepted) = pair(&host).await;
			let catalog = session.fetch("large").await.unwrap();
			let root = Ref::try_from(&session.send(&catalog, "open", &[]).await.unwrap()).unwrap();
			text(&session, &root, &payload).await;
			let costs = store.storage_statistics();
			assert!(costs.peak_input_bytes > schema.max_payload);
			assert!(costs.peak_input_bytes <= costs.input_capacity_bytes);
			drop(control);
			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			caller.close(PendingWork::Cancel).await.unwrap();
			attachment.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			store.close().await.unwrap();
			Ok(())
		})
		.await
}

mod cancellation;
