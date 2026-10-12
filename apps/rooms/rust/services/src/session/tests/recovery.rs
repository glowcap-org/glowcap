//! A cold workspace retries restoration when its directory becomes reachable.
use super::*;
use glowcap::{Argument, Host, tcp};
use rooms_application::{
	content::session::{custody, workspace},
	directory,
	fields::Text,
};
use rooms_glowcap::client::workspace::DirectoryImport;
use std::{cell::Cell, num::NonZeroU64, rc::Rc};

async fn directory_server(port: u16, watches: Rc<Cell<usize>>) -> (Rc<tcp::Server>, tokio::task::JoinHandle<()>) {
	let host = Host::from_seed([193; 32]).unwrap();
	host.publish("recovery-directory", move || {
		let watches = watches.clone();
		Box::new(move |verb, _args| match verb {
			directory::WATCH => {
				watches.set(watches.get() + 1);
				Ok(directory::wire::snapshot::<rooms_glowcap::snapshot::Arguments>(
					&directory::Snapshot {
						rooms: Vec::new(),
						peers: Vec::new(),
						omitted: 0,
					},
					directory::Shape::Publication,
				))
			}
			directory::UNWATCH => Ok(Argument::Void),
			_ => Err("unexpected directory operation".into()),
		})
	})
	.unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		port,
		tcp::ListenOptions {
			identity: tcp::ListenerIdentity::Host(host),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let accepting = Rc::new(server);
	let task = tokio::task::spawn_local({
		let accepting = accepting.clone();
		async move {
			while let Ok(session) = accepting.accept().await {
				tokio::task::spawn_local(async move {
					let _ = session.serve().await;
				});
			}
		}
	});
	(accepting, task)
}

async fn until(label: &str, mut ready: impl FnMut() -> bool) {
	tokio::time::timeout(Duration::from_secs(3), async {
		while !ready() {
			tokio::time::sleep(Duration::from_millis(5)).await;
		}
	})
	.await
	.expect(label);
}

#[tokio::test]
async fn cold_workspace_recovers_directory_without_a_user_mutation() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), async {
				let temp = Temp::new();
				let watches = Rc::new(Cell::new(0));
				let (server, accepting) = directory_server(0, watches.clone()).await;
				let port = server.port().unwrap();
				let uri = glowcap::format_sturdyref(
					&server.locator().unwrap(),
					b"recovery-directory",
					glowcap::CaptpVersion::V1_0,
				)
				.unwrap();
				let mut peer = Peer::open(tcp_config(temp.0.clone()), Rc::new(|_| {})).await.unwrap();
				let local = peer.local().unwrap();
				let snapshot = local.workspace.snapshot().await.unwrap();
				let key = NonZeroU64::new(1).unwrap();
				let acquisition = local
					.workspace
					.prepare_directory(
						snapshot.revision,
						DirectoryImport {
							row: workspace::Directory {
								id: Text::new("directory".into()).unwrap(),
								access: custody::FieldKey::new(key, key),
								source: Some(custody::FieldKey::new(key, key)),
								name: None,
								inbox: None,
								home: true,
								nick: Text::new("".into()).unwrap(),
								assigned_nick: None,
								nick_allocation: directory::registration::NicknameAllocation::Exact,
								standing: None,
							},
							reference: local.host.enliven(&uri).await.unwrap(),
							uri: Some(uri),
						},
						&snapshot.intent,
					)
					.unwrap();
				acquisition.submit().await.unwrap();
				until("initial directory snapshot did not arrive", || watches.get() == 1).await;
				drop((acquisition, local));
				peer.close().await.unwrap();
				server.host().close(PendingWork::Cancel).await.unwrap();
				accepting.await.unwrap();
				drop(server);
				let failures = Rc::new(Cell::new(0));
				let mut peer = Peer::open(tcp_config(temp.0.clone()), {
					let failures = failures.clone();
					Rc::new(move |notice| {
						if matches!(notice, Notice::Activity { .. }) {
							failures.set(failures.get() + 1);
						}
					})
				})
				.await
				.unwrap();
				until("offline startup did not report restoration failure", || {
					failures.get() > 0
				})
				.await;
				let (server, accepting) = directory_server(port, watches.clone()).await;
				until("directory restoration did not recover without a workspace edit", || {
					watches.get() == 2
				})
				.await;
				peer.close().await.unwrap();
				server.host().close(PendingWork::Cancel).await.unwrap();
				accepting.await.unwrap();
			})
			.await
			.expect("cold restoration proof exceeded its deadline");
		})
		.await;
}
