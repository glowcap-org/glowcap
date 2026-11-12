//! Loop-tier FINISH close over a dial that is still negotiating.

#![cfg(feature = "tcp")]

use super::*;

/// Loop-tier FINISH (ADR-0030), mirroring the byte-fed Host timeout
/// scenario in `host.rs`: a dial still negotiating against a silent TCP
/// partner is admitted pending work, so a finite grace expires and the
/// loop close barrier reports its timeout. The expiry takes effect only
/// inside a step, so this is the proof of the close driver's deadline
/// timer: parked on loop activity alone it would never step again.
#[cfg(feature = "tcp")]
#[tokio::test]
async fn a_finite_finish_close_times_out_over_a_negotiating_loop_dial() {
	let local = tokio::task::LocalSet::new();
	local
		.run_until(async {
			// Bound but never accepted from: the kernel backlog completes
			// the TCP connect, and the CapTP handshake never answers.
			let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
			let port = listener.local_addr().unwrap().port();

			let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
			let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config {
				profiles: crate::tcp::Profiles::TCP,
				..Default::default()
			})
			.unwrap();
			lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
			let host = crate::host::Host::from_shared(lp.wrapper_host().unwrap());

			let locator_uri = crate::uri::format_peer_locator("tcp", &format!("127.0.0.1:{port}"), "").unwrap();
			let locator = crate::uri::parse_locator(&locator_uri).unwrap();
			let dial = {
				let lp = Rc::clone(&lp);
				tokio::task::spawn_local(async move { lp.dial_locator(&locator, None).await })
			};
			for _ in 0..1_000 {
				if !lp.pending_dials.borrow().is_empty() {
					break;
				}
				tokio::task::yield_now().await;
			}
			assert!(!lp.pending_dials.borrow().is_empty(), "the dial was never admitted");

			let error = host
				.close(crate::PendingWork::Finish {
					grace: Some(std::time::Duration::from_millis(20)),
				})
				.await
				.expect_err("a negotiating dial keeps the finite finish from settling in time");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			assert!(dial.await.unwrap().is_err(), "close failed the admitted dial");
		})
		.await;
}
