//! One continuous consumer delivers each retained event once per invocation.
//! Delivery is not acknowledgment: restarting replays all still-pending events.
use super::{Failure, emit, request};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Default)]
struct Delivery {
	after: Option<u64>,
	// Independent of the wake cursor: page past delivered events while leaving
	// them pending for acknowledgment and replay on a later invocation.
	delivered: u64,
}
impl Delivery {
	fn batch(&mut self, batch: &mut Value) -> Result<bool, Failure> {
		let cursor = batch["cursor"]
			.as_u64()
			.ok_or_else(|| Failure::invalid("inbox response lacks cursor"))?;
		let gap = !batch["gap"].is_null();
		let rows = batch["pending"]
			.as_array_mut()
			.ok_or_else(|| Failure::invalid("inbox response lacks pending events"))?;
		let mut last = 0;
		for row in rows.iter() {
			let id = row["id"]
				.as_u64()
				.ok_or_else(|| Failure::invalid("inbox event lacks id"))?;
			if id <= last {
				return Err(Failure::invalid("inbox events are not in ascending identifier order"));
			}
			last = id;
		}
		rows.retain(|row| row["id"].as_u64().expect("validated event") > self.delivered);
		let deliver = self.after.is_none() || !rows.is_empty() || gap;
		self.delivered = self.delivered.max(last);
		self.after = Some(cursor);
		Ok(deliver)
	}
}

pub(super) async fn run(state: &Path) -> Result<Value, Failure> {
	let mut delivery = Delivery::default();
	loop {
		let wait = if delivery.after.is_none() { 0 } else { 30 };
		let mut batch = request(
			state,
			json!({"verb":"tick", "wait":wait, "after":delivery.after, "after_id":delivery.delivered}),
		)
		.await?;
		if delivery.batch(&mut batch)? {
			emit(&batch)?;
		}
		if !batch["gap"].is_null() && batch["more"] != true {
			return Err(Failure::uncertain(
				"observation gap; inspect status, then explicitly resume --accept-gap",
			));
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	fn batch(cursor: u64, rows: Value) -> Value {
		json!({"ok":true,"cursor":cursor,"remaining":rows.as_array().unwrap().len(),"pending":rows,"gap":null})
	}
	#[test]
	fn delivery_preserves_every_kind_without_repeating_unacknowledged_events() {
		let rows = json!([
			{"id":1,"channel":"room","author":"Alice","text":"own echo"},
			{"id":2,"channel":"dm","author":"Alice","text":"same name is not identity"},
			{"id":3,"system":true,"presence":"{\"kind\":\"typing\",\"on\":false}"},
			{"id":4,"system":true,"facts":"{\"carries\":{}}"},
			{"id":5,"change":"edited","text":"edited line","files":[{"name":"notes"}]}
		]);
		let mut delivery = Delivery::default();
		let mut first = batch(5, rows.clone());
		assert!(delivery.batch(&mut first).unwrap());
		assert_eq!(first["pending"], rows);
		assert!(!delivery.batch(&mut batch(5, rows.clone())).unwrap());
		let mut next = rows.clone();
		next.as_array_mut()
			.unwrap()
			.push(json!({"id":6,"channel":"dm","text":"new DM"}));
		let mut next = batch(6, next);
		assert!(delivery.batch(&mut next).unwrap());
		assert_eq!(next["pending"], json!([{"id":6,"channel":"dm","text":"new DM"}]));
		assert_eq!(next["remaining"], 6);
		assert!(
			!delivery.batch(&mut batch(7, json!([]))).unwrap(),
			"acks are not new events"
		);
		assert_eq!(delivery.delivered, 6, "acknowledgment does not rewind delivery");
		let mut restarted = Delivery::default();
		let mut retained = batch(6, rows.clone());
		assert!(restarted.batch(&mut retained).unwrap());
		assert_eq!(retained["pending"], rows, "delivery must not acknowledge the journal");
	}
	#[test]
	fn listener_reports_initial_readiness_and_gaps_but_not_quiet_timeouts() {
		let mut delivery = Delivery::default();
		assert!(delivery.batch(&mut batch(0, json!([]))).unwrap());
		assert!(!delivery.batch(&mut batch(0, json!([]))).unwrap());
		let mut gap = batch(1, json!([]));
		gap["gap"] = json!({"class":"storage"});
		assert!(delivery.batch(&mut gap).unwrap());
	}
	#[test]
	fn advancing_pages_delivers_the_backlog_without_repeating_the_retained_prefix() {
		let rows = |start, end| (start..=end).map(|id| json!({"id":id})).collect::<Vec<_>>();
		let mut delivery = Delivery::default();
		assert!(delivery.batch(&mut batch(100, json!(rows(1, 64)))).unwrap());
		let mut next = batch(101, json!(rows(33, 96)));
		assert!(delivery.batch(&mut next).unwrap());
		assert_eq!(next["pending"], json!(rows(65, 96)));
		assert!(!delivery.batch(&mut batch(102, json!(rows(50, 96)))).unwrap());
		assert!(delivery.batch(&mut batch(103, json!([{"id":98},{"id":97}]))).is_err());
	}
}
