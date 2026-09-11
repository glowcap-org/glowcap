use rooms_application::{
	files::{identity::Identity, FileDescription},
	room::{
		message::LineId,
		operation::{Command, Context, Line},
	},
};

pub fn run() {
	let description = FileDescription::new("file".into(), "text/plain".into(), 1, 0, 0).unwrap();
	let files = [Identity {
		description: &description,
		digest: [1; 32],
	}];
	let changed = [Identity {
		description: &description,
		digest: [2; 32],
	}];
	let entry = "room-entry".into();
	let context = || Context {
		directory: "directory",
		conversation: "conversation",
		room: "room",
		held: true,
		entry: Some(&entry),
	};
	let line = Line {
		incarnation: [1; 16],
		membership: 1,
		id: LineId::new(1).unwrap(),
	};
	let material = |line, keep, files| {
		Command::Refile {
			line,
			caption: "caption",
			keep,
			files,
		}
		.material(context())
		.unwrap()
	};
	let original = material(line, &[0, 1], &files);
	assert_ne!(original, material(line, &[1, 0], &files));
	assert_ne!(original, material(line, &[0, 1], &changed));
	assert_ne!(
		original,
		material(
			Line {
				id: LineId::new(2).unwrap(),
				..line
			},
			&[0, 1],
			&files
		)
	);
	assert_ne!(original, material(Line { membership: 2, ..line }, &[0, 1], &files));
	assert_ne!(
		original,
		material(
			Line {
				incarnation: [2; 16],
				..line
			},
			&[0, 1],
			&files
		)
	);
	let command = Command::Send {
		caption: "caption",
		files: &files,
	};
	let other = "other-entry".into();
	assert_ne!(
		command.material(context()).unwrap(),
		command
			.material(Context {
				entry: Some(&other),
				..context()
			})
			.unwrap()
	);
	assert_ne!(
		command.material(context()).unwrap(),
		command
			.material(Context {
				directory: "other",
				..context()
			})
			.unwrap()
	);
}

#[test]
fn file_commands_distinguish_bytes_selection_and_membership() {
	run();
	super::direct_operation::run();
}
