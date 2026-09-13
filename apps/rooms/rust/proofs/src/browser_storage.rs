//! Real IndexedDB ownership under Chromium, including abandoned write observers.
#[path = "browser_storage/records.rs"]
mod records;
use rooms_application::text::DocumentText;
use rooms_browser::{
	platform::Platform,
	storage::{Database, Error},
};
use std::{
	future::Future,
	task::{Context, Waker},
};
use wasm_bindgen::prelude::*;
#[wasm_bindgen]
pub async fn rooms_browser_storage_contract() -> String {
	super::install_panic_hook();
	let left = Database::open().await.unwrap();
	let right = Database::open().await.unwrap();
	let mut first = Platform::new().unwrap();
	let mut second = first.clone();
	let (a, b) = tokio::join!(left.source(&mut first), right.source(&mut second));
	let source = a.unwrap();
	assert_eq!(source, b.unwrap());
	let old = left.retention_epoch(&mut first).await.unwrap();
	left.set_retention_epoch("new-epoch".into(), false).await.unwrap();
	assert_ne!(old.as_str(), Some("new-epoch"));
	assert_eq!(
		right.retention_epoch(&mut second).await.unwrap().as_str(),
		Some("new-epoch")
	);
	let exact = DocumentText::from_utf16(&[0x0061, 0xd800, 0x0062]);
	let mut unobserved = Box::pin(left.set_retention_epoch(exact.clone(), true));
	assert!(
		unobserved
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	drop(unobserved);
	left.close().await;
	assert!(left.is_closed());
	assert_eq!(left.source(&mut first).await, Err(Error::Closed));
	assert!(!right.is_closed());
	assert_eq!(right.retention_epoch(&mut second).await.unwrap(), exact);
	assert_eq!(right.source(&mut second).await.unwrap(), source);
	right.close().await;
	let reopened = Database::open().await.unwrap();
	assert_eq!(reopened.source(&mut first).await.unwrap(), source);
	assert_eq!(reopened.retention_epoch(&mut first).await.unwrap(), exact);
	reopened.close().await;
	source.as_str().unwrap().into()
}
