use super::support::*;
use std::rc::Rc;

#[tokio::test]
async fn callback_session_projects_the_turn_and_clears_after_unwind() {
	LocalSet::new()
		.run_until(async {
			assert!(crate::current_session().unwrap().is_none());
			let server = listen("127.0.0.1:0").await.unwrap();
			let locator = server.locator().unwrap();
			let (caller, accepted) = tokio::join!(connect(&locator, ConnectOptions::default()), server.accept());
			let caller = caller.unwrap();
			let accepted = Rc::new(accepted.unwrap());
			let expected = accepted.clone();
			let root = accepted
				.publish("current", move |verb, _| {
					let arrived = crate::current_session().unwrap().expect("remote callback session");
					assert!(arrived.same_session(&expected));
					assert!(arrived.is_open());
					if verb == Some("panic") {
						panic!("callback unwind probe");
					}
					Ok(Argument::Void)
				})
				.unwrap();
			let service = accepted.clone();
			let serving = tokio::task::spawn_local(async move { service.serve().await });
			let target = caller.fetch("current").await.unwrap();
			caller.send(&target, "remote", &[]).await.unwrap();
			assert!(crate::current_session().unwrap().is_none());
			assert!(caller.send(&target, "panic", &[]).await.is_err());
			assert!(crate::current_session().unwrap().is_none());
			caller.send(&target, "remote", &[]).await.unwrap();
			let local_session = accepted.clone();
			let local = accepted
				.spawn_owned(move |_, _| {
					let current = crate::current_session().unwrap().expect("local turn session");
					assert!(current.same_session(&local_session));
					Ok(Argument::Void)
				})
				.unwrap();
			accepted.send(&local, "local", &[]).await.unwrap();
			assert!(crate::current_session().unwrap().is_none());
			let (second_caller, second_accepted) =
				tokio::join!(connect(&locator, ConnectOptions::default()), server.accept());
			let (second_caller, second_accepted) = (second_caller.unwrap(), second_accepted.unwrap());
			assert!(second_accepted.host().same_host(&accepted.host()));
			assert!(!second_accepted.same_session(&accepted));
			assert!(second_accepted.is_open());
			second_caller.close(crate::PendingWork::Cancel).await.unwrap();
			second_accepted.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(!second_accepted.is_open());
			drop((target, local));
			accepted.release(root).unwrap();
			caller.close(crate::PendingWork::Cancel).await.unwrap();
			accepted.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(!accepted.is_open());
			server.close().await.unwrap();
			server.host().close(crate::PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
		})
		.await;
}
