//! Per-operation boundary costs after a page reload. Each operation reports
//! the change in `StorageStatistics` across exactly that operation.
use super::*;
use glowcap::loam::StorageStatistics;
use serde_json::{Value, json};

fn delta(label: &str, before: StorageStatistics, after: StorageStatistics) -> Value {
	json!({
		"operation": label,
		"transactions": after.transactions - before.transactions,
		"js_calls": after.js_calls - before.js_calls,
		"callbacks": after.callbacks - before.callbacks,
		"planning_passes": after.planning_passes - before.planning_passes,
		"database_rows": after.database_rows - before.database_rows,
		"emitted_writes": after.emitted_writes - before.emitted_writes,
		"copied_bytes": after.copied_bytes - before.copied_bytes,
	})
}

struct Meter {
	mark: StorageStatistics,
	report: Vec<Value>,
}
impl Meter {
	fn restart(&mut self, store: &Store) {
		self.mark = store.storage_statistics();
	}
	fn record(&mut self, label: &str, store: &Store) {
		let now = store.storage_statistics();
		self.report.push(delta(label, self.mark, now));
		self.mark = now;
	}
}

/// Measure a cold read, a warm read, an edit, a share and a receipt replay
/// against the store that `create` saved, in a freshly loaded page.
#[wasm_bindgen]
pub async fn operations(saved: &str) -> Result<String, JsValue> {
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
			attachment
				.start_live(Some(glowcap::loam::LiveMarker::decode(marker.try_into().unwrap())), 2)
				.unwrap();
			let (rooted, _control) = attachment.restore(resource).await.unwrap();
			host.publish("root", move || {
				let root = rooted.clone();
				Box::new(move |_, _| Ok(Argument::Reference(root.clone())))
			})
			.unwrap();
			let (caller, session, accepted) = pair(&host).await;
			let mut meter = Meter {
				mark: store.storage_statistics(),
				report: Vec::new(),
			};

			let shared = session.fetch(&swiss).await.unwrap();
			text(&session, &shared, b"edited").await;
			meter.record("cold read", &store);
			text(&session, &shared, b"edited").await;
			meter.record("warm read", &store);

			// The receipt sequences the next edit and share expect are setup.
			let entry = session.fetch("root").await.unwrap();
			let root = Ref::try_from(&session.send(&entry, "open", &[]).await.unwrap()).unwrap();
			let sequence = |verb: &'static str, target: Ref| {
				let session = &session;
				async move { u32::try_from(session.send(&target, verb, &[]).await.unwrap().as_i64().unwrap()).unwrap() }
			};
			let mutation_sequence = sequence("mutation-sequence", shared.clone()).await;
			let derivation_sequence = sequence("derivation-sequence", root.clone()).await;
			meter.restart(&store);

			let mut edit = mutation();
			edit[0] = Argument::Integer(i64::from(mutation_sequence));
			edit[2] = Argument::Bytes(b"measured".to_vec());
			session.send(&shared, "mutate", &edit).await.unwrap();
			meter.record("edit", &store);
			session.send(&shared, "mutate", &edit).await.unwrap();
			meter.record("receipt replay", &store);
			let grant = policy()
				.value(&[10], &[])
				.unwrap()
				.derive_arguments(derivation_sequence, Scope::Object, 0);
			session.send(&root, "derive", &grant).await.unwrap();
			meter.record("share", &store);

			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			caller.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			store.close().await.unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(json!(meter.report).to_string())
		})
		.await
}
