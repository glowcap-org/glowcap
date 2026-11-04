//! Fetch classification owns rejected and cancelled replies before exposure.
use super::support::*;
use std::{cell::RefCell, future::Future, task::Poll};

// Bootstrap fetch is an ordinary send whose fulfillment reaches fetch_like.
// Mint that send through its exact ABI so the test can supply adversarial
// values without replacing the protocol bootstrap or the classifier.
unsafe extern "C" fn mint_reply(
	session: *mut ffi::GlowcapHostSession,
	name: *const u8,
	length: usize,
	out_vow: *mut u64,
) -> i32 {
	if name.is_null() || length != 9 || out_vow.is_null() {
		return sys::ERR_INVALID_ARGUMENT;
	}
	// SAFETY: fetch_like borrows the nine-byte test request through this call.
	let request = unsafe { std::slice::from_raw_parts(name, length) };
	let mut bytes = [0; 8];
	bytes.copy_from_slice(&request[..8]);
	let target = sys::GlowcapReference {
		id: u64::from_le_bytes(bytes),
	};
	let verb: &[u8] = match request[8] {
		0 => b"valid",
		1 => b"malformed",
		2 => b"deferred",
		_ => return sys::ERR_INVALID_ARGUMENT,
	};
	// SAFETY: session and out_vow are fetch_like's checked live handle and
	// output; target and verb are borrowed locals, and the argument list is empty.
	unsafe {
		ffi::glowcap_host_session_send(
			session,
			&target,
			verb.as_ptr(),
			verb.len(),
			std::ptr::null(),
			0,
			out_vow,
		)
	}
}

#[derive(Clone, Copy, Debug)]
enum Case {
	Valid,
	Malformed,
	CancelPending,
	CancelDelivered,
	CancelDeliveredValid,
}

#[tokio::test]
async fn classified_fetch_outcomes_preserve_release_policy_and_retire_discards() {
	LocalSet::new()
		.run_until(async {
			let mut leaked = Vec::new();
			for profile in [crate::HostProfile::Interop, crate::HostProfile::Glowcap] {
				for automatic in [true, false] {
					let options = crate::HostOptions::with_profile(profile);
					let server_host = Host::with_options(options).unwrap();
					let client_host = Host::with_options(options).unwrap();
					let server = listen_with_host("127.0.0.1:0", server_host.clone()).await.unwrap();
					let locator = server.locator().unwrap();
					let (client, accepted) =
						tokio::join!(connect_with_host(&locator, client_host.clone()), server.accept());
					let client = client.unwrap();
					let accepted = accepted.unwrap();
					let child = accepted.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
					let malformed = Argument::List(vec![
						(&child).into(),
						Argument::Tagged {
							tag: "opaque".into(),
							value: vec![(&child).into()],
						},
					]);
					let deferred = Rc::new(RefCell::new(None));
					let waiting = deferred.clone();
					let owner = server_host.clone();
					let returned = child.clone();
					let invalid = malformed.clone();
					accepted
						.publish("fetch-custody", move |verb, _| match verb {
							Some("malformed") => Ok(invalid.clone()),
							Some("deferred") => {
								*waiting.borrow_mut() = Some(owner.defer_turn().unwrap());
								Ok(Argument::Void)
							}
							Some("barrier") => Ok(Argument::Void),
							_ => Ok((&returned).into()),
						})
						.unwrap();
					let serving = tokio::task::spawn_local(accepted.serve());
					let target = client.fetch("fetch-custody").await.unwrap();
					client_host.set_release_on_drop(automatic).unwrap();
					for case in [
						Case::Valid,
						Case::Malformed,
						Case::CancelPending,
						Case::CancelDelivered,
						Case::CancelDeliveredValid,
					] {
						let Argument::Reference(anchor) = client.send(&target, "anchor", &[]).await.unwrap() else {
							panic!("expected anchor");
						};
						let id = anchor.id();
						let mut request = [0; 9];
						request[..8].copy_from_slice(&target.id().to_le_bytes());
						request[8] = match case {
							Case::Valid => 0,
							Case::Malformed => 1,
							_ => 2,
						};
						let mut lookup = Box::pin(crate::promise::fetch_like(
							&client.shared,
							&request,
							"custody",
							mint_reply,
						));
						match case {
							Case::Valid => {
								let result = lookup.await.unwrap();
								assert_eq!(result.id(), id);
								assert_eq!(result.guard().is_some(), automatic);
								drop(result);
								client.shared.drain_gc().unwrap();
								if !automatic {
									client.release(Ref::bare_id(id)).unwrap();
								}
							}
							Case::Malformed => assert_eq!(lookup.await.unwrap_err().kind(), ErrorKind::Broken),
							Case::CancelPending | Case::CancelDelivered | Case::CancelDeliveredValid => {
								std::future::poll_fn(|cx| {
									assert!(lookup.as_mut().poll(cx).is_pending());
									Poll::Ready(())
								})
								.await;
								client.send(&target, "barrier", &[]).await.unwrap();
								let mut resolver = deferred.borrow_mut().take().unwrap();
								let outcome = if matches!(case, Case::CancelDeliveredValid) {
									(&child).into()
								} else {
									malformed.clone()
								};
								if matches!(case, Case::CancelPending) {
									drop(lookup);
									client.shared.drain_gc().unwrap();
									resolver.fulfill_value(&outcome).unwrap();
								} else {
									resolver.fulfill_value(&outcome).unwrap();
									client.send(&target, "barrier", &[]).await.unwrap();
									// The receiver owns the delivered value, but
									// the lookup classifier has not resumed.
									drop(lookup);
								}
							}
						}
						client.send(&target, "barrier", &[]).await.unwrap();
						client.shared.drain_gc().unwrap();
						client.release(anchor).unwrap();
						// Source/export roots cannot keep this client registry
						// row alive. Only leaked consumer occurrences can do so.
						let mut remaining = 0;
						for _ in 0..3 {
							match client.release(Ref::bare_id(id)) {
								Err(error) => {
									assert_eq!(error.kind(), ErrorKind::NotFound);
									break;
								}
								Ok(()) => remaining += 1,
							}
						}
						if remaining != 0 {
							leaked.push((profile, automatic, case, remaining));
						}
					}
					client.release(target).unwrap();
					client.close(crate::PendingWork::Cancel).await.unwrap();
					server.close().await.unwrap();
					serving.await.unwrap().unwrap();
				}
			}
			assert!(
				leaked.is_empty(),
				"classified fetch leaked consumer retains: {leaked:?}"
			);
		})
		.await;
}
