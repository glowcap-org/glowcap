use super::*;
use std::cell::Cell;

struct DropProbe(Rc<Cell<bool>>);

impl Drop for DropProbe {
	fn drop(&mut self) {
		self.0.set(true);
	}
}

#[test]
fn public_close_is_a_safe_boundary_for_deferred_driver_release() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let attempts = Rc::new(Cell::new(0));
		let completions = Rc::new(Cell::new(0));
		crate::finalizer::park_test_release(Rc::clone(&attempts), Rc::clone(&completions), 0);
		Host::new_host().close(PendingWork::Cancel).await.unwrap();
		assert_eq!(attempts.get(), 1);
		assert_eq!(completions.get(), 1);
	});
}

// A hosted behavior may retain a Host clone. Native Host ownership of the
// behavior then closes an Rc cycle; explicit close must release the native
// actor row and break that cycle instead of waiting for HostShared::drop.
#[test]
fn close_breaks_a_hosted_behavior_host_cycle() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		let captured_host = host.clone();
		let dropped = Rc::new(Cell::new(false));
		let dropped_by_behavior = Rc::clone(&dropped);
		host.publish_giftable("cycle", move || {
			let retained_host = captured_host.clone();
			let probe = DropProbe(Rc::clone(&dropped_by_behavior));
			Box::new(move |_verb, _args| {
				let _keep_host = &retained_host;
				let _keep_probe = &probe;
				Ok(Argument::Void)
			})
		})
		.unwrap();

		host.close(crate::PendingWork::Cancel).await.unwrap();
		assert!(host.shared.raw.get().is_null());
		assert!(dropped.get(), "native Host release drops the captured behavior");
	});
}

#[test]
fn closed_host_publication_verbs_return_their_refusal() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		host.close(crate::PendingWork::Cancel).await.unwrap();

		let publish = host
			.publish_giftable("late", || Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap_err();
		assert_eq!(publish.code(), sys::ERR_CLOSED);
		let durable = host
			.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap_err();
		assert_eq!(durable.code(), sys::ERR_CLOSED);
		assert_eq!(host.remove_durable("late").unwrap_err().code(), sys::ERR_CLOSED);
		assert_eq!(host.unpublish_giftable("late").unwrap_err().code(), sys::ERR_CLOSED);
	});
}

#[test]
fn host_publication_results_cover_success_and_absence() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		host.publish_giftable("alias", || Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap();
		assert!(host.unpublish_giftable("alias").unwrap());
		assert!(!host.unpublish_giftable("alias").unwrap());

		let swiss = host
			.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap();
		assert!(host.remove_durable(&swiss).unwrap());
		assert!(!host.remove_durable(&swiss).unwrap());
		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
}

#[test]
fn cancel_dial_action_joins_its_ticketed_task() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		let dropped = Rc::new(Cell::new(false));
		let task_dropped = Rc::clone(&dropped);
		assert!(host
			.shared
			.spawn_dial_task(1, move |_host| async move {
				let _probe = DropProbe(task_dropped);
				std::future::pending::<()>().await;
			})
			.unwrap());
		tokio::task::yield_now().await;

		host.shared.cancel_dial_task(1).await.unwrap();
		assert!(dropped.get(), "CANCEL_DIAL joins the ticketed DIAL future");
		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
}

#[test]
fn panicking_dial_task_reaches_the_host_close_barrier() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		assert!(host
			.shared
			.spawn_dial_task(1, move |_host| async move {
				panic!("dial executor panic");
			})
			.unwrap());
		tokio::task::yield_now().await;
		tokio::task::yield_now().await;

		let error = host.close(crate::PendingWork::Cancel).await.unwrap_err();
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error
			.message()
			.is_some_and(|message| message.contains("dial executor panic")));
	});
}

#[test]
fn panicking_actor_cell_drop_is_contained_and_diagnosed() {
	struct PanicOnDrop;
	impl Drop for PanicOnDrop {
		fn drop(&mut self) {
			panic!("actor cell destructor panic");
		}
	}

	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	let diagnostics = local.block_on(&runtime, async {
		let host = Host::new_host();
		host.publish_giftable("panicking-drop", move || {
			let guard = PanicOnDrop;
			Box::new(move |_verb, _args| {
				let _keep_captured = &guard;
				Ok(Argument::Void)
			})
		})
		.unwrap();
		host.close(crate::PendingWork::Cancel).await.unwrap();
		host.take_failures().unwrap()
	});

	assert!(diagnostics.iter().any(|failure| {
		failure.operation == "actor-cell.drop" && failure.primary_message == "actor cell destructor panic"
	}));
}

#[test]
fn refused_publication_attaches_panicking_actor_cell_drop() {
	struct PanicOnDrop;
	impl Drop for PanicOnDrop {
		fn drop(&mut self) {
			panic!("refused actor cell destructor panic");
		}
	}

	let host = Host::new_host();
	let guard = PanicOnDrop;
	let cell = Box::into_raw(Box::new(ActorCell {
		behavior: RefCell::new(outcome_behavior(move |_verb, _args| {
			let _keep_captured = &guard;
			Ok(Argument::Void)
		})),
		context: host.shared.retained_context().unwrap(),
		diagnostic_id: host.shared.diagnostic_id(),
	}));
	let cleanup = unsafe { reclaim_refused_cell(sys::ERR_INVALID_ARGUMENT, cell) };
	let error = crate::retain_cleanup_failure(
		Error::with_detail(sys::ERR_INVALID_ARGUMENT, "publication refused".to_string()),
		cleanup,
	);

	assert_eq!(error.code(), sys::ERR_INVALID_ARGUMENT);
	assert_eq!(error.secondary_error_count(), 1);
	assert!(error.secondary_errors()[0]
		.message()
		.is_some_and(|message| message.contains("refused actor cell destructor panic")));
	// Rollback did not poison or consume the Host.
	host.publish_giftable("still-live", || Box::new(|_verb, _args| Ok(Argument::Void)))
		.unwrap();
}

#[test]
fn close_waits_for_an_admitted_action_drain_before_native_release() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		host.shared.schedule_kick().unwrap();
		assert_eq!(host.shared.owned_tasks.get(), 1);

		host.request_close();
		assert!(
			!host.shared.raw.get().is_null(),
			"close released native state beneath an admitted action drain"
		);
		host.close(crate::PendingWork::Cancel).await.unwrap();
		assert!(host.shared.raw.get().is_null());
		assert_eq!(host.shared.owned_tasks.get(), 0);
	});
}

// Host-level FINISH (ADR-0114): a negotiating session is admitted pending
// work, so a finite grace expires and the close barrier reports its
// timeout. The barrier retains that terminal outcome, so a repeated close
// observes the same timeout instead of silently succeeding.
#[test]
fn a_finite_finish_close_reports_its_timeout_and_a_repeat_observes_it() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = Host::new_host();
		let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
		let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
		let mut ptr = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_dialed_locator(host.shared.raw(), owned.borrow_view().unwrap(), &mut ptr)
		})
		.unwrap();

		let error = host
			.close(crate::PendingWork::Finish {
				grace: Some(std::time::Duration::from_millis(20)),
			})
			.await
			.expect_err("a negotiating session keeps the finite finish from settling in time");
		assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
		assert!(
			host.shared.raw.get().is_null(),
			"the timed-out finish still releases native state"
		);

		let again = host
			.close(crate::PendingWork::Cancel)
			.await
			.expect_err("a repeated close observes the recorded timeout");
		assert_eq!(again.kind(), crate::ErrorKind::TimedOut);
	});
}

#[test]
fn close_barrier_retains_the_exact_first_failure() {
	let host = Host::new_host();
	let first = Error::with_detail(sys::ERR_IO, "close transport lost its wake descriptor".to_string());
	host.shared.fail_close(first.clone());
	host.shared.fail_close(Error::with_detail(
		sys::ERR_INTERNAL,
		"later cleanup failure".to_string(),
	));

	let observed = host
		.shared
		.close_host(crate::PendingWork::Cancel)
		.expect_err("a terminal close failure remains observable");
	assert_eq!(observed, first);
}

#[test]
fn committed_close_can_retry_its_driver_spawn() {
	let host = Host::new_host();
	let first = host.shared.close_host(crate::PendingWork::Cancel);
	assert!(first.is_err(), "close outside a LocalSet must refuse its driver spawn");
	assert_eq!(host.shared.close_barrier.get(), CloseBarrierState::Running);
	assert!(!host.shared.close_task_started.get());

	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
	assert!(host.shared.raw.get().is_null());
}

#[test]
fn action_kick_without_a_local_set_reports_admission_failure() {
	let host = Host::new_host();
	let error = host.shared.schedule_kick().unwrap_err();
	assert_eq!(error.kind(), crate::ErrorKind::Internal);
	assert_eq!(
		host.shared.owned_tasks.get(),
		0,
		"refused admission releases its task registration"
	);
}

// Public Host surfaces the ADR-0082 selective knobs (not only HostShared).
#[test]
fn set_session_limits_is_callable_on_host() {
	let host = Host::new_host();
	host.set_session_limits(0, 0, 0)
		.expect("0 leaves both fields unchanged");
	host.set_session_limits(64 * 1024, 0, 0)
		.expect("max_frame_bytes alone is accepted");
}

#[test]
fn advertised_locator_lifecycle_is_callable_on_host() {
	let host = Host::new_host();
	let locator = Locator {
		transport: "tcp".to_string(),
		designator: "127.0.0.1:7441".to_string(),
		hints: Default::default(),
		hint_wire_form: crate::HintWireForm::Map,
	};
	host.set_advertised_locator(&locator)
		.expect("a complete locator is accepted");
	host.remove_advertised_locator("tcp")
		.expect("the published locator is removed");
}

#[test]
fn host_options_carry_local_turn_budget() {
	let host = Host::with_options(HostOptions {
		codec: Codec::Syrup,
		local_turn_budget: 64,
		..Default::default()
	})
	.unwrap();
	host.set_session_limits(0, 0, 0).expect("minted host answers limits");
}

#[test]
fn connector_installation_publishes_no_partial_batch() {
	let host = Host::new_host();
	let mixed = crate::Connector::new(
		&["new-good", ""],
		|_host: Host,
		 _locator: &Locator,
		 _redeem: bool,
		 _transport_options: Option<&[u8]>,
		 _timeout: Option<std::time::Duration>| {
			Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
		},
	)
	.unwrap();
	assert!(host.install_connectors(&[mixed]).is_err());
	assert!(host.shared.connector("new-good").is_none());

	let good = crate::Connector::new(
		&["new-good"],
		|_host: Host,
		 _locator: &Locator,
		 _redeem: bool,
		 _transport_options: Option<&[u8]>,
		 _timeout: Option<std::time::Duration>| {
			Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
		},
	)
	.unwrap();
	host.install_connectors(&[good]).unwrap();
	assert!(host.shared.connector("new-good").is_some());
}
