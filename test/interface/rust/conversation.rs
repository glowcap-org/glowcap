//! Generated calls against independently authored raw Factory, Reader, and Sink
//! behaviors. Factory.open stays pending through argument admission and callback.
use crate::callbacks;
use crate::pair::Pair;
use glowcap::{Argument, Host, Ref, Resolver};
use std::{cell::RefCell, rc::Rc};

#[derive(Default)]
struct Factory {
	resolver: Option<Resolver>,
	sink: Option<Ref>,
	argument: Option<Ref>,
}
#[derive(Default)]
struct Sink {
	reference: Option<Ref>,
	notices: usize,
}

pub async fn run() {
	scenario(false, false).await;
	scenario(false, true).await;
	scenario(true, false).await;
}

async fn scenario(wrong_fulfillment: bool, discard_original: bool) {
	let host = Host::with_options(Default::default()).unwrap();
	let reader = host
		.spawn(|verb, args| {
			assert!(args.is_empty());
			match verb {
				Some("read") => Ok(Argument::String("reader value".into())),
				Some("then") => Ok(Argument::String("ordinary then method".into())),
				_ => Err("unknown reader method".into()),
			}
		})
		.unwrap();
	let factory = Rc::new(RefCell::new(Factory::default()));
	let captured = factory.clone();
	let owner = host.clone();
	host.publish("factory", move || {
		let factory = captured.clone();
		let owner = owner.clone();
		Box::new(move |verb, args| {
			assert_eq!(args.len(), 1);
			let argument = Ref::try_from(&args[0]).unwrap();
			match verb {
				Some("open") => {
					let resolver = owner.defer_turn().unwrap();
					let mut factory = factory.borrow_mut();
					assert!(factory.resolver.is_none());
					factory.sink = Some(argument);
					factory.resolver = Some(resolver);
				}
				Some("accept") => {
					let mut factory = factory.borrow_mut();
					assert!(factory.resolver.is_some(), "argument must arrive before fulfillment");
					factory.argument = Some(argument);
				}
				_ => return Err("unknown factory method".into()),
			}
			Ok(Argument::Void)
		})
	})
	.unwrap();
	let pair = Pair::open(&host, Default::default()).await;
	let client = &pair.client;
	let accepted = &pair.accepted;
	let root = client.fetch("factory").await.unwrap();
	let sink = Rc::new(RefCell::new(Sink::default()));
	let received = sink.clone();
	let callback = client
		.spawn_owned(move |verb, args| {
			assert_eq!(args.len(), 1);
			match verb {
				Some("push") => received.borrow_mut().reference = Some(Ref::try_from(&args[0]).unwrap()),
				Some("changed") => {
					assert_eq!(args[0].as_str(), Some("notice"));
					received.borrow_mut().notices += 1;
				}
				_ => return Err("unknown sink method".into()),
			}
			Ok(Argument::Void)
		})
		.unwrap();
	let mut opened = Some(callbacks::factory_open(client, &root, &callback));
	let retained = opened.as_ref().unwrap().raw().retain().unwrap();
	let foreign = callbacks::factory_accept(accepted, &reader, opened.as_ref().unwrap().raw())
		.await
		.unwrap_err();
	assert!(matches!(foreign, callbacks::Error::Runtime(error) if error.kind() == glowcap::ErrorKind::InvalidArgument));
	if discard_original {
		drop(opened.take());
		callbacks::factory_accept(client, &root, &retained).await.unwrap();
	} else {
		callbacks::factory_accept(client, &root, opened.as_ref().unwrap().raw())
			.await
			.unwrap();
	}
	assert!(factory.borrow().resolver.is_some());
	let sink_target = factory.borrow().sink.clone().unwrap();
	let argument = factory.borrow().argument.clone().unwrap();
	callbacks::sink_changed(accepted, &sink_target, Argument::String("notice".into())).unwrap();
	callbacks::sink_push(accepted, &sink_target, &argument).await.unwrap();
	assert_eq!(sink.borrow().notices, 1);
	let alias = sink.borrow().reference.clone().unwrap();
	let raw_observer = client.listen(&alias);
	let pipelined = callbacks::reader_read(client, &retained);
	let mut resolver = factory.borrow_mut().resolver.take().unwrap();
	if wrong_fulfillment {
		resolver.fulfill(&Argument::String("not a reader".into())).unwrap();
		assert!(matches!(
			opened.take().unwrap().await,
			Err(callbacks::Error::InvalidReply)
		));
		assert_eq!(raw_observer.await.unwrap().as_str(), Some("not a reader"));
		assert!(matches!(pipelined.await, Err(callbacks::Error::Runtime(_))));
	} else {
		resolver.fulfill_value(&(&reader).into()).unwrap();
		if let Some(opened) = opened {
			let _ = opened.await.unwrap();
		}
		assert_eq!(pipelined.await.unwrap(), "reader value");
		let observed = Ref::try_from(&raw_observer.await.unwrap()).unwrap();
		assert_eq!(
			callbacks::reader_then(client, &observed).await.unwrap(),
			"ordinary then method"
		);
	}
	drop(retained);
	pair.close().await;
}
