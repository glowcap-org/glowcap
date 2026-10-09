//! A deadline lends the actual admission receiver without issuing another call.
use super::*;
use rooms_glowcap::client::workspace::{EffectStatus, Workspace};

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn expired_admission_wait_resumes_the_original_receiver() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(2_000, async {
				let host = Host::from_seed([126; 32]).unwrap();
				let calls = Rc::new(Cell::new(0));
				let answer = Rc::new(std::cell::RefCell::new(None));
				let endpoint = host
					.spawn({
						let host = host.clone();
						let calls = calls.clone();
						let answer = answer.clone();
						move |verb, args| match verb {
							"command" => {
								assert_eq!(args[0].as_str(), Some("pending"));
								assert_eq!(args[1].as_i64(), Some(1));
								calls.set(calls.get() + 1);
								*answer.borrow_mut() = Some(host.defer_turn().unwrap());
								Ok(Argument::Void)
							}
							"acquire-workspace" | "acquire-result-workspace" => {
								calls.set(calls.get() + 1);
								*answer.borrow_mut() = Some(host.defer_turn().unwrap());
								Ok(Argument::Void)
							}
							_ => panic!("unexpected admission method: {verb}"),
						}
					})
					.unwrap();
				let platform = Platform::default();
				let workspace = Workspace::local(host.clone(), platform.clone(), endpoint);
				let command = workspace
					.prepare_command("pending", 1, "setDraft", &["conversation".into(), "draft".into()])
					.await
					.unwrap();
				let mut submission = command.start_submission();
				for _ in 0..2 {
					assert!(submission.within(&platform, 2).await.is_none());
					assert_eq!(calls.get(), 1, "expired waits cannot replay admission");
				}
				answer
					.borrow_mut()
					.as_mut()
					.unwrap()
					.fulfill(&"pending".into())
					.unwrap();
				assert_eq!(submission.completed().await.unwrap(), EffectStatus::Pending);
				assert_eq!(submission.completed().await.unwrap(), EffectStatus::Pending);
				assert_eq!(calls.get(), 1);
				let intent = Intent::empty();
				let acquisition = workspace.prepare_acquisition(1, vec![], &[], &intent).unwrap();
				let result = command.prepare_result_acquisition(1, &[], &[], &intent).unwrap();
				for expected in 2..=3 {
					let mut waiting = if expected == 2 {
						acquisition.start_submission()
					} else {
						result.start_submission()
					};
					for _ in 0..2 {
						assert!(waiting.within(&platform, 2).await.is_none());
						assert_eq!(calls.get(), expected, "acquisition replayed after an expired wait");
					}
					answer.borrow_mut().as_mut().unwrap().fulfill(&Argument::Void).unwrap();
					waiting.completed().await.unwrap();
					waiting.completed().await.unwrap();
					assert_eq!(calls.get(), expected);
				}
				drop((answer, command, workspace, submission, acquisition, result));
				host.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("retained admission has bounded progress");
		})
		.await;
}
