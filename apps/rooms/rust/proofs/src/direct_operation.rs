use rooms_application::{
	direct::operation::{Command, Context, LineKey},
	files::identity::Identity,
	files::FileDescription,
	room::message::LineId,
};
pub fn run() {
	let directory = "directory".into();
	let conversation = "conversation".into();
	let peer = "peer".into();
	let context = || Context {
		directory: &directory,
		conversation: &conversation,
		peer: &peer,
		registration: "registration",
	};
	let description = FileDescription::new("file".into(), "text/plain".into(), 1, 0, 0).unwrap();
	let a = [Identity {
		description: &description,
		digest: [1; 32],
	}];
	let b = [Identity {
		description: &description,
		digest: [2; 32],
	}];
	let send = Command::Send {
		text: "caption",
		files: &a,
	}
	.material(context())
	.unwrap();
	assert_eq!(
		send,
		Command::Send {
			text: "caption",
			files: &a
		}
		.material(context())
		.unwrap()
	);
	assert_ne!(
		send,
		Command::Send {
			text: "caption",
			files: &b
		}
		.material(context())
		.unwrap()
	);
	// Preserve the direct-v1 encoding when sharing attachment identity.
	let old = serde_json::to_string(&(
		"sendFiles",
		"direct-v1",
		&directory,
		&conversation,
		&peer,
		"registration",
		Option::<([u8; 16], u64)>::None,
		"caption",
		&[] as &[u32],
		[("file", "text/plain", 1usize, 0u32, 0u32, [1u8; 32])],
	))
	.unwrap();
	assert_eq!(send.as_str(), Some(old.as_str()));
	let key = LineKey {
		generation: [1; 16],
		line: LineId::new(1).unwrap(),
	};
	let old = Command::Withdraw { line: key }.material(context()).unwrap();
	assert_ne!(
		old,
		Command::Withdraw {
			line: LineKey {
				generation: [2; 16],
				..key
			}
		}
		.material(context())
		.unwrap()
	);
	let refile = |keep| {
		Command::Refile {
			line: key,
			text: "caption",
			keep,
			files: &a,
		}
		.material(context())
		.unwrap()
	};
	assert_ne!(refile(&[0, 1]), refile(&[1, 0]));
}
