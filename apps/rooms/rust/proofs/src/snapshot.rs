use super::arguments::{from_fixture, Arg};
use rooms_application::{
	grants::Access,
	room::ArgumentView,
	session::{
		checkpoint::Routes,
		snapshot::{self, views::*, BuildArguments, Snapshot, SnapshotArgument},
	},
};
use serde_json::Value;

struct NoRoutes;
impl Routes for NoRoutes {
	fn locator_authority(&self, _: &str) -> Option<String> {
		None
	}
	fn sturdyref_authority(&self, _: &str) -> Option<String> {
		None
	}
}
#[derive(Clone, Copy)]
struct View<'a>(&'a Arg);
impl ArgumentView for View<'_> {
	fn boolean(&self) -> Option<bool> {
		self.0.boolean()
	}
	fn is_null(&self) -> bool {
		self.0.is_null()
	}
	fn text(&self) -> Option<&str> {
		self.0.text()
	}
	fn integer(&self) -> Option<i128> {
		self.0.integer()
	}
	fn float(&self) -> Option<f64> {
		self.0.float()
	}
	fn contains_capability(&self) -> bool {
		self.0.contains_capability()
	}
}
impl SnapshotArgument for View<'_> {
	type Item<'a>
		= View<'a>
	where
		Self: 'a;
	fn list(&self) -> Option<impl ExactSizeIterator<Item = View<'_>>> {
		match self.0 {
			Arg::List(v) => Some(v.iter().map(View)),
			_ => None,
		}
	}
}
fn arg(value: &Value) -> Arg {
	if let Some(values) = value.as_array() {
		Arg::List(values.iter().map(arg).collect())
	} else {
		from_fixture(value)
	}
}
fn read(value: &Value) -> Result<Snapshot, snapshot::Refusal> {
	let args: Vec<_> = value.as_array().unwrap().iter().map(arg).collect();
	Snapshot::read(&args.iter().map(View).collect::<Vec<_>>(), &NoRoutes)
}
struct Output;
impl BuildArguments for Output {
	type Value = Value;
	fn text(value: String) -> Value {
		value.into()
	}
	fn integer(value: u64) -> Value {
		serde_json::json!({"integer":value.to_string()})
	}
	fn null() -> Value {
		Value::Null
	}
	fn list(value: Vec<Value>) -> Value {
		value.into()
	}
}
fn same(got: Vec<Value>, want: &Value, name: &str) {
	let want = want.as_array().unwrap();
	assert_eq!(got.len(), want.len(), "{name}");
	for (i, (got, want)) in got.iter().zip(want).enumerate() {
		if [1, 7, 8, 9, 10, 11].contains(&i) {
			let g = serde_json::from_str::<Value>(got.as_str().unwrap());
			let w = serde_json::from_str::<Value>(want.as_str().unwrap());
			if let (Ok(g), Ok(w)) = (g, w) {
				assert_eq!(g, w, "{name} slot {i}");
				continue;
			}
		}
		assert_eq!(got, want, "{name} slot {i}");
	}
}
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/snapshots.json")).unwrap();
	for row in fixture["rows"].as_array().unwrap() {
		let parsed = read(&row["raw"]);
		assert_eq!(
			parsed.is_ok(),
			row["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			row["name"],
			parsed.as_ref().err()
		);
		if let Ok(snapshot) = parsed {
			same(
				snapshot.encode::<Output>().unwrap(),
				&row["raw"],
				row["name"].as_str().unwrap(),
			);
		}
	}
	let baseline = &fixture["rows"][0]["raw"];
	let snapshot = read(baseline).unwrap();
	for (access, name) in [
		(Access::None, "none"),
		(Access::Observe, "observe"),
		(Access::Interact, "interact"),
		(Access::Admin, "admin"),
	] {
		same(
			snapshot
				.project::<Output>(
					access,
					&"Paused".into(),
					&[(
						snapshot::Text::new("attachment".into()).unwrap(),
						snapshot::Text::new("retry here".into()).unwrap(),
					)],
				)
				.unwrap(),
			&fixture["projections"][name],
			name,
		);
	}
	same(
		snapshot.encode::<Output>().unwrap(),
		baseline,
		"projection leaves owner intact",
	);
	for fit in fixture["fitting"].as_array().unwrap() {
		let name = fit["name"].as_str().unwrap();
		let mut snapshot = read(baseline).unwrap();
		snapshot.directory_views = snapshot::List::new(
			(0..32)
				.map(|i| DirectoryView {
					directory_id: snapshot::Text::new(format!("{}{i}", "d".repeat(30000)).into()).unwrap(),
					rooms: snapshot::List::new(vec![]).unwrap(),
					peers: snapshot::List::new(vec![]).unwrap(),
					truncated: false,
				})
				.collect(),
		)
		.unwrap();
		if name != "live" {
			snapshot.pending_effect_details = snapshot::List::new(
				(0..8)
					.map(|_| {
						(
							snapshot::Text::new("x".repeat(65536).into()).unwrap(),
							snapshot::Text::new("y".repeat(65536).into()).unwrap(),
							snapshot::Text::new("post".into()).unwrap(),
							EffectPhase::Prepared,
						)
					})
					.collect(),
			)
			.unwrap();
		}
		if name == "refuse" {
			snapshot.pending_effects = snapshot::List::new(
				(0..15)
					.map(|_| snapshot::Text::new("z".repeat(65536).into()).unwrap())
					.collect(),
			)
			.unwrap();
		}
		let result = snapshot.encode::<Output>();
		assert_eq!(result.is_ok(), fit["accepted"].as_bool().unwrap(), "{name}");
		if let Ok(result) = result {
			same(result, &fit["result"], name);
			assert!(read(&fit["result"]).is_ok());
		}
	}
	// The old reader only bounds individual fields. Rust also enforces the
	// producer's aggregate budget before retaining any application data.
	let mut huge = baseline.clone();
	huge[2] = serde_json::json!(vec!["x".repeat(65536); 15]);
	assert!(matches!(read(&huge), Err(snapshot::Refusal::Budget)));
	let mut oversized_room_view = read(baseline).unwrap();
	let room = oversized_room_view.room_views.as_slice()[0].clone();
	oversized_room_view.room_views = snapshot::List::new(
		(0..9)
			.map(|i| {
				let mut view = room.clone();
				view.conversation_id = snapshot::Text::new(format!("{}{i}", "r".repeat(65535)).into()).unwrap();
				view
			})
			.collect(),
	)
	.unwrap();
	let fitted = oversized_room_view.encode::<Output>().unwrap();
	assert_eq!(fitted[7], "[]");
	assert_eq!(fitted[3].as_array().unwrap().last().unwrap()[0], "snapshot-overflow");
	assert!(
		read(&Value::Array(fitted)).is_ok(),
		"producer must respect individual JSON budgets"
	);
	let drops = std::rc::Rc::new(std::cell::Cell::new(0));
	let mut args: Vec<_> = baseline.as_array().unwrap().iter().map(arg).collect();
	args[2] = Arg::List(vec![Arg::Capability(drops.clone())]);
	assert!(Snapshot::read(&args.iter().map(View).collect::<Vec<_>>(), &NoRoutes).is_err());
	assert_eq!(drops.get(), 0, "admission keeps argument custody with its caller");
	drop(args);
	assert_eq!(drops.get(), 1);
}
#[test]
fn captured_snapshot_contract() {
	run();
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn native_snapshot_constructs_binding_arguments() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/snapshots.json")).unwrap();
	let snapshot = read(&fixture["rows"][0]["raw"]).unwrap();
	let args = snapshot.encode::<rooms_glowcap::snapshot::Arguments>().unwrap();
	let values: Vec<_> = rooms_glowcap::values(&args).collect();
	let decoded = Snapshot::read(&values, &rooms_glowcap::routes::CheckpointRoutes).unwrap();
	same(
		decoded.encode::<Output>().unwrap(),
		&fixture["rows"][0]["raw"],
		"native",
	);
}
