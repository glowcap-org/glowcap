use super::*;
use crate::documents::VolatileDocument;

struct FailOnceStore {
	bytes: Option<Vec<u8>>,
	writes: usize,
	fail_at: usize,
}
impl Store for FailOnceStore {
	fn read(&mut self) -> StoreFuture<'_, Result<Option<Vec<u8>>, Error>> {
		Box::pin(async { Ok(self.bytes.clone()) })
	}
	fn replace(&mut self, bytes: Vec<u8>) -> StoreFuture<'_, Result<(), Error>> {
		Box::pin(async move {
			self.writes += 1;
			if self.writes == self.fail_at {
				// A write that did not commit, so custody must roll back whole.
				return Err(Error::storage_message("injected custody write refusal"));
			}
			self.bytes = Some(bytes);
			Ok(())
		})
	}
	fn finish_pending(&mut self) -> StoreFuture<'_, Option<Result<(), Error>>> {
		Box::pin(async { None })
	}
}

fn answers(value: &str) -> Answers {
	let mut answers = Answers::default();
	answers.insert("password".into(), DocumentText::from(value)).unwrap();
	answers
}

struct IndeterminateStore {
	bytes: Rc<std::cell::RefCell<Option<Vec<u8>>>>,
	writes: usize,
	lands: bool,
}
impl Store for IndeterminateStore {
	fn read(&mut self) -> StoreFuture<'_, Result<Option<Vec<u8>>, Error>> {
		Box::pin(async { Ok(self.bytes.borrow().clone()) })
	}
	fn replace(&mut self, bytes: Vec<u8>) -> StoreFuture<'_, Result<(), Error>> {
		Box::pin(async move {
			self.writes += 1;
			if self.writes == 3 {
				if self.lands {
					*self.bytes.borrow_mut() = Some(bytes);
				}
				return Err(Error::uncertain("injected lost credential write result"));
			}
			*self.bytes.borrow_mut() = Some(bytes);
			Ok(())
		})
	}
	fn finish_pending(&mut self) -> StoreFuture<'_, Option<Result<(), Error>>> {
		Box::pin(async { None })
	}
}

#[tokio::test(flavor = "current_thread")]
async fn indeterminate_replacement_fences_use_and_preserves_previous_until_readback() {
	for lands in [false, true] {
		for witnessed in [false, true] {
			let disk = Rc::new(std::cell::RefCell::new(None));
			let custody = BridgeSecrets(Rc::new(tokio::sync::Mutex::new(Owner {
				document: Box::new(IndeterminateStore {
					bytes: disk.clone(),
					writes: 0,
					lands,
				}),
				rows: Vec::new(),
				staged: Vec::new(),
				unwitnessed: Vec::new(),
				next_token: 0,
				storage_unknown: false,
			})));
			let directory = DocumentText::from("ocapn://directory.id");
			let scope = DocumentText::from("network");
			let first = DocumentText::from("first-revision");
			let second = DocumentText::from("second-revision");
			let token = custody
				.stage(directory.clone(), scope.clone(), answers("first"), Some(first.clone()))
				.await
				.unwrap();
			custody.settle(&directory, &scope, token).await.unwrap();
			assert!(matches!(
				custody
					.stage(
						directory.clone(),
						scope.clone(),
						answers("second"),
						Some(second.clone())
					)
					.await,
				Err(Error::Uncertain(_))
			));
			let unknown = disk.borrow().clone();
			assert!(matches!(
				custody.answers(&directory, &scope).await,
				Err(Error::Uncertain(_))
			));
			assert!(matches!(
				custody
					.stage(
						directory.clone(),
						scope.clone(),
						answers("third"),
						Some("third-revision".into())
					)
					.await,
				Err(Error::Uncertain(_))
			));
			assert!(custody.settle(&directory, &scope, token).await.is_err());
			assert!(custody.discard(&directory, &scope, token).await.is_err());
			assert_eq!(*disk.borrow(), unknown, "uncertain custody must not write again");
			let recovered = if witnessed { second } else { first };
			custody
				.recover(&[(directory.clone(), scope.clone(), Some(recovered))])
				.await
				.unwrap();
			let expected = if lands && witnessed { "second" } else { "first" };
			assert_eq!(
				custody
					.answers(&directory, &scope)
					.await
					.unwrap()
					.unwrap()
					.0
					.get("password")
					.unwrap()
					.as_str(),
				Some(expected)
			);
			custody
				.stage(directory, scope, answers("third"), Some("third-revision".into()))
				.await
				.unwrap();
		}
	}
}

#[tokio::test(flavor = "current_thread")]
async fn staging_is_case_folded_and_a_refused_replacement_restores_custody() {
	let custody = BridgeSecrets::open(VolatileDocument::new(SessionDocument::BridgeSecrets))
		.await
		.unwrap();
	let directory = DocumentText::from("ocapn://directory.id");
	let scope = DocumentText::from("Libera");
	let token = custody
		.stage(
			directory.clone(),
			scope.clone(),
			answers("first"),
			Some(DocumentText::from("first-revision")),
		)
		.await
		.unwrap();
	custody.settle(&directory, &scope, token).await.unwrap();
	assert_eq!(
		custody
			.answers(&directory, &DocumentText::from("libera"))
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("first")
	);

	let token = custody
		.stage(directory.clone(), scope.clone(), Answers::default(), None)
		.await
		.unwrap();
	assert!(custody.answers(&directory, &scope).await.unwrap().is_none());
	custody.discard(&directory, &scope, token).await.unwrap();
	assert_eq!(
		custody
			.answers(&directory, &scope)
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("first")
	);
}

#[tokio::test(flavor = "current_thread")]
async fn recovery_chooses_the_credentials_named_by_the_recovered_checkpoint() {
	let custody = BridgeSecrets::open(VolatileDocument::new(SessionDocument::BridgeSecrets))
		.await
		.unwrap();
	let directory = DocumentText::from("ocapn://directory.id");
	let scope = DocumentText::from("network");
	let first = DocumentText::from("first-revision");
	let token = custody
		.stage(directory.clone(), scope.clone(), answers("first"), Some(first.clone()))
		.await
		.unwrap();
	custody.settle(&directory, &scope, token).await.unwrap();
	let second = DocumentText::from("second-revision");
	custody
		.stage(
			directory.clone(),
			scope.clone(),
			answers("second"),
			Some(second.clone()),
		)
		.await
		.unwrap();
	custody
		.recover(&[(directory.clone(), scope.clone(), Some(first.clone()))])
		.await
		.unwrap();
	assert_eq!(
		custody
			.answers(&directory, &scope)
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("first")
	);
	custody
		.stage(
			directory.clone(),
			scope.clone(),
			answers("second"),
			Some(second.clone()),
		)
		.await
		.unwrap();
	custody
		.recover(&[(directory.clone(), scope.clone(), Some(second))])
		.await
		.unwrap();
	assert_eq!(
		custody
			.answers(&directory, &scope)
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("second")
	);
}

#[tokio::test(flavor = "current_thread")]
async fn recovery_resolves_a_pending_removal_from_checkpoint_presence() {
	let custody = BridgeSecrets::open(VolatileDocument::new(SessionDocument::BridgeSecrets))
		.await
		.unwrap();
	let directory = DocumentText::from("ocapn://directory.id");
	let scope = DocumentText::from("network");
	let revision = DocumentText::from("first-revision");
	let token = custody
		.stage(
			directory.clone(),
			scope.clone(),
			answers("first"),
			Some(revision.clone()),
		)
		.await
		.unwrap();
	custody.settle(&directory, &scope, token).await.unwrap();
	custody
		.stage(directory.clone(), scope.clone(), Answers::default(), None)
		.await
		.unwrap();
	custody
		.recover(&[(directory.clone(), scope.clone(), Some(revision.clone()))])
		.await
		.unwrap();
	assert_eq!(
		custody
			.answers(&directory, &scope)
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("first")
	);

	let removal = custody
		.stage(directory.clone(), scope.clone(), Answers::default(), None)
		.await
		.unwrap();
	assert!(removal > token);
	custody.recover(&[]).await.unwrap();
	assert!(custody.answers(&directory, &scope).await.unwrap().is_none());
}

#[tokio::test(flavor = "current_thread")]
async fn invalid_stage_does_not_disturb_existing_custody() {
	let custody = BridgeSecrets::open(VolatileDocument::new(SessionDocument::BridgeSecrets))
		.await
		.unwrap();
	let directory = DocumentText::from("ocapn://directory.id");
	let scope = DocumentText::from("network");
	let token = custody
		.stage(
			directory.clone(),
			scope.clone(),
			answers("first"),
			Some(DocumentText::from("first-revision")),
		)
		.await
		.unwrap();
	custody.settle(&directory, &scope, token).await.unwrap();
	assert!(
		custody
			.stage(directory.clone(), scope.clone(), answers("invalid"), None)
			.await
			.is_err()
	);
	assert_eq!(
		custody
			.answers(&directory, &scope)
			.await
			.unwrap()
			.unwrap()
			.0
			.get("password")
			.unwrap()
			.as_str(),
		Some("first")
	);
}

#[tokio::test(flavor = "current_thread")]
async fn failed_finalization_is_recovered_before_the_next_submission() {
	let custody = BridgeSecrets(Rc::new(tokio::sync::Mutex::new(Owner {
		document: Box::new(FailOnceStore {
			bytes: None,
			writes: 0,
			fail_at: 2,
		}),
		rows: Vec::new(),
		staged: Vec::new(),
		unwitnessed: Vec::new(),
		next_token: 0,
		storage_unknown: false,
	})));
	let directory = DocumentText::from("ocapn://directory.id");
	let scope = DocumentText::from("network");
	let first = DocumentText::from("first-revision");
	let token = custody
		.stage(directory.clone(), scope.clone(), answers("first"), Some(first.clone()))
		.await
		.unwrap();
	assert!(custody.settle(&directory, &scope, token).await.is_err());
	custody
		.recover(&[(directory.clone(), scope.clone(), Some(first))])
		.await
		.unwrap();
	let second = DocumentText::from("second-revision");
	custody
		.stage(directory, scope, answers("second"), Some(second))
		.await
		.expect("the recovered journal no longer blocks this scope");
}

#[tokio::test(flavor = "current_thread")]
async fn corrupt_existing_custody_refuses_startup() {
	for bytes in [
		b"{}".as_slice(),
		br#"{"version":1,"secrets":[]}"#,
		br#"{"version":1,"secrets":[{"directory":"ocapn://directory.id","scope":"network","answers":{"password":"held"}}],"pending":[]}"#,
	] {
		let mut document = VolatileDocument::new(SessionDocument::BridgeSecrets);
		Document::replace(&mut document, bytes.to_vec()).await.unwrap();
		assert!(BridgeSecrets::open(document).await.is_err());
	}
}
