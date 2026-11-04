//! Independent raw list/tuple replies, moved references, and decoder limits.
use crate::{compound_generated as g, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile};
use std::{cell::RefCell, rc::Rc};

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		let options = HostOptions::with_profile(profile);
		let host = Host::with_options(options).unwrap();
		let reference = host
			.spawn(|verb, args| {
				assert_eq!(verb, Some("read"));
				assert!(args.is_empty());
				Ok("retained compound reference".into())
			})
			.unwrap();
		let reply = Rc::new(RefCell::new(Argument::List(vec![])));
		let captured = reply.clone();
		host.publish("compounds", move || {
			let reply = captured.clone();
			Box::new(move |verb, args| {
				assert!(matches!(verb, Some("list" | "limited" | "tuple" | "zero" | "nested")));
				assert!(args.is_empty());
				Ok(reply.borrow().clone())
			})
		})
		.unwrap();
		let pair = Pair::open(&host, options).await;
		let client = &pair.client;
		let target = client.fetch("compounds").await.unwrap();
		assert!(g::list(client, &target).await.unwrap().is_empty());
		assert!(g::limited(client, &target).await.unwrap().is_empty());
		assert_eq!(g::zero(client, &target).await.unwrap(), ());
		let notices = vec![Argument::Symbol("unknown".into()), Argument::Symbol("unknown".into())];
		*reply.borrow_mut() = Argument::List(notices.clone());
		assert_eq!(g::list(client, &target).await.unwrap(), ["unknown", "unknown"]);
		assert_eq!(g::limited(client, &target).await.unwrap(), ["unknown", "unknown"]);
		*reply.borrow_mut() = Argument::List(vec![Argument::Symbol("x".into()); 3]);
		assert!(matches!(g::limited(client, &target).await, Err(g::Error::InvalidReply)));
		*reply.borrow_mut() = Argument::List(vec!["string is not symbol".into()]);
		let typed = g::list(client, &target);
		let retained = typed.raw().retain().unwrap();
		let raw = client.listen(&retained);
		assert!(matches!(typed.await, Err(g::Error::InvalidReply)));
		assert_eq!(
			raw.await.unwrap(),
			*reply.borrow(),
			"typed refusal rewrote raw settlement"
		);
		drop(retained);
		*reply.borrow_mut() = Argument::List(vec![Argument::Bytes(vec![0, 255]), (&reference).into(), true.into()]);
		let (bytes, moved, flag) = g::tuple(client, &target).await.unwrap();
		assert_eq!(bytes, [0, 255]);
		assert!(flag);
		assert_eq!(
			client.send(&moved, "read", &[]).await.unwrap().as_str(),
			Some("retained compound reference")
		);
		for length in [0, 1, 3] {
			*reply.borrow_mut() =
				Argument::List(vec![Argument::Bytes(vec![0; length]), (&reference).into(), true.into()]);
			assert!(matches!(g::tuple(client, &target).await, Err(g::Error::InvalidReply)));
		}
		*reply.borrow_mut() = Argument::List(vec![Argument::Boolean(false)]);
		assert!(matches!(g::zero(client, &target).await, Err(g::Error::InvalidReply)));
		for value in [
			Argument::Void,
			Argument::List(vec![]),
			Argument::List(vec![Argument::Bytes(vec![0, 1]), true.into(), true.into()]),
		] {
			*reply.borrow_mut() = value;
			assert!(matches!(g::tuple(client, &target).await, Err(g::Error::InvalidReply)));
		}
		let opaque = Argument::Tagged {
			tag: "uninterpreted:description".into(),
			value: vec![(&reference).into()],
		};
		*reply.borrow_mut() = Argument::List(vec![Argument::List(vec![
			Argument::Symbol("item".into()),
			(&reference).into(),
			opaque.clone(),
		])]);
		let mut values = g::nested(client, &target).await.unwrap();
		let (symbol, reference, description) = values.pop().unwrap();
		assert_eq!(symbol, "item");
		assert!(matches!(description, Argument::Tagged { ref tag, .. } if tag == "uninterpreted:description"));
		assert_eq!(
			client.send(&reference, "read", &[]).await.unwrap().as_str(),
			Some("retained compound reference")
		);
		pair.close().await;
	}
}
