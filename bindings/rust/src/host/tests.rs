use super::*;
use std::cell::Cell;

struct DropProbe(Rc<Cell<bool>>);

#[path = "tests/hosting.rs"]
mod hosting;

#[path = "tests/teardown.rs"]
mod teardown;

#[cfg(feature = "tcp")]
#[tokio::test]
async fn dropped_deferred_reply_breaks_its_remote_answer_after_the_callback() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let actor_host = host.clone();
			host.publish("abandon", move || {
				Box::new(move |_, _| {
					drop(actor_host.defer_turn().unwrap());
					Ok(Argument::Void)
				})
			})
			.unwrap();
			let server = crate::tcp::listen(
				"127.0.0.1",
				0,
				crate::tcp::ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
					..Default::default()
				},
			)
			.await
			.unwrap();
			let runtime = crate::Runtime::open(crate::RuntimeConfig::providers([crate::tcp::provider(
				Default::default(),
			)]))
			.await
			.unwrap();
			let locator = server.locator().unwrap();
			let (client, accepted) = tokio::join!(
				runtime.connect(&locator, crate::ConnectOptions::default()),
				server.accept()
			);
			let client = client.unwrap();
			let accepted = accepted.unwrap();
			let serving = tokio::task::spawn_local(async move { accepted.serve().await });
			let target = client.fetch("abandon").await.unwrap();
			let result = tokio::time::timeout(Duration::from_millis(500), client.send(&target, "drop", &[])).await;
			server.close().await.unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
			let refusal = result
				.expect("dropping a deferred reply must settle its caller")
				.unwrap_err();
			assert!(refusal.to_string().contains("deferred reply owner was dropped"));
		})
		.await;
}

impl Drop for DropProbe {
	fn drop(&mut self) {
		self.0.set(true);
	}
}

#[cfg(feature = "tcp")]
#[tokio::test]
async fn dropping_a_resolver_after_its_session_closes_does_not_poison_host_progress() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let saved = Rc::new(RefCell::new(None));
			let (actor_host, actor_saved) = (host.clone(), saved.clone());
			host.publish("defer", move || {
				Box::new(move |_, _| {
					*actor_saved.borrow_mut() = Some(actor_host.defer_turn().unwrap());
					Ok(Argument::Void)
				})
			})
			.unwrap();
			let server = crate::tcp::listen(
				"127.0.0.1",
				0,
				crate::tcp::ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
					..Default::default()
				},
			)
			.await
			.unwrap();
			let runtime = crate::Runtime::open(crate::RuntimeConfig::providers([crate::tcp::provider(
				Default::default(),
			)]))
			.await
			.unwrap();
			let locator = server.locator().unwrap();
			let (client, accepted) = tokio::join!(
				runtime.connect(&locator, crate::ConnectOptions::default()),
				server.accept()
			);
			let (client, accepted) = (client.unwrap(), accepted.unwrap());
			let serving = tokio::task::spawn_local(async move { accepted.serve().await });
			let target = client.fetch("defer").await.unwrap();
			let answer = client.send(&target, "work", &[]);
			tokio::time::timeout(Duration::from_secs(2), async {
				while saved.borrow().is_none() {
					tokio::task::yield_now().await;
				}
			})
			.await
			.unwrap();
			client.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
			drop(saved.borrow_mut().take());
			let drained = crate::gc::drain(&host.shared);
			server.close().await.unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			drop(answer);
			drained.expect("FFI session retirement already consumed this resolver");
		})
		.await;
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

// A hosted behavior may retain a Host clone. FFI Host ownership of the
// behavior then closes an Rc cycle; explicit close must release the FFI
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
		host.publish("cycle", move || {
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
		assert!(dropped.get(), "FFI Host release drops the captured behavior");
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
			.publish("late", || Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap_err();
		assert_eq!(publish.code(), sys::ERR_CLOSED);
		let durable = host
			.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap_err();
		assert_eq!(durable.code(), sys::ERR_CLOSED);
		assert_eq!(host.remove_durable("late").unwrap_err().code(), sys::ERR_CLOSED);
		assert_eq!(host.unpublish("late").unwrap_err().code(), sys::ERR_CLOSED);
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
		host.publish("alias", || Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap();
		assert!(host.unpublish("alias").unwrap());
		assert!(!host.unpublish("alias").unwrap());

		let swiss = host
			.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap();
		assert!(host.remove_durable(&swiss).unwrap());
		assert!(!host.remove_durable(&swiss).unwrap());
		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
}

#[tokio::test]
async fn retained_entropy_restores_durable_names_and_refuses_live_collisions() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([7; 32]).unwrap();
			let dropped = Rc::new(Cell::new(false));
			let probe = DropProbe(dropped.clone());
			let name = host
				.publish_durable_with_entropy([3; Host::DURABLE_ENTROPY_BYTES], move || {
					Box::new(move |_, _| {
						let _keep = &probe;
						Ok(Argument::Void)
					})
				})
				.unwrap();
			let refused_drop = Rc::new(Cell::new(false));
			let probe = refused_drop.clone();
			assert!(
				host.publish_durable_with_entropy([3; Host::DURABLE_ENTROPY_BYTES], move || {
					let probe = DropProbe(probe.clone());
					Box::new(move |_, _| {
						let _keep = &probe;
						Ok(Argument::Void)
					})
				})
				.is_err()
			);
			assert!(refused_drop.get(), "refused publication returns its behavior custody");
			assert!(!dropped.get(), "collision does not retire the original actor");
			assert!(host.remove_durable(&name).unwrap());
			assert_eq!(
				host.publish_durable_with_entropy([3; Host::DURABLE_ENTROPY_BYTES], || Box::new(|_, _| Ok(
					Argument::Void
				)))
				.unwrap(),
				name
			);
			host.close(PendingWork::Cancel).await.unwrap();
			assert!(dropped.get());
			let calls = Cell::new(0);
			assert!(
				host.publish_durable_with_entropy([3; Host::DURABLE_ENTROPY_BYTES], || {
					calls.set(calls.get() + 1);
					Box::new(|_, _| Ok(Argument::Void))
				})
				.is_err()
			);
			assert_eq!(calls.get(), 0, "closed-host refusal precedes behavior construction");
			let restored = Host::from_seed([7; 32]).unwrap();
			assert_eq!(
				restored
					.publish_durable_with_entropy([3; Host::DURABLE_ENTROPY_BYTES], || Box::new(|_, _| Ok(
						Argument::Void
					)))
					.unwrap(),
				name
			);
			assert_ne!(
				restored
					.publish_durable_with_entropy([4; Host::DURABLE_ENTROPY_BYTES], || Box::new(|_, _| Ok(
						Argument::Void
					)))
					.unwrap(),
				name
			);
			restored.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
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
		assert!(
			host.shared
				.spawn_dial_task(1, 0, move |_host| async move {
					let _probe = DropProbe(task_dropped);
					std::future::pending::<()>().await;
				})
				.unwrap()
		);
		tokio::task::yield_now().await;

		host.shared.cancel_dial_task(1, 0).await.unwrap();
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
		assert!(
			host.shared
				.spawn_dial_task(1, 0, move |_host| async move {
					panic!("dial executor panic");
				})
				.unwrap()
		);
		tokio::task::yield_now().await;
		tokio::task::yield_now().await;

		let error = host.close(crate::PendingWork::Cancel).await.unwrap_err();
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(
			error
				.message()
				.is_some_and(|message| message.contains("dial executor panic"))
		);
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
		host.publish("panicking-drop", move || {
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
	let cell = host
		.shared
		.actor_cell(outcome_behavior(move |_verb, _args| {
			let _keep_captured = &guard;
			Ok(Argument::Void)
		}))
		.unwrap();
	let entropy = [0u8; Host::DURABLE_ENTROPY_BYTES - 1];
	let mut swiss = [0u8; crate::abi_constants_gen::HOST_DURABLE_SWISS_LEN];
	// SAFETY: `register_actor_cell` is called directly with `cell`, the fresh unregistered `ActorCell` that
	// `actor_cell` just boxed, so nothing else holds it; the closure makes the one `glowcap_host_publish_durable` call
	// on `host.shared.raw`, the live handle of the `Host` this test owns. `entropy` is one byte short, so
	// the host refuses the call, and a refusal leaves the cell unregistered for `register_actor_cell` to reclaim;
	// `swiss` is a local buffer that outlives the call, and `trampoline` and `ctx_free` are the binding's callbacks for
	// an `ActorCell`.
	let error = unsafe {
		register_actor_cell(
			cell,
			|| {
				ffi::glowcap_host_publish_durable(
					host.shared.raw.get(),
					entropy.as_ptr(),
					entropy.len(),
					trampoline,
					cell.cast(),
					ctx_free,
					swiss.as_mut_ptr(),
					swiss.len(),
				)
			},
			|code| code > 0,
		)
	}
	.unwrap_err();

	assert_eq!(error.code(), sys::ERR_INVALID_ARGUMENT);
	assert_eq!(error.secondary_error_count(), 1);
	assert!(
		error.secondary_errors()[0]
			.message()
			.is_some_and(|message| message.contains("refused actor cell destructor panic"))
	);
	// Rollback did not poison or consume the Host.
	host.publish("still-live", || Box::new(|_verb, _args| Ok(Argument::Void)))
		.unwrap();
}

#[test]
fn close_waits_for_an_admitted_action_drain_before_ffi_release() {
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
			"close released FFI state beneath an admitted action drain"
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
		// SAFETY: `host.shared.raw()` is the `GlowcapHost` handle of the `Host` this test owns, live until the test
		// ends; `owned.borrow_view()` is a view into `owned`, a local `OwnedLocator` that outlives the call, and `ptr`
		// is a local out-parameter the callee fills with a host-owned session handle.
		check_host(unsafe {
			ffi::glowcap_host_session_open_dialed_locator(host.shared.raw(), owned.borrow_view().unwrap(), &mut ptr)
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
			"the timed-out finish still releases FFI state"
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

// Public Host surfaces the ADR-0124 selective knobs (not only HostShared).
#[test]
fn set_session_limits_is_callable_on_host() {
	let host = Host::new_host();
	host.set_session_limits(crate::SessionLimitOptions::default())
		.expect("0 leaves both fields unchanged");
	host.set_session_limits(crate::SessionLimitOptions {
		max_frame_bytes: 64 * 1024,
		max_retained_sent_answer_bytes: 8 * 1024 * 1024,
		..Default::default()
	})
	.expect("independent transient and durable byte caps are accepted");
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
	host.set_session_limits(crate::SessionLimitOptions::default())
		.expect("minted host answers limits");
}

#[test]
fn host_profiles_use_the_generated_coherent_pairs() {
	let glowcap = HostOptions::with_profile(crate::HostProfile::Glowcap);
	assert_eq!(glowcap.codec, Codec::Capnp);
	assert_eq!(glowcap.captp_version, crate::CaptpVersion::Next);
	let interop = HostOptions::with_profile(crate::HostProfile::Interop);
	assert_eq!(interop.codec, Codec::Syrup);
	assert_eq!(interop.captp_version, crate::CaptpVersion::V1_0);
}

#[test]
fn connector_installation_publishes_no_partial_batch() {
	let host = Host::new_host();
	let mixed = crate::Connector::new(
		&["new-good", ""],
		|_host: Host,
		 _locator: &Locator,
		 _origin: crate::DialOrigin,
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
		 _origin: crate::DialOrigin,
		 _transport_options: Option<&[u8]>,
		 _timeout: Option<std::time::Duration>| {
			Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
		},
	)
	.unwrap();
	host.install_connectors(&[good]).unwrap();
	assert!(host.shared.connector("new-good").is_some());
}
