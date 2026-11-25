//! A directory of notes is the bot's own: a write makes it readable by its
//! owner alone, narrows one that others can read, and refuses a link or a
//! file planted where it belongs, for every write, read, listing, rename, and
//! removal.
use super::*;
use rooms_testing::scratch::Scratch;

const NOTES: Notes = Notes::new("notes", "notes-count", |operation| operation.to_owned());

fn operation(index: usize) -> String {
	format!("{index:032x}")
}

fn mode(path: &Path) -> u32 {
	std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_directory_of_notes_is_made_and_kept_for_its_owner_alone() {
	let scratch = Scratch::create("bot-notes-owner");
	NOTES.write(&scratch, &operation(1), &1).unwrap();
	assert_eq!(mode(&scratch.join("notes")), 0o700);
	assert_eq!(NOTES.listed(&scratch).unwrap().live, [operation(1)]);
	std::fs::set_permissions(scratch.join("notes"), std::fs::Permissions::from_mode(0o755)).unwrap();
	NOTES.write(&scratch, &operation(2), &2).unwrap();
	assert_eq!(
		mode(&scratch.join("notes")),
		0o700,
		"a directory others can read is narrowed"
	);
}

#[test]
fn a_link_or_a_file_where_the_notes_belong_is_refused() {
	let scratch = Scratch::create("bot-notes-link");
	let elsewhere = scratch.join("elsewhere");
	std::fs::create_dir(&elsewhere).unwrap();
	std::os::unix::fs::symlink(&elsewhere, scratch.join("notes")).unwrap();
	assert!(NOTES.write(&scratch, &operation(1), &1).is_err());
	assert_eq!(
		std::fs::read_dir(&elsewhere).unwrap().count(),
		0,
		"nothing is written through the link"
	);
	std::fs::write(elsewhere.join(format!("{}.json", operation(2))), "2").unwrap();
	assert!(NOTES.listed(&scratch).is_err(), "a listing through the link is refused");
	assert!(NOTES.read::<u32>(&scratch, &operation(2), State::Live).is_err());
	let live = Name::live(&operation(2));
	assert!(
		NOTES.remove(&scratch, &live).is_err(),
		"a removal through the link is refused"
	);
	let unsettled = Name::serving(&operation(2), State::Unsettled);
	assert!(
		NOTES.rename(&scratch, &live, &unsettled, "renaming").is_err(),
		"a rename through the link is refused"
	);
	assert_eq!(
		std::fs::read_dir(&elsewhere).unwrap().count(),
		1,
		"the note through the link is left where it is"
	);
	std::fs::remove_file(scratch.join("notes")).unwrap();
	std::fs::write(scratch.join("notes"), "").unwrap();
	assert!(
		NOTES.write(&scratch, &operation(1), &1).is_err(),
		"a file is no directory of notes"
	);
}
