//! Generated positional, empty-symbol, and named calls meet one raw behavior.
use crate::{callbacks, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile};
use std::{cell::Cell, rc::Rc};

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		let options = HostOptions::with_profile(profile);
		let host = Host::with_options(options).unwrap();
		host.publish("invocation", || {
			Box::new(|verb, args| match verb {
				None => {
					assert_eq!(args.len(), 1);
					assert_eq!(args[0].as_str(), Some("positional input"));
					Ok(Argument::String("positional result".into()))
				}
				Some("") => {
					assert!(args.is_empty());
					Ok(Argument::String("empty-symbol result".into()))
				}
				Some("then") => {
					assert!(args.is_empty());
					Ok(Argument::String("named result".into()))
				}
				_ => Err("unknown invocation".into()),
			})
		})
		.unwrap();
		let notices = Rc::new(Cell::new(0));
		let received = notices.clone();
		let owner = host.clone();
		host.publish("notify", move || {
			let received = received.clone();
			let owner = owner.clone();
			Box::new(move |verb, args| {
				assert_eq!(verb, None);
				assert_eq!(args.len(), 1);
				assert_eq!(args[0].as_str(), Some("notification"));
				assert!(
					owner.defer_turn_if_answer().unwrap().is_none(),
					"tell carried an answer"
				);
				received.set(received.get() + 1);
				Ok(Argument::Void)
			})
		})
		.unwrap();
		let pair = Pair::open(&host, options).await;
		let negotiated = pair.client.profile().unwrap();
		assert_eq!(negotiated.codec, options.codec);
		assert_eq!(negotiated.captp_version, options.captp_version);
		let target = pair.client.fetch("invocation").await.unwrap();
		assert_eq!(
			callbacks::invoke_direct(&pair.client, &target, "positional input")
				.await
				.unwrap(),
			"positional result"
		);
		assert_eq!(
			callbacks::invoke_empty(&pair.client, &target).await.unwrap(),
			"empty-symbol result"
		);
		let notify = pair.client.fetch("notify").await.unwrap();
		callbacks::notify_direct(&pair.client, &notify, Argument::String("notification".into())).unwrap();
		assert_eq!(
			callbacks::invoke_named(&pair.client, &target).await.unwrap(),
			"named result"
		);
		assert_eq!(notices.get(), 1);
		pair.close().await;
	}
}
