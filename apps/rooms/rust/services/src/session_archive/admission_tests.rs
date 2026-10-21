use super::*;
use std::{
	future::Future,
	task::{Context, Waker},
};

#[tokio::test]
async fn waiting_erasure_gets_released_count_capacity_before_new_requests() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = Rc::new(
				glowcap::Runtime::open(glowcap::RuntimeConfig::providers([]))
					.await
					.unwrap(),
			);
			let backend = Memory::new();
			backend.blocked.set(true);
			let blocked = backend.blocked.clone();
			let gate = backend.gate.clone();
			let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), backend);
			let mut replies = Vec::new();
			for _ in 0..MAX_PENDING {
				replies.push(owner.put(line(LineState::Present), vec![]).unwrap());
			}
			let source = "source".into();
			let mut erasing = Box::pin(owner.clear_source_when_ready(&source));
			assert!(
				erasing
					.as_mut()
					.poll(&mut Context::from_waker(Waker::noop()))
					.is_pending()
			);
			// Retire real admitted custody without polling the erase again. New work
			// cannot steal the credit assigned to the earlier asynchronous waiter. status-allow: event or source ordering
			let mut execution = Box::pin(worker.run());
			let mut context = Context::from_waker(Waker::noop());
			assert!(execution.as_mut().poll(&mut context).is_pending());
			gate.notify_one();
			assert!(execution.as_mut().poll(&mut context).is_pending());
			assert_eq!(replies.remove(0).wait().await.unwrap(), 1);
			assert!(owner.read(Filter::default()).is_err());
			blocked.set(false);
			gate.notify_one();
			let task = tokio::task::spawn_local(execution);
			erasing.await.unwrap();
			for reply in replies {
				reply.wait().await.unwrap();
			}
			assert!(owner.read(Filter::default()).unwrap().wait().await.unwrap().is_empty());
			owner.close().await.unwrap();
			task.await.unwrap();
			runtime.close(glowcap::PendingWork::Cancel).await.unwrap();
		})
		.await;
}
