//! The operator capabilities under real CapTP: the admin-listeners seat list
//! and its `up` and `down` with every typed refusal, a runtime listener
//! that serves the same rooms, the kept intent replayed after a restart, the
//! diagnostic snapshot, and the swiss numbers a state directory keeps. The
//! operator, peering, and timeline scenarios sit beside this one.
mod authority;
mod irc;
mod listener_changes;
mod manager_scope;
mod operator;
mod peering;
mod trace;

use super::{Running, Temp, runtime, start_with, tcp};
use crate::server::Asked;
use glowcap::{Argument, ConnectOptions, PendingWork, Session};
use rooms_application::server::operations::listeners::{ONION_NEEDS_TOR, TRANSPORTS, Transport};
use std::time::Duration;

const KEYED_TCP: &str = glowcap::TRANSPORT_KEYED_TCP;

/// The policy crate names transports without a glowcap dependency; this
/// pins its names to the transport symbols glowcap owns.
#[test]
fn seat_transports_are_named_by_glowcaps_symbols() {
	for transport in TRANSPORTS {
		let symbol = match transport {
			Transport::Tcp => glowcap::TRANSPORT_TCP,
			Transport::KeyedTcp => glowcap::TRANSPORT_KEYED_TCP,
			Transport::NoiseTcp => glowcap::TRANSPORT_NOISE_TCP,
			Transport::Iroh => glowcap::TRANSPORT_IROH,
			Transport::KeyedRelay => glowcap::TRANSPORT_KEYED_RELAY,
			Transport::NoiseRelay => glowcap::TRANSPORT_NOISE_RELAY,
			Transport::Onion => glowcap::TRANSPORT_ONION,
		};
		assert_eq!(transport.name(), symbol);
	}
}

pub(super) fn text(row: &[Argument], at: usize) -> &str {
	row[at].as_str().expect("a text cell")
}
pub(super) fn int(row: &[Argument], at: usize) -> i64 {
	match &row[at] {
		Argument::Integer(n) => *n,
		other => panic!("an integer cell, not {other:?}"),
	}
}
pub(super) fn boolean(row: &[Argument], at: usize) -> bool {
	match &row[at] {
		Argument::Boolean(b) => *b,
		other => panic!("a boolean cell, not {other:?}"),
	}
}
pub(super) fn rows(answer: &Argument) -> Vec<Vec<Argument>> {
	match answer {
		Argument::List(rows) => rows
			.iter()
			.map(|row| match row {
				Argument::List(cells) => cells.clone(),
				other => panic!("a row, not {other:?}"),
			})
			.collect(),
		other => panic!("a list of rows, not {other:?}"),
	}
}
fn seat<'a>(seats: &'a [Vec<Argument>], transport: &str) -> &'a [Argument] {
	seats
		.iter()
		.find(|row| text(row, 0) == transport)
		.unwrap_or_else(|| panic!("a {transport} seat"))
}
fn free_port() -> u16 {
	std::net::TcpListener::bind(("127.0.0.1", 0))
		.unwrap()
		.local_addr()
		.unwrap()
		.port()
}
async fn list(session: &Session, cap: &glowcap::Ref) -> Vec<Vec<Argument>> {
	rows(&session.send(cap, "list", &[]).await.unwrap())
}
fn pair(name: &str, value: Argument) -> Argument {
	Argument::List(vec![Argument::String(name.into()), value])
}
pub(super) async fn refused(session: &Session, cap: &glowcap::Ref, verb: &str, args: &[Argument]) -> String {
	session.send(cap, verb, args).await.unwrap_err().to_string()
}
pub(super) fn cells(answer: &Argument) -> Vec<Argument> {
	match answer {
		Argument::List(cells) => cells.clone(),
		other => panic!("a list, not {other:?}"),
	}
}
/// One category's page: `(next, rows, total)`.
pub(super) type Page = (Argument, Vec<Vec<Argument>>, i64);
/// The pages of a whole snapshot by category name.
pub(super) fn whole(answer: &Argument) -> (i64, std::collections::BTreeMap<String, Page>) {
	// Actual host inventories must be consumable by the shared attached
	// protocol, including nested room members and issued authority relations.
	rooms_application::server::operations::operator::view::read_snapshot(&rooms_glowcap::Value(answer)).unwrap();
	let top = cells(answer);
	let revision = int(&top, 0);
	let pages = rows(&top[1])
		.into_iter()
		.map(|page| {
			(
				text(&page, 0).to_string(),
				(page[1].clone(), rows(&page[2]), int(&page, 3)),
			)
		})
		.collect();
	(revision, pages)
}

#[tokio::test]
async fn rooms_server_administers_listeners_and_answers_diagnostics() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), scenario())
				.await
				.expect("operations scenario deadline");
		})
		.await;
}

async fn scenario() {
	let temp = Temp::new();
	let asked = Asked {
		admin_listeners: true,
		diagnostics: true,
		..Default::default()
	};
	let running = start_with(temp.0.clone(), tcp(), asked.clone()).await;
	let tokens: Vec<&str> = running
		.capabilities
		.iter()
		.map(|minted| minted.capability.token)
		.collect();
	assert_eq!(tokens, ["ROOMS-ADMIN-LISTENERS", "ROOMS-DIAGNOSTICS"]);
	let listeners_swiss = running.capabilities[0].swiss.clone();
	let diagnostics_swiss = running.capabilities[1].swiss.clone();
	assert_eq!(
		std::fs::read_to_string(temp.0.join("admin-listeners")).unwrap().trim(),
		listeners_swiss
	);
	let runtime = runtime().await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let session = runtime.connect(&dial, ConnectOptions::default()).await.unwrap();
	let admin = session.fetch(&listeners_swiss).await.unwrap();

	// The seat list: one per transport, described, the boot tcp seat serving.
	let seats = list(&session, &admin).await;
	assert_eq!(
		seats.iter().map(|row| text(row, 0).to_string()).collect::<Vec<_>>(),
		[
			"tcp",
			KEYED_TCP,
			"noise-tcp",
			"iroh",
			"keyed-relay",
			"noise-relay",
			"onion"
		]
	);
	assert!(seats.iter().all(|row| !text(row, 1).is_empty()));
	let boot = seat(&seats, "tcp");
	assert_eq!(int(boot, 6), 1);
	assert_eq!(text(boot, 7), dial.designator);
	assert!(boolean(boot, 8));
	assert_eq!(text(seat(&seats, "onion"), 5), ONION_NEEDS_TOR);
	assert_eq!(int(seat(&seats, KEYED_TCP), 6), 0);
	let takes = rows(&seat(&seats, KEYED_TCP)[4]);
	assert_eq!(
		takes.iter().map(|row| text(row, 0).to_string()).collect::<Vec<_>>(),
		["bind", "port", "advertise"]
	);
	assert_eq!(text(&rows(&seat(&seats, "keyed-relay")[4])[0], 1), "url");

	// Exact data before the registry: the refusals name what was wrong.
	assert!(
		refused(&session, &admin, "list", &[Argument::Integer(1)])
			.await
			.contains("list takes no arguments")
	);
	assert!(
		refused(&session, &admin, "down", &[Argument::Integer(1)])
			.await
			.contains("listener-serving")
	);
	assert!(
		refused(&session, &admin, "down", &[Argument::Integer(999)])
			.await
			.contains("no-such-listener")
	);
	assert!(
		refused(&session, &admin, "up", &[Argument::String("tcp".into())])
			.await
			.contains("listener-transport-held")
	);
	assert!(
		refused(&session, &admin, "up", &[Argument::String("onion".into())])
			.await
			.contains("listener-unsupported")
	);
	assert!(
		refused(&session, &admin, "up", &[Argument::String("carrier-pigeon".into())])
			.await
			.contains("listener-unsupported")
	);
	assert!(
		refused(&session, &admin, "up", &[Argument::String("keyed-relay".into())])
			.await
			.contains("registers at a relay")
	);
	assert!(
		refused(
			&session,
			&admin,
			"up",
			&[
				Argument::String("keyed-relay".into()),
				Argument::List(vec![pair("relay", Argument::String("ws://127.0.0.1:1/".into()))]),
			],
		)
		.await
		.contains("No relay answered a register socket")
	);
	assert!(
		refused(
			&session,
			&admin,
			"up",
			&[
				Argument::String("iroh".into()),
				Argument::List(vec![pair("port", Argument::Integer(1))]),
			],
		)
		.await
		.contains("no \"port\" option")
	);
	assert!(
		refused(&session, &admin, "nope", &[])
			.await
			.contains("listeners has no method nope")
	);

	// A keyed-tcp listener rides up beside the serving one, on the asked
	// port, and serves the same rooms.
	let port = free_port();
	let up = session
		.send(
			&admin,
			"up",
			&[
				Argument::String(KEYED_TCP.into()),
				Argument::List(vec![
					pair("bind", Argument::String("127.0.0.1".into())),
					pair("port", Argument::Integer(i64::from(port))),
				]),
			],
		)
		.await
		.unwrap();
	let row = match up {
		Argument::List(cells) => cells,
		other => panic!("a seat row, not {other:?}"),
	};
	assert_eq!(text(&row, 0), KEYED_TCP);
	assert_eq!(int(&row, 6), 2);
	assert!(!boolean(&row, 8));
	let keyed = text(&row, 7).to_string();
	assert!(keyed.starts_with("ocapn://") && keyed.contains(".keyed-tcp"), "{keyed}");
	assert!(keyed.contains(&format!("%3A{port}")), "{keyed}");
	let kept = std::fs::read_to_string(temp.0.join("operations.json")).unwrap();
	assert!(
		kept.contains("\"keyed-tcp\"") && kept.contains(&port.to_string()),
		"{kept}"
	);
	let via_keyed = runtime
		.connect(&glowcap::parse_locator(&keyed).unwrap(), ConnectOptions::default())
		.await
		.unwrap();
	let directory = via_keyed.fetch("directory").await.unwrap();
	let garden = via_keyed
		.send(&directory, "open", &[Argument::String("garden".into())])
		.await
		.unwrap();
	assert!(matches!(garden, Argument::Reference(_)), "{garden:?}");
	assert!(matches!(
		via_keyed.send(&directory, "list", &[]).await.unwrap(),
		Argument::List(_)
	));
	assert!(
		list(&session, &admin)
			.await
			.iter()
			.filter(|row| int(row, 6) != 0)
			.count() == 2
	);
	assert!(
		refused(&session, &admin, "up", &[Argument::String(KEYED_TCP.into())])
			.await
			.contains("listener-transport-held")
	);

	// Diagnostics: the published bootstrap, the room, the sessions, no trouble.
	let inspect = session.fetch(&diagnostics_swiss).await.unwrap();
	let snapshot = rows(&session.send(&inspect, "snapshot", &[]).await.unwrap());
	let kinds: Vec<&str> = snapshot.iter().map(|row| text(row, 0)).collect();
	assert_eq!(kinds[0], "directory");
	assert_eq!(text(&snapshot[0], 2), "published bootstrap");
	assert!(kinds.contains(&"room"), "{kinds:?}");
	assert_eq!(snapshot.iter().filter(|row| text(row, 0) == "session").count(), 2);
	assert!(
		snapshot
			.iter()
			.any(|row| text(row, 0) == "session" && text(row, 1) == KEYED_TCP)
	);
	assert!(!kinds.contains(&"trouble"), "{kinds:?}");
	assert!(
		refused(&session, &inspect, "snapshot", &[Argument::Integer(1)])
			.await
			.contains("snapshot takes no arguments")
	);
	assert!(
		refused(&session, &inspect, "list", &[])
			.await
			.contains("diagnostics has no method list")
	);

	via_keyed.close(PendingWork::Cancel).await.unwrap();
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();

	// The restart reuses the swiss numbers and replays the kept keyed-tcp
	// seat on the same port; taking it down forgets it.
	let again = start_with(temp.0.clone(), tcp(), asked).await;
	assert_eq!(again.capabilities[0].swiss, listeners_swiss);
	let session = runtime
		.connect(
			&glowcap::parse_locator(&again.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap();
	let admin = session.fetch(&listeners_swiss).await.unwrap();
	let seats = list(&session, &admin).await;
	let restored = seat(&seats, KEYED_TCP);
	assert_ne!(int(restored, 6), 0, "the kept keyed-tcp seat came back");
	assert!(text(restored, 7).contains(&format!("%3A{port}")));
	let restored_id = int(restored, 6);
	assert_eq!(
		session
			.send(&admin, "down", &[Argument::Integer(restored_id)])
			.await
			.unwrap(),
		Argument::Void
	);
	let seats = list(&session, &admin).await;
	assert_eq!(int(seat(&seats, KEYED_TCP), 6), 0);
	let kept = std::fs::read_to_string(temp.0.join("operations.json")).unwrap();
	assert!(!kept.contains(KEYED_TCP), "{kept}");
	assert!(
		refused(&session, &admin, "down", &[Argument::Integer(restored_id)])
			.await
			.contains("no-such-listener")
	);
	session.close(PendingWork::Cancel).await.unwrap();
	again.stop.send(()).unwrap();
	again.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	assert!(again.notices.borrow().is_empty(), "{:?}", again.notices.borrow());
}

#[tokio::test]
async fn no_capability_exists_without_its_flag() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), async {
				let temp = Temp::new();
				let flagged = start_with(
					temp.0.clone(),
					tcp(),
					Asked {
						diagnostics: true,
						..Default::default()
					},
				)
				.await;
				let swiss = flagged.capabilities[0].swiss.clone();
				flagged.stop.send(()).unwrap();
				flagged.task.await.unwrap().unwrap();
				let plain = start_with(temp.0.clone(), tcp(), Asked::default()).await;
				assert!(plain.capabilities.is_empty());
				let runtime = runtime().await;
				let session = runtime
					.connect(
						&glowcap::parse_locator(&plain.location).unwrap(),
						ConnectOptions::default(),
					)
					.await
					.unwrap();
				assert!(session.fetch(&swiss).await.is_err(), "a stale swiss answers nothing");
				session.fetch("directory").await.unwrap();
				session.close(PendingWork::Cancel).await.unwrap();
				plain.stop.send(()).unwrap();
				plain.task.await.unwrap().unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("flag scenario deadline");
		})
		.await;
}
