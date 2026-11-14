//! A room's name is shown unescaped in every reader's display, and a durable
//! name derives its link's token from a label that NUL separates. The server
//! refuses a name with control or direction characters at every verb that
//! takes a new one.
use super::*;
use rooms_application::room::authority;
use rooms_testing::scratch::Scratch;

/// Names whose bytes spell the label another room's steward or manager
/// derives from, and one that only carries a control or direction character.
const SPELLED: [&str; 5] = [
	"steward\u{0}vault",
	"manager\u{0}0\u{0}vault",
	"bell\u{7}room",
	"flipped\u{202e}name",
	"arabic\u{61c}mark",
];

/// The refusal's own words, which no other failure of these verbs shares.
const REFUSAL: &str = "may not contain control or text-direction characters";

fn refused<T: std::fmt::Debug, E: std::fmt::Display>(asked: Result<T, E>, what: &str) {
	match asked {
		Ok(answer) => panic!("{what} was answered {answer:?}"),
		Err(refusal) => assert!(refusal.to_string().contains(REFUSAL), "{what}: {refusal}"),
	}
}

#[tokio::test]
async fn a_new_room_name_with_control_or_direction_characters_is_refused_everywhere() {
	rooms_testing::local_set::run_within(Duration::from_secs(30), async {
		let temp = Scratch::create("server");
		let running = super::super::start_with(
			temp.to_path_buf(),
			tcp(),
			crate::server::Asked::parse("peering").unwrap(),
		)
		.await;
		let runtime = runtime().await;
		let client = Client::new(
			runtime
				.connect(
					&glowcap::parse_locator(&running.location).unwrap(),
					ConnectOptions::default(),
				)
				.await
				.unwrap(),
			HostPlatform,
		);
		let directory = Directory::fetch(client.clone()).await.unwrap();
		let vault = directory
			.open_managed("Vault", RoomPolicy::Open, &RecoveryKey::from_entropy([71; 16]))
			.await
			.unwrap();
		let manager = client.enliven(&vault.manager_link).await.unwrap();
		let peering = client.session().fetch(&running.capabilities[0].swiss).await.unwrap();
		for (n, name) in SPELLED.into_iter().enumerate() {
			refused(directory.open(name).await, &format!("open {name:?}"));
			let managed = directory
				.open_managed(
					name,
					RoomPolicy::Moderated,
					&RecoveryKey::from_entropy([72 + n as u8; 16]),
				)
				.await;
			refused(managed.map(|_| ()), &format!("openManaged {name:?}"));
			let [visibility, entry, speaking] = RoomPolicy::Open.modes();
			let renamed = client
				.session()
				.send(
					&manager,
					authority::SET_POLICY,
					&[visibility.into(), entry.into(), speaking.into(), name.into()],
				)
				.await;
			refused(renamed, &format!("setRoomPolicy {name:?}"));
			refused(
				client
					.session()
					.send(
						&peering,
						"publishDurableRoom",
						&[name.into(), vault.room.clone().into()],
					)
					.await,
				&format!("publishDurableRoom {name:?}"),
			);
		}
		drop((vault, directory));
		closing_tolerated(client.session().close(PendingWork::Cancel).await);
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}
