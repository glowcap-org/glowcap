use super::*;
use crate::grants::ready;
use rooms_application::{
	documents::{SessionDocument, WriteFailure},
	session::{checkpoint::commands::results, state::*},
};
struct Memory {
	checkpoint: Vec<u8>,
	effects: Vec<u8>,
}
impl SessionStorage for Memory {
	type Error = ();
	async fn replace(&mut self, kind: SessionDocument, bytes: Vec<u8>) -> Result<(), WriteFailure<()>> {
		match kind {
			SessionDocument::Checkpoint => self.checkpoint = bytes,
			SessionDocument::Effects => self.effects = bytes,
			_ => panic!("unexpected state document"),
		}
		Ok(())
	}
}
fn text<const N: usize>(s: &str) -> Text<N, true> {
	Text::new(s.into()).unwrap()
}
fn commit(state: &mut SessionState, memory: &mut Memory, write: Prepared) -> Change {
	ready(write.persist(memory)).unwrap().commit(state).unwrap()
}
pub(super) fn check(fixture: &Value, routes: &impl Routes) {
	for row in fixture["applications"]
		.as_array()
		.unwrap()
		.iter()
		.filter(|r| r["name"] == r["kind"])
	{
		if !row["after"].is_string() {
			continue;
		}
		for restart in [false, true] {
			let mut state = SessionState::fresh([1; 32], [2; 16]);
			let mut memory = Memory {
				checkpoint: state.document(SessionDocument::Checkpoint).unwrap(),
				effects: state.document(SessionDocument::Effects).unwrap(),
			};
			let before = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
			let Admission::Write(write) = state.adopt(text("adopt"), 0, &"initial".into(), before).unwrap() else {
				panic!("fresh adoption");
			};
			commit(&mut state, &mut memory, write);
			let id = text("result");
			let kind = text(row["kind"].as_str().unwrap());
			let intent = text(row["intent"].as_str().unwrap());
			let returned = text(row["result"].as_str().unwrap());
			let material = "result material".into();
			let ResultAdmission::Write(write) = state
				.prepare_result(id.clone(), 1, &material, kind.clone(), intent.clone())
				.unwrap()
			else {
				panic!("fresh result");
			};
			commit(&mut state, &mut memory, write);
			let ResultRecorded::Write(write) = state.record_result(&id, Some(&material), returned).unwrap() else {
				panic!("fresh return");
			};
			commit(&mut state, &mut memory, write);
			let mut applications = 0;
			let mut changes = Vec::new();
			loop {
				if restart {
					state = SessionState::restore(&memory.checkpoint, &memory.effects, routes).unwrap();
				}
				let progress = state
					.advance_result(&id, |current, kind, intent, returned| {
						applications += 1;
						results::apply(current, kind, intent, returned, routes)
					})
					.unwrap();
				match progress {
					ResultProgress::Write(write) => changes.push(commit(&mut state, &mut memory, write).checkpoint),
					ResultProgress::Complete(revision) => {
						assert_eq!(revision, 2);
						break;
					}
				}
			}
			assert_eq!(
				changes,
				[None, Some(Impact::Realization), None],
				"{} changes",
				row["name"]
			);
			if !restart {
				assert_eq!(applications, 1, "normal execution applies once");
			}
			assert_eq!(
				state.checkpoint().unwrap().encode_for(Access::Admin).unwrap(),
				row["after"].as_str().unwrap()
			);
			assert!(matches!(
				state.prepare_result(id, 1, &material, kind, intent).unwrap(),
				ResultAdmission::Committed { revision: 2, .. }
			));
		}
	}
}
