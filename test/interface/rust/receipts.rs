//! Independent move receipts retain their target and arguments across sequence
//! acquisition. Failed public replies never authorize a fresh sequence.
use crate::{interface, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile, Resolver};
use std::{cell::RefCell, rc::Rc};

#[derive(Default)]
struct State {
	sequence: Option<Resolver>,
	queries: usize,
	deliveries: usize,
	effects: usize,
	reply: Option<Argument>,
	broken: Option<&'static str>,
}

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		let options = HostOptions::with_profile(profile);
		let host = Host::with_options(options).unwrap();
		let state = Rc::new(RefCell::new(State::default()));
		let task = host.spawn(|_, _| Ok("task authority".into())).unwrap();
		let destination = host.spawn(|_, _| Ok("destination authority".into())).unwrap();
		let owner = host.clone();
		let captured = state.clone();
		host.publish("move", move || {
			let (task, destination, owner, state) =
				(task.clone(), destination.clone(), owner.clone(), captured.clone());
			Box::new(move |verb, args| {
				match verb {
					Some("task") => return Ok((&task).into()),
					Some("destination") => return Ok((&destination).into()),
					Some("barrier") => return Ok(Argument::Void),
					Some("mutation-sequence") => {
						assert!(args.is_empty());
						let resolver = owner.defer_turn().unwrap();
						let mut state = state.borrow_mut();
						state.queries += 1;
						assert!(state.sequence.replace(resolver).is_none());
						return Ok(Argument::Void);
					}
					Some("mutate") => {
						// messages.syrup independently spells this envelope. The
						// operation is String, while the selector above is Symbol.
						assert_eq!(
							args,
							&[
								4i64.into(),
								Argument::String("move".into()),
								(&task).into(),
								(&destination).into()
							]
						);
					}
					_ => panic!("unexpected move-fixture method"),
				}
				let mut state = state.borrow_mut();
				if state.deliveries == 0 {
					state.effects += 1;
				}
				state.deliveries += 1;
				if let Some(failure) = state.broken {
					Err(failure.into())
				} else {
					Ok(state.reply.clone().unwrap_or_else(|| 0i64.into()))
				}
			})
		})
		.unwrap();
		let pair = Pair::open(&host, options).await;
		let target = pair.client.fetch("move").await.unwrap();
		let barrier = pair.client.fetch("move").await.unwrap();
		let task = glowcap::Ref::try_from(&pair.client.send(&target, "task", &[]).await.unwrap()).unwrap();
		let destination =
			glowcap::Ref::try_from(&pair.client.send(&target, "destination", &[]).await.unwrap()).unwrap();
		let foreign_host = Host::with_options(options).unwrap();
		let foreign = foreign_host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		for (receiver, first, second) in [
			(&foreign, &task, &destination),
			(&target, &foreign, &destination),
			(&target, &task, &foreign),
		] {
			match interface::prepare_move(pair.client.clone(), receiver.clone(), first.into(), second.into()) {
				Err(interface::Error::Runtime(error)) => assert_eq!(error.kind(), glowcap::ErrorKind::NotFound),
				_ => panic!("foreign reference preparation was admitted"),
			}
		}
		pair.client.send(&barrier, "barrier", &[]).await.unwrap();
		assert_eq!(state.borrow().queries, 0, "foreign preparation acquired a sequence");
		let preparation = interface::prepare_move(
			pair.client.clone(),
			target.clone(),
			(&task).into(),
			(&destination).into(),
		)
		.unwrap();
		// Explicit release invalidates all ordinary clones. Only independently
		// retained occurrences may survive this caller action and suspension.
		pair.client.release(target).unwrap();
		pair.client.release(task).unwrap();
		pair.client.release(destination).unwrap();
		pair.client.send(&barrier, "barrier", &[]).await.unwrap();
		assert_eq!(state.borrow().queries, 1);
		assert_eq!(state.borrow().deliveries, 0);
		state
			.borrow_mut()
			.sequence
			.take()
			.unwrap()
			.fulfill(&4i64.into())
			.unwrap();
		let request = preparation.await.unwrap();
		// Zero is a valid declared TaskCount. It is not a failed Boolean.
		assert_eq!(request.submit().await.unwrap(), 0);
		state.borrow_mut().reply = Some(256i64.into());
		assert_eq!(request.submit().await.unwrap(), 256);
		for reply in [Argument::Boolean(false), (-1i64).into(), 257i64.into()] {
			state.borrow_mut().reply = Some(reply.clone());
			let typed = request.submit();
			let retained = typed.raw().retain().unwrap();
			let raw = pair.client.listen(&retained);
			assert!(matches!(typed.await, Err(interface::Error::InvalidReply)));
			assert_eq!(raw.await.unwrap(), reply, "typed decoder changed raw settlement");
		}
		for failure in ["independent outcome unknown after commit", "receipt expired"] {
			state.borrow_mut().broken = Some(failure);
			match request.submit().await {
				Err(interface::Error::Runtime(error)) => assert!(error.to_string().contains(failure)),
				_ => panic!("remote mutation refusal lost"),
			}
		}
		state.borrow_mut().broken = None;
		state.borrow_mut().reply = Some(1i64.into());
		assert_eq!(request.submit().await.unwrap(), 1);
		assert_eq!(state.borrow().queries, 1, "replay refreshed its sequence");
		assert_eq!(state.borrow().deliveries, 8);
		assert_eq!(state.borrow().effects, 1, "replay duplicated a committed effect");
		drop(request);
		let task = glowcap::Ref::try_from(&pair.client.send(&barrier, "task", &[]).await.unwrap()).unwrap();
		let destination =
			glowcap::Ref::try_from(&pair.client.send(&barrier, "destination", &[]).await.unwrap()).unwrap();
		for invalid_sequence in [false, true] {
			let preparation = interface::prepare_move(
				pair.client.clone(),
				barrier.clone(),
				(&task).into(),
				(&destination).into(),
			)
			.unwrap();
			pair.client.send(&barrier, "barrier", &[]).await.unwrap();
			let mut sequence = state.borrow_mut().sequence.take().unwrap();
			if invalid_sequence {
				sequence.fulfill(&0i64.into()).unwrap();
				assert!(matches!(preparation.await, Err(interface::Error::InvalidSequence)));
			} else {
				drop(preparation);
				sequence.fulfill(&4i64.into()).unwrap();
			}
			pair.client.send(&barrier, "barrier", &[]).await.unwrap();
			assert_eq!(
				state.borrow().deliveries,
				8,
				"abandoned preparation submitted a mutation"
			);
		}
		pair.close().await;
		foreign_host.close(glowcap::PendingWork::Cancel).await.unwrap();
	}
}
