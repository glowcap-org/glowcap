//! Fresh processes recover credentials using the physically saved Loam witness.
use super::*;
use glowcap::loam::{Resource, Store};
use rooms_services::documents::DocumentFile;
use std::{path::Path, sync::Arc};

#[tokio::test]
async fn bridge_loam_witness_recovers_credentials_after_process_exit() {
	if let Some(path) = std::env::var_os("GLOWCAP_BRIDGE_LOAM_RESTART_PATH") {
		tokio::task::LocalSet::new().run_until(phase(Path::new(&path))).await;
		return;
	}
	let database = Database::new("bridge-physical-recovery");
	for phase in ["submit", "recover", "forgotten"] {
		let mut child = std::process::Command::new(std::env::current_exe().unwrap())
			.args([
				"bridge_loam_witness_recovers_credentials_after_process_exit",
				"--nocapture",
			])
			.env("GLOWCAP_BRIDGE_LOAM_RESTART_PATH", database.path())
			.env("GLOWCAP_BRIDGE_LOAM_RESTART_PHASE", phase)
			.spawn()
			.unwrap();
		let status = environment::within(15_000, async {
			loop {
				if let Some(status) = child.try_wait().unwrap() {
					break status;
				}
				tokio::time::sleep(std::time::Duration::from_millis(10)).await;
			}
		})
		.await;
		if status.is_none() {
			child.kill().unwrap();
			child.wait().unwrap();
		}
		assert!(
			status.expect("bridge recovery child deadline").success(),
			"bridge {phase}"
		);
	}
	database.remove();
}

async fn phase(path: &Path) {
	environment::within(12_000, async {
		let phase = std::env::var("GLOWCAP_BRIDGE_LOAM_RESTART_PHASE").unwrap();
		let first = phase == "submit";
		let directory =
			Arc::new(rooms_platform::storage::Directory::open(path.to_owned(), ".bridge-proof.lock").unwrap());
		let store_path = path.join("loam");
		if first {
			std::fs::create_dir(&store_path).unwrap();
		}
		let mut schemas = managed::schemas();
		schemas.push(BRIDGE);
		let limits = managed::production_limits().unwrap();
		let mut store = Store::open(&store_path, [111; 16], first, 256 * 1024 * 1024, &schemas, limits).unwrap();
		let policy = rooms_glowcap::policy::descriptor().unwrap();
		let resource = |name: &str, schema: Schema, payload: &[u8]| {
			let file = path.join(name);
			if first {
				let resource = store
					.create_resource(&policy, schema, session::KIND, payload, 3)
					.unwrap();
				std::fs::write(file, resource.encode()).unwrap();
				resource
			} else {
				Resource::decode(std::fs::read(file).unwrap().try_into().unwrap())
			}
		};
		let root_resource = resource(
			"root",
			schemas[0],
			&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(),
		);
		let access_resource = resource("access", BRIDGE, b"access");
		let seat_resource = resource("seat", BRIDGE, b"seat");
		let host = Host::from_seed([161; 32]).unwrap();
		let platform = Platform::default();
		let owner = managed::Session::new(
			host.clone(),
			platform.clone(),
			std::num::NonZeroUsize::new(limits.forward_reply_bytes).unwrap(),
		);
		let calls = Rc::new(Cell::new(0));
		let registration = Registration {
			schema: BRIDGE.id,
			version: 1,
			graph: None,
			methods: [rooms_application::bridge::ASK, rooms_application::bridge::SUBMIT]
				.into_iter()
				.map(|verb| Method {
					verb: verb.into(),
					retry: Retry::Idempotent,
				})
				.collect(),
			content: Box::new(Bridge {
				form: Rc::new(RefCell::new(form())),
				calls: calls.clone(),
				unknown: Rc::new(Cell::new(false)),
			}),
		};
		let mut attachment = store.attach(&host, vec![owner.registration(), registration]).unwrap();
		attachment.start_live(None, 128).unwrap();
		let (root, control) = attachment.restore(root_resource).unwrap();
		owner.bind(root.clone(), control).unwrap();
		owner.initialize().await.unwrap();
		owner
			.configure_credentials(DocumentFile::bridge_secrets(directory.clone()))
			.await
			.unwrap();
		let terms = policy
			.value_for_kind(
				session::KIND,
				&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
				&[],
			)
			.unwrap();
		// Replay the original derivation receipt, rather than minting equal policy
		// access and using it to authenticate another source's saved identity.
		let pair = host
			.send(
				&root,
				"derive-managed",
				&terms.managed_derive_arguments(1, 1, ControlPowers::default()),
			)
			.await
			.unwrap();
		let source = Ref::try_from(&pair.as_list().unwrap()[0]).unwrap();
		let workspace = Workspace::local(host.clone(), platform, source);
		let snapshot = workspace.snapshot().await.unwrap();
		let mut intent = if first {
			Case::kick().workspace(1)
		} else {
			snapshot.intent
		};
		let access_key = custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap());
		if phase != "forgotten" {
			let (access, _) = attachment.restore(access_resource).unwrap();
			let (seat, _) = attachment.restore(seat_resource).unwrap();
			if first {
				for role in [custody::Role::DirectoryAccess, custody::Role::RoomAccess] {
					owner.import(coordinate(role, 1), access.clone(), None).await.unwrap();
				}
			}
			let slot = if first { 1 } else { 2 };
			owner
				.import(coordinate(custody::Role::RoomSeat, slot), seat, None)
				.await
				.unwrap();
			let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
				panic!("room")
			};
			room.id = Text::new("room".into()).unwrap();
			room.moderator = None;
			room.access = Some(access_key);
			room.seat = Some(seat_key(slot));
			owner.replace_workspace(&intent).await.unwrap();
		}
		match phase.as_str() {
			"submit" => {
				let request = bridge::Request {
					bridge: bridge::Intent {
						declaration: form(),
						action: rooms_application::bridge::Id::new("apply".into()).unwrap(),
						answers: Answers::decode("{\"name\":\"sender\"}").unwrap(),
					},
					operation: Text::new("physical-original".into()).unwrap(),
					base: SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap(),
					room: Text::new("room".into()).unwrap(),
					seat: seat_key(1),
					access: Some(coordinate(custody::Role::RoomAccess, 1)),
					credentials: Some(serde_json::from_str("\"0123456789abcdef0123456789abcdef\"").unwrap()),
					reapply: None,
				};
				let command = workspace
					.prepare_bridge(
						&request,
						&Answers::decode("{\"password\":\"private credential\"}").unwrap(),
					)
					.unwrap();
				command.submit().await.unwrap();
				assert_eq!(terminal(&command).await, EffectStatus::Committed);
				assert_eq!(calls.get(), 1);
				// Do not run Rust Drop or an orderly close. The next process must
				// recover the exact committed witness and physical credential file.
				std::process::exit(0);
			}
			"recover" => {
				assert_eq!(calls.get(), 0, "cold recovery must not resubmit the original effect");
				let command = workspace
					.prepare_bridge_reapplication(
						"physical-reapply",
						workspace.snapshot().await.unwrap().revision,
						"room",
					)
					.await
					.unwrap();
				command.submit().await.unwrap();
				assert_eq!(terminal(&command).await, EffectStatus::Committed);
				assert_eq!(
					calls.get(),
					1,
					"the saved exact identity applies once to the fresh seat"
				);
				let forget = workspace
					.prepare_forget_bridge(workspace.snapshot().await.unwrap().revision, "room")
					.await
					.unwrap();
				forget.submit().await.unwrap();
			}
			"forgotten" => {
				assert!(
					workspace
						.prepare_bridge_reapplication("forgotten", workspace.snapshot().await.unwrap().revision, "room")
						.await
						.is_err()
				);
				let bytes = std::fs::read_to_string(path.join("bridge-secrets.json")).unwrap();
				assert!(
					!bytes.contains("private credential"),
					"physical erasure survives another process"
				);
				assert_eq!(calls.get(), 0);
			}
			_ => panic!("unknown bridge recovery phase"),
		}
		owner.close().await.unwrap();
		attachment.close().await.unwrap();
		host.close(PendingWork::Cancel).await.unwrap();
		drop((workspace, owner, attachment));
		store.close().unwrap();
	})
	.await
	.expect("physical bridge journey deadline");
}
