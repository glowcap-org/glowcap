//! Unknown graph outcomes retain the mutation until physical recovery settles.
use glowcap::{Argument, Ref, Session};
use std::{
	cell::Cell,
	future::IntoFuture,
	task::{Context, Waker},
};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(js_namespace = globalThis, js_name = armRoomsGraphOutcome)]
	fn arm(applied: bool);
	#[wasm_bindgen(js_namespace = globalThis, js_name = waitRoomsGraphRecovery)]
	fn recovering() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = releaseRoomsGraphRecovery)]
	fn release();
}

pub async fn replace(
	client: &Session,
	root: &Ref,
	control: &Ref,
	replacement: &[Argument],
	pages: usize,
	invocations: &Cell<usize>,
) {
	for applied in [false, true] {
		if !applied {
			// Physical rollback happens after every page and the root was submitted.
			super::refuse_write(pages + 2);
		}
		arm(applied);
		let before = invocations.get();
		let mut mutation = client.send(root, "mutate", replacement).into_future();
		assert!(
			mutation
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		wasm_bindgen_futures::JsFuture::from(recovering()).await.unwrap();
		assert_eq!(invocations.get(), before + 1);
		assert!(
			mutation
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending(),
			"an unknown write cannot disclose its provisional result"
		);
		release();
		if applied {
			assert_eq!(mutation.await.unwrap().as_i64(), Some(pages as i64));
			assert_eq!(
				client.send(root, "mutation-sequence", &[]).await.unwrap().as_i64(),
				Some(3)
			);
			client.send(root, "mutate", replacement).await.unwrap();
			assert_eq!(
				invocations.get(),
				before + 1,
				"applied recovery and replay do not reinvoke"
			);
		} else {
			let failure = mutation.await.unwrap_err();
			assert_eq!(failure.kind(), glowcap::ErrorKind::Broken);
			assert_eq!(failure.message(), Some("WriteNotCommitted"));
			assert_eq!(
				client.send(root, "mutation-sequence", &[]).await.unwrap().as_i64(),
				Some(2)
			);
			let old = client.send(root, "read", &[Argument::Integer(1)]).await.unwrap();
			assert_eq!(Ref::try_from(&old).unwrap(), *control);
		}
	}
}
