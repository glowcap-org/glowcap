//! The installed server must reset more authorities than fit in its writer
//! queue, and answer session retirement only after its inventory has retired.
use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::server::document::{Document, FILE};

#[tokio::test]
async fn room_server_service_operator_reset_exceeds_writer_capacity() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), scenario())
				.await
				.expect("operator process scenario deadline");
		})
		.await;
}

async fn runtime() -> Runtime {
	Runtime::open(RuntimeConfig::providers([glowcap::tcp::provider(Default::default())]))
		.await
		.unwrap()
}

fn top(answer: Argument) -> Vec<Argument> {
	let Argument::List(cells) = answer else {
		panic!("a list answer")
	};
	cells
}

async fn scenario() {
	const LINKS: usize = 300;
	let temp = Temp(std::env::temp_dir().join(format!("rooms-operator-pressure-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let mut fixture = serde_json::to_value(Document::fresh([31; 32], [32; 32])).unwrap();
	fixture["linkedRooms"] = serde_json::json!((0..LINKS).map(|i| format!("garden-{i:03}")).collect::<Vec<_>>());
	let document = Document::decode(&fixture.to_string()).unwrap();
	std::fs::write(temp.0.join(FILE), document.encode().unwrap()).unwrap();
	let start = || {
		let mut process = Process(
			command()
				.arg(format!("--state={}", temp.0.display()))
				.args(["--transport=tcp", "--operator"])
				.stdout(Stdio::piped())
				.stderr(Stdio::piped())
				.spawn()
				.unwrap(),
		);
		let block = stderr_until(&mut process, "rooms: ready");
		let locator = block
			.lines()
			.find_map(|line| line.trim().strip_prefix("locator     "))
			.unwrap();
		let operator = block
			.lines()
			.find_map(|line| line.strip_prefix("ROOMS-OPERATOR "))
			.unwrap()
			.to_owned();
		(process, glowcap::parse_locator(locator).unwrap(), operator)
	};
	let (mut process, locator, token) = start();
	let client = runtime().await;
	let session = client
		.connect(&locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let operator = session.fetch(&token).await.unwrap();
	// Page totals prove the fixture is present without materializing every row.
	let args = ["links".into(), Argument::Integer(0), Argument::Integer(1)];
	let before = top(session.send(&operator, "operatorSnapshot", &args).await.unwrap());
	assert_eq!(before.last().unwrap().as_i64(), Some(LINKS as i64));
	session
		.send(&operator, "resetOperatorScope", &["links".into()])
		.await
		.unwrap();
	let after = top(session.send(&operator, "operatorSnapshot", &args).await.unwrap());
	assert_eq!(after.last().unwrap().as_i64(), Some(0));
	let kept = Document::decode(&std::fs::read_to_string(temp.0.join(FILE)).unwrap()).unwrap();
	assert!(kept.linked_rooms.as_slice().is_empty());
	assert_eq!(kept.revoked_rooms.as_slice().len(), LINKS);

	// Separate Hosts give separate sessions; each has called the directory
	// before the operator captures its inventory.
	let mut members = Vec::new();
	for _ in 0..8 {
		let member = runtime().await;
		let seat = member.connect(&locator, ConnectOptions::default()).await.unwrap();
		let directory = seat.fetch(rooms_application::directory::NAME).await.unwrap();
		seat.send(&directory, "list", &[]).await.unwrap();
		members.push((member, seat));
	}
	let retired = top(session
		.send(
			&operator,
			"operatorRetireMatching",
			&["sessions".into(), "".into(), Argument::Integer(256)],
		)
		.await
		.unwrap());
	assert_eq!(retired[0].as_i64(), Some(8));
	assert_eq!(retired[1].as_i64(), Some(1)); // the calling operator stays
	for (member, _) in members {
		member.close(PendingWork::Cancel).await.unwrap();
	}
	session.close(PendingWork::Cancel).await.unwrap();
	process.signal("-TERM");
	let (mut process, locator, restarted_token) = start();
	assert_eq!(token, restarted_token);
	let session = client
		.connect(&locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let operator = session.fetch(&token).await.unwrap();
	let after = top(session.send(&operator, "operatorSnapshot", &args).await.unwrap());
	assert_eq!(after.last().unwrap().as_i64(), Some(0));
	session.close(PendingWork::Cancel).await.unwrap();
	client.close(PendingWork::Cancel).await.unwrap();
	process.signal("-TERM");
}
