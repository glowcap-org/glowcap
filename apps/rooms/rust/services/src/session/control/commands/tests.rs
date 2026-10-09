//! A retained pending admission cannot serialize unrelated control clients.
use super::*;
use glowcap::{Argument, Host, PendingWork};
use std::{cell::RefCell, time::Duration};

#[tokio::test]
async fn pending_admission_leaves_other_commands_and_release_available() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([129; 32]).unwrap();
			let answer = Rc::new(RefCell::new(None));
			let endpoint = host
				.spawn({
					let host = host.clone();
					let answer = answer.clone();
					move |verb, args| match verb {
						"command" if args[0].as_str() == Some("held") => {
							assert!(answer.borrow().is_none(), "pending admission was redispatched");
							*answer.borrow_mut() = Some(host.defer_turn().unwrap());
							Ok(Argument::Void)
						}
						"command" | "effect-status" => Ok("committed".into()),
						_ => Err(format!("unexpected command observation: {verb}")),
					}
				})
				.unwrap();
			let workspace = Workspace::local(host.clone(), HostPlatform, endpoint);
			let commands = Commands::default();
			let args = vec!["standing".to_owned()];
			{
				let first = commands.submit(&workspace, "held", 1, "setStanding", &args);
				tokio::pin!(first);
				assert!(
					tokio::time::timeout(Duration::from_millis(20), &mut first)
						.await
						.is_err()
				);
				assert!(answer.borrow().is_some());
				let second = tokio::time::timeout(
					Duration::from_secs(1),
					commands.submit(&workspace, "other", 1, "setStanding", &args),
				)
				.await
				.unwrap()
				.unwrap();
				assert_eq!(second, EffectStatus::Committed);
				tokio::time::timeout(Duration::from_secs(1), commands.release("other"))
					.await
					.unwrap()
					.unwrap();
				answer
					.borrow_mut()
					.as_mut()
					.unwrap()
					.fulfill(&"committed".into())
					.unwrap();
				assert_eq!(first.await.unwrap(), EffectStatus::Committed);
			}
			commands.release("held").await.unwrap();
			commands.close().await.unwrap();
			drop((workspace, answer));
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
