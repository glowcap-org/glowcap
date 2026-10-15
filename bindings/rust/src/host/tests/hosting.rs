use super::*;

#[tokio::test]
async fn local_callback_retains_and_retires_its_received_capability_occurrence() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let released = Rc::new(Cell::new(false));
			let probe = DropProbe(released.clone());
			let target = host
				.spawn(move |_, _| {
					let _retained = &probe;
					Ok(19.into())
				})
				.unwrap();
			let received = Rc::new(RefCell::new(None));
			let held = received.clone();
			let receiver = host
				.spawn(move |verb, args| {
					if verb == "hold" {
						*held.borrow_mut() = Some(Ref::try_from(&args[0]).unwrap());
					}
					Ok(Argument::Void)
				})
				.unwrap();
			host.send(&receiver, "hold", &[target.clone().into()]).await.unwrap();
			drop(target);
			let retained = received.borrow_mut().take().unwrap();
			assert_eq!(host.send(&retained, "get", &[]).await.unwrap().as_i64(), Some(19));
			assert!(!released.get(), "the received occurrence owns the target");
			drop(retained);
			host.send(&receiver, "barrier", &[]).await.unwrap();
			assert!(
				released.get(),
				"dropping the received occurrence releases its FFI retain"
			);
			drop(receiver);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn hosted_callback_uses_its_registered_host_without_an_adapter_bracket() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let called = Rc::new(Cell::new(false));
			let factory_host = host.clone();
			let observed = called.clone();
			let factory = host
				.spawn(move |_, _| {
					assert!(crate::current_session().unwrap().is_none());
					// This must use turn-time spawning on the callback's own Host.
					let child = factory_host.spawn(|_, _| Ok(Argument::Void)).unwrap();
					observed.set(true);
					Ok(child.into())
				})
				.unwrap();
			host.tell(&factory, "make", &[]).unwrap();
			// FFI settlement and release may pump callbacks synchronously.
			// Drive the same FFI pump without the adapter's TLS bracket.
			crate::action::park(&host.shared).unwrap();
			assert!(called.get(), "FFI callback must find its registration owner");
			drop(factory);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn host_notifications_keep_admitted_work_after_target_release_without_an_answer() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let calls = Rc::new(Cell::new(0));
			let released = Rc::new(Cell::new(false));
			let probe = DropProbe(released.clone());
			let actor = host
				.spawn({
					let calls = calls.clone();
					move |verb, args| {
						let _retained = &probe;
						assert!(crate::current_session().unwrap().is_none());
						assert_eq!(verb, "notify");
						assert_eq!(args[0].as_str(), Some("held payload"));
						calls.set(calls.get() + 1);
						Ok(Argument::Void)
					}
				})
				.unwrap();
			host.tell(&actor, "notify", &["held payload".into()]).unwrap();
			drop(actor);
			crate::finalizer::drain();
			assert!(!released.get(), "queued work owns its target independently");
			let barrier = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
			host.send(&barrier, "barrier", &[]).await.unwrap();
			assert_eq!(calls.get(), 1);
			crate::finalizer::drain();
			host.send(&barrier, "collect", &[]).await.unwrap();
			assert!(released.get(), "notification retires target and input custody");
			drop(barrier);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn publication_of_held_actor_keeps_exact_identity_and_its_own_root() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let released = Rc::new(Cell::new(false));
			let probe = DropProbe(released.clone());
			let actor = host
				.spawn(move |_, _| {
					let _retained = &probe;
					Ok(19.into())
				})
				.unwrap();
			let name = host
				.publish_reference_with_entropy(&actor, [9; Host::DURABLE_ENTROPY_BYTES])
				.unwrap();
			assert!(
				host.publish_reference_with_entropy(&actor, [9; Host::DURABLE_ENTROPY_BYTES])
					.is_err()
			);
			assert_eq!(host.send(&actor, "identity", &[]).await.unwrap().as_i64(), Some(19));
			drop(actor);
			crate::finalizer::drain();
			assert!(!released.get(), "publication keeps its own actor root");
			assert!(host.remove_durable(&name).unwrap());
			crate::finalizer::drain();
			let next = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
			host.send(&next, "collect", &[]).await.unwrap();
			assert!(released.get(), "removing publication releases the last root");
			drop(next);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn host_spawn_owns_local_roots_and_factories_without_a_session_or_publication() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let released = Rc::new(Cell::new(false));
			let factory_host = host.clone();
			let probe = DropProbe(released.clone());
			let factory = host
				.spawn(move |_, _| {
					let _retained = &probe;
					assert!(crate::current_session().unwrap().is_none());
					let child = factory_host.spawn(|_, args| Ok(Argument::List(args.to_vec()))).unwrap();
					Ok(child.into())
				})
				.unwrap();
			let child = Ref::try_from(&host.send(&factory, "make", &[]).await.unwrap()).unwrap();
			let result = host.send(&child, "echo", &[19.into()]).await.unwrap();
			assert_eq!(result.as_list().unwrap()[0].as_i64(), Some(19));
			drop((child, factory));
			crate::finalizer::drain();
			let next = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
			host.send(&next, "next-turn", &[]).await.unwrap();
			assert!(released.get(), "last local root collects its actor before Host close");
			drop(next);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
