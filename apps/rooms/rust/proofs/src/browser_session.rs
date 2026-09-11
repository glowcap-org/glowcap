//! The native session command owner, running with browser entropy and storage.
use rooms_application::{
	grants::Access,
	session::{
		checkpoint::{
			commands::{Command, Facts},
			reconciliation::Fact,
		},
		state::Change,
	},
	text::DocumentText,
};
use rooms_browser::platform::Platform;
use rooms_runtime::{
	clock::Clock,
	documents::VolatileDocuments,
	session_commands::{FactScope, SessionCommands, SessionEvents},
	session_state::{DurableSession, LoadStatus, SessionView},
};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::prelude::*;

struct Events {
	revisions: Rc<RefCell<Vec<u64>>>,
	issues: tokio::sync::mpsc::Sender<bool>,
}
impl SessionEvents for Events {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, String> {
		Ok(())
	}

	fn facts(&self) -> impl Facts {}
	fn changed(&mut self, change: Change, _: &SessionView) {
		self.revisions.borrow_mut().push(change.revision);
	}
	fn reconciliation_issue(&mut self, _: &Fact, error: Option<&str>) {
		self.issues.try_send(error.is_some()).unwrap();
	}
}
fn text<const N: usize, const REQUIRED: bool>(value: &str) -> rooms_application::fields::Text<N, REQUIRED> {
	rooms_application::fields::Text::new(value.into()).unwrap()
}
fn room(directory: &str, conversation: &str) -> Vec<DocumentText> {
	vec![serde_json::json!({"locator":directory,"nick":"browser","conversation":{
		"kind":"room","id":conversation,"directory":directory,"name":conversation,
		"held":false,"standing":null,"draft":""}})
	.to_string()
	.into()]
}

#[wasm_bindgen]
pub async fn rooms_browser_session_contract() {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			let platform = Platform::new().unwrap();
			let mut state = DurableSession::new(VolatileDocuments::default(), platform.clone());
			assert!(matches!(state.load().await.unwrap(), LoadStatus::Ready));
			let identity = *state.state().unwrap().identity_seed().unwrap();
			assert!(matches!(state.load().await.unwrap(), LoadStatus::Ready));
			assert_eq!(state.state().unwrap().identity_seed().unwrap(), &identity);
			let (commands, worker) = SessionCommands::open(state, platform.clone()).await.unwrap();
			let view = commands.view();
			let revisions = Rc::new(RefCell::new(Vec::new()));
			let (issue, mut issues) = tokio::sync::mpsc::channel(4);
			let events = Events {
				revisions: revisions.clone(),
				issues: issue,
			};
			let execute = async {
				// Abandoning the reply does not abandon admitted application work.
				drop(
					commands
						.prepare_command(text("unobserved"), 0, Command::SetStanding, vec!["present".into()])
						.unwrap()
						.send()
						.unwrap(),
				);
				let first = room("ocapn://first.id", "one");
				for (at, args) in [
					first.clone(),
					room("ocapn://first.id", "two"),
					room("ocapn://second.id", "three"),
				]
				.into_iter()
				.enumerate()
				{
					assert_eq!(
						commands
							.prepare_command(text(&format!("join-{at}")), at as u64 + 1, Command::JoinRoom, args)
							.unwrap()
							.send()
							.unwrap()
							.wait()
							.await
							.unwrap(),
						at as u64 + 2
					);
				}
				assert_eq!(
					commands
						.prepare_command(text("join-0"), 999, Command::JoinRoom, first)
						.unwrap()
						.send()
						.unwrap()
						.wait()
						.await
						.unwrap(),
					2
				);
				let encoded = view
					.read(|s| s.checkpoint().unwrap().encode_for(Access::Admin).unwrap())
					.unwrap();
				let checkpoint: serde_json::Value = serde_json::from_str(&encoded).unwrap();
				assert_eq!(checkpoint["directories"].as_array().unwrap().len(), 2);
				assert_eq!(checkpoint["conversations"].as_array().unwrap().len(), 3);
				// A failed live fact uses the actual browser clock/timer for retry.
				// Retiring its producer then wakes that backoff without another retry.
				let scope = FactScope::new();
				let before = platform.now();
				let bad = Fact::DirectAccepted {
					conversation: text("absent"),
					directory: text("missing"),
					peer: text("peer"),
					registration: text("bad"),
				};
				assert!(commands
					.prepare_scoped_fact(bad, &scope)
					.unwrap()
					.send()
					.unwrap()
					.wait()
					.await
					.is_err());
				assert_eq!(issues.recv().await, Some(true));
				assert_eq!(issues.recv().await, Some(true));
				assert!(platform.now() >= before + std::time::Duration::from_secs(1));
				scope.retire();
				assert_eq!(issues.recv().await, Some(false));
				commands.close().await.unwrap();
			};
			let (run, ()) = tokio::join!(worker.run(events), execute);
			run.unwrap();
			assert_eq!(*revisions.borrow(), [1, 2, 3, 4]);
			assert!(view.read(|_| ()).is_err());
			// Replacing a tab's volatile owner creates a fresh session identity.
			let mut next = DurableSession::new(VolatileDocuments::default(), platform);
			assert!(matches!(next.load().await.unwrap(), LoadStatus::Ready));
			assert_ne!(next.state().unwrap().identity_seed().unwrap(), &identity);
		})
		.await;
}
