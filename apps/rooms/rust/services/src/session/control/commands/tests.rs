//! A retained pending admission cannot serialize unrelated control clients.
use super::*;
use glowcap::{Argument, Host, PendingWork};
use std::{cell::RefCell, time::Duration};

#[tokio::test]
async fn refused_admission_retires_without_a_receipt_and_unknown_admission_stays_owned() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([130; 32]).unwrap();
			let endpoint = host
				.spawn(|verb, args| match verb.ok_or("fixture requires a method")? {
					"command" if args[0].as_str() == Some("refused") => {
						Err("rate-limited: retry-after-ms=1000; scope=message; owner=session".into())
					}
					"command" => Err("admission observation was lost".into()),
					_ => Err("no receipt exists for this admission".into()),
				})
				.unwrap();
			let workspace = Workspace::local(host.clone(), HostPlatform, endpoint);
			let commands = Commands::default();
			let args = vec!["standing".to_owned()];
			let refusal = commands
				.submit(&workspace, "refused", 1, "setStanding", &args)
				.await
				.unwrap_err();
			assert_eq!(refusal.class, "rate-limited");
			commands.release("refused").await.unwrap();
			assert!(commands.0.lock().await.is_empty());
			commands
				.submit(&workspace, "unknown", 1, "setStanding", &args)
				.await
				.unwrap_err();
			assert!(commands.release("unknown").await.is_err());
			assert!(commands.0.lock().await.contains_key("unknown"));
			commands.close().await.unwrap();
			drop(workspace);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

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
					move |verb, args| match verb.ok_or("fixture requires a method")? {
						"command" if args[0].as_str() == Some("held") => {
							assert!(answer.borrow().is_none(), "pending admission was redispatched");
							*answer.borrow_mut() = Some(host.defer_turn().unwrap());
							Ok(Argument::Void)
						}
						"command" | "effect-status" => Ok("committed".into()),
						_ => Err(format!("unexpected command observation: {verb:?}")),
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
