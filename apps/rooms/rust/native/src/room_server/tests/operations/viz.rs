//! The live timeline endpoint under real sockets: a plain request told
//! where the doors are, sockets refused without the capability, a viewer's
//! CapTP session over a WebSocket with its replay, a producer's scoped
//! records, the room's own trace, a producer leaving, and a quiet viewer
//! hearing a long timeline to its end.
use super::*;
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn room_server_serves_the_live_timeline_to_admitted_sockets_only() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), viz())
				.await
				.expect("viz scenario deadline");
		})
		.await;
}

#[tokio::test]
async fn room_server_delivers_a_long_timeline_to_a_quiet_viewer() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), long_timeline())
				.await
				.expect("long timeline scenario deadline");
		})
		.await;
}

/// A running endpoint: the server, its capability swiss, the announced
/// sturdyref, its parsed locator, and the port the doors are on.
struct Endpoint {
	running: Running,
	swiss: String,
	sturdyref: String,
	port: u16,
}

async fn endpoint(temp: &Temp) -> Endpoint {
	let running = start_with(
		temp.0.clone(),
		tcp(),
		Asked {
			viz: true,
			..Default::default()
		},
	)
	.await;
	let swiss = running.capabilities[0].swiss.clone();
	let sturdyref = running.viz.clone().expect("the endpoint announced its sturdyref");
	let parsed = glowcap::parse_sturdyref(&sturdyref, glowcap::CaptpVersion::V1_0).unwrap();
	assert_eq!(String::from_utf8(parsed.swissnum.clone()).unwrap(), swiss);
	let port = glowcap::designator_host_port(&parsed.locator.designator).unwrap().1;
	Endpoint {
		running,
		swiss,
		sturdyref,
		port,
	}
}

/// A viewer on its own thread, because the trace tap covers every Host on
/// the server's thread and a viewer is another process in the product: it
/// subscribes an inbox that collects every record line into `heard`, then
/// stays until told.
pub(super) struct Viewer {
	heard: Arc<Mutex<Vec<String>>>,
	stop: std::sync::mpsc::Sender<()>,
	thread: std::thread::JoinHandle<()>,
}

impl Viewer {
	/// Connect, subscribe, and answer once subscribed or with why not; the
	/// answer is polled rather than blocked on, because the server serving
	/// the viewer runs on the calling thread.
	pub(super) async fn subscribe(sturdyref: &str) -> Viewer {
		use crate::websocket::WsBytes;
		use tokio_tungstenite::connect_async;
		let parsed = glowcap::parse_sturdyref(sturdyref, glowcap::CaptpVersion::V1_0).unwrap();
		let swiss = String::from_utf8(parsed.swissnum).unwrap();
		let port = glowcap::designator_host_port(&parsed.locator.designator).unwrap().1;
		let url = format!("ws://127.0.0.1:{port}/?cap={swiss}");
		let (sturdyref, locator) = (sturdyref.to_owned(), parsed.locator);
		let heard = Arc::new(Mutex::new(Vec::<String>::new()));
		let (stop, stopped) = std::sync::mpsc::channel::<()>();
		let (ready, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
		let sink = heard.clone();
		let thread = std::thread::spawn(move || {
			let runtime = tokio::runtime::Builder::new_current_thread()
				.enable_all()
				.build()
				.unwrap();
			let local = tokio::task::LocalSet::new();
			local.block_on(&runtime, async move {
				let opened = async {
					let (ws, _) = connect_async(&url).await.map_err(|e| e.to_string())?;
					let host = glowcap::Host::from_seed([7u8; 32]).map_err(|e| e.to_string())?;
					let session = Session::dial_channel(
						&host,
						&locator,
						WsBytes::new(ws).into_channel(),
						Some(Duration::from_secs(10)),
						None,
					)
					.await
					.map_err(|e| e.to_string())?
					.with_gc();
					let trace = session.enliven(&sturdyref).await.map_err(|e| e.to_string())?;
					let inbox = session
						.spawn_owned(move |verb, args| {
							if let ("record", Some(Argument::String(line))) = (verb, args.first()) {
								sink.lock().unwrap().push(line.clone());
							}
							Ok(Argument::Void)
						})
						.map_err(|e| e.to_string())?;
					let answered = session
						.send(&trace, "subscribe", &[Argument::Reference(inbox)])
						.await
						.map_err(|e| e.to_string())?;
					if answered != Argument::Void {
						return Err(format!("subscribe answered {answered:?}"));
					}
					Ok((host, session))
				}
				.await;
				let (host, session) = match opened {
					Ok(held) => {
						ready.send(Ok(())).unwrap();
						held
					}
					Err(reason) => {
						ready.send(Err(reason)).unwrap();
						return;
					}
				};
				while stopped.try_recv() == Err(std::sync::mpsc::TryRecvError::Empty) {
					tokio::time::sleep(Duration::from_millis(10)).await;
				}
				let _ = session.close(PendingWork::Cancel).await;
				let _ = host.close(PendingWork::Cancel).await;
			});
		});
		tokio::time::timeout(Duration::from_secs(20), async {
			loop {
				match ready_rx.try_recv() {
					Ok(outcome) => break outcome,
					Err(std::sync::mpsc::TryRecvError::Empty) => tokio::time::sleep(Duration::from_millis(10)).await,
					Err(std::sync::mpsc::TryRecvError::Disconnected) => break Err("the viewer thread ended".into()),
				}
			}
		})
		.await
		.expect("the viewer subscribed in time")
		.expect("the viewer subscribed");
		Viewer { heard, stop, thread }
	}
	/// The first line heard containing `wanted`, within `patience`.
	pub(super) async fn heard(&self, wanted: &str, patience: Duration) -> String {
		let heard = self.heard.clone();
		tokio::time::timeout(patience, async {
			loop {
				if let Some(line) = heard.lock().unwrap().iter().find(|line| line.contains(wanted)).cloned() {
					break line;
				}
				tokio::time::sleep(Duration::from_millis(10)).await;
			}
		})
		.await
		.unwrap_or_else(|_| {
			panic!(
				"the viewer heard {wanted}; it heard {} lines",
				self.heard.lock().unwrap().len()
			)
		})
	}
	fn lines(&self) -> Vec<String> {
		self.heard.lock().unwrap().clone()
	}
	pub(super) async fn leave(self) {
		self.stop.send(()).unwrap();
		// The viewer's protocol close needs this LocalSet to answer its
		// WebSocket Close frame. A blocking join here would stop the server at
		// precisely the boundary the test is trying to prove.
		while !self.thread.is_finished() {
			tokio::task::yield_now().await;
		}
		self.thread.join().unwrap();
	}
}

/// One opened-session record as a producer says it.
fn opened_line(id: usize) -> String {
	format!(
		r#"{{"v":1,"sim_t_ns":{id},"kind":"ocapn.session-opened","session":"live-h1-s{id}","a":"alpha","b":"beta","transport":"tcp"}}"#
	)
}

async fn viz() {
	use futures_util::{SinkExt, StreamExt};
	use tokio_tungstenite::{connect_async, tungstenite::Message};
	let temp = Temp::new();
	let endpoint = endpoint(&temp).await;
	let (port, swiss) = (endpoint.port, endpoint.swiss.clone());
	assert_eq!(std::fs::read_to_string(temp.0.join("viz")).unwrap().trim(), swiss);

	// A plain request is told where the doors are.
	{
		use tokio::io::{AsyncReadExt, AsyncWriteExt};
		let mut plain = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
		plain
			.write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
			.await
			.unwrap();
		let mut answer = String::new();
		plain.read_to_string(&mut answer).await.unwrap();
		assert!(answer.starts_with("HTTP/1.1 400"), "{answer}");
		assert!(answer.contains("presenting the viz capability"), "{answer}");
	}
	// A socket without the capability is refused before anything is parsed,
	// with the wrong swiss as with none.
	for query in ["", "?cap=0000"] {
		let (mut refused, _) = connect_async(format!("ws://127.0.0.1:{port}/publish{query}"))
			.await
			.unwrap();
		match refused.next().await {
			Some(Ok(Message::Close(Some(frame)))) => {
				assert_eq!(u16::from(frame.code), 4403);
				assert!(frame.reason.as_str().contains("requires its capability"));
			}
			other => panic!("a refusal, not {other:?}"),
		}
	}

	// A viewer: a CapTP session over the socket, the trace object under the
	// swiss, and a subscription that replays the live topology.
	let viewer = Viewer::subscribe(&endpoint.sturdyref).await;
	let patience = Duration::from_secs(5);
	let end = viewer.heard("trace.replay-end", patience).await;
	assert!(!end.contains("\"seq\""), "{end}");
	assert!(end.contains("\"epoch\""), "{end}");
	assert!(
		!viewer.lines().iter().any(|line| line.contains("ocapn.session-opened")),
		"the viewer's own session is not a row: {:?}",
		viewer.lines()
	);

	// A producer hears the admission mark and nothing else; what it says
	// reaches the viewer scoped apart from the room's own trace.
	let (mut producer, _) = connect_async(format!("ws://127.0.0.1:{port}/publish?cap={swiss}"))
		.await
		.unwrap();
	let mark = producer.next().await.unwrap().unwrap();
	assert!(mark.to_text().unwrap().contains("trace.publish-ready"), "{mark:?}");
	producer
		.send(Message::Text(
			r#"{"v":1,"sim_t_ns":3,"kind":"ocapn.session-opened","session":"live-h1-s1","a":"alpha","b":"beta","transport":"tcp","seq":77}"#.into(),
		))
		.await
		.unwrap();
	let forwarded = viewer.heard("\"a\":\"alpha\"", patience).await;
	assert!(forwarded.contains("/live-h1-s1\""), "{forwarded}");
	assert!(
		forwarded.contains("\"seq\":") && !forwarded.contains("\"seq\":77"),
		"{forwarded}"
	);
	producer
		.send(Message::Text(r#"{"v":1,"kind":"trace.replay-end","epoch":1}"#.into()))
		.await
		.unwrap();

	// The room's own trace goes in through the same door: a member's session
	// with the room server appears as a row from the endpoint's own scope.
	let runtime = super::runtime().await;
	let member = runtime
		.connect(
			&glowcap::parse_locator(&endpoint.running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap()
		.with_gc();
	member.fetch("directory").await.unwrap();
	let own = viewer.heard("\"session\":\"p0/", patience).await;
	assert!(own.contains("ocapn.session-opened"), "{own}");
	assert!(own.contains("\"a_label\":\"rooms\""), "{own}");

	// A producer leaving takes its rows without a close being announced.
	drop(producer);
	let left = viewer.heard("trace.producer-left", patience).await;
	assert!(left.contains("\"scope\":\"p1\""), "{left}");
	{
		let heard = viewer.lines();
		assert!(
			!heard
				.iter()
				.any(|line| line.contains("ocapn.session-closed") && line.contains("/live-h1-s1\"")),
			"{heard:?}"
		);
		assert!(
			!heard
				.iter()
				.any(|line| line.contains("trace.replay-end") && line.contains("\"seq\"")),
			"a producer cannot forge the end of a replay"
		);
	}

	member.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	viewer.leave().await;
	endpoint.running.stop.send(()).unwrap();
	endpoint.running.task.await.unwrap().unwrap();
}

/// A viewer that only listens hears a long timeline to its end: records
/// keep arriving after a burst, after a pause, and after far more of them
/// than one answered call could hold in flight.
async fn long_timeline() {
	use futures_util::{SinkExt, StreamExt};
	use tokio_tungstenite::{connect_async, tungstenite::Message};
	let temp = Temp::new();
	let endpoint = endpoint(&temp).await;
	let viewer = Viewer::subscribe(&endpoint.sturdyref).await;
	viewer.heard("trace.replay-end", Duration::from_secs(5)).await;
	let (mut producer, _) = connect_async(format!(
		"ws://127.0.0.1:{}/publish?cap={}",
		endpoint.port, endpoint.swiss
	))
	.await
	.unwrap();
	producer.next().await.unwrap().unwrap();
	// A burst, then a pause with the viewer silent, then one more.
	for id in 0..400 {
		producer.send(Message::Text(opened_line(id).into())).await.unwrap();
	}
	viewer.heard("/live-h1-s399\"", Duration::from_secs(10)).await;
	tokio::time::sleep(Duration::from_millis(300)).await;
	producer.send(Message::Text(opened_line(400).into())).await.unwrap();
	viewer.heard("/live-h1-s400\"", Duration::from_secs(5)).await;
	let opens = viewer
		.lines()
		.iter()
		.filter(|line| line.contains("ocapn.session-opened"))
		.count();
	assert_eq!(opens, 401, "every record reached the viewer once");
	drop(producer);
	viewer.leave().await;
	endpoint.running.stop.send(()).unwrap();
	endpoint.running.task.await.unwrap().unwrap();
}
