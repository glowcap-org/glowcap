//! Delayed captures keep their admitted writer and standing through selection.
use super::*;

pub(super) async fn run(runtime: Rc<Runtime>, client: &Client<HostPlatform>, link: &str, path: &Path) {
	for peer in [false, true] {
		let answer = Rc::new(RefCell::new(None::<Resolver>));
		let pending = answer.clone();
		let host = client.session().host();
		let root = client
			.session()
			.spawn_owned(move |_, _| {
				*pending.borrow_mut() = Some(host.defer_turn().map_err(|e| e.to_string())?);
				Ok(Argument::Void)
			})
			.unwrap();
		let (owner, worker) = SessionArchive::new(
			HostPlatform,
			runtime.clone(),
			FileArchive::open(
				path.join(if peer {
					"capture-retain-peer"
				} else {
					"capture-retain-device"
				}),
				Options::default(),
			)
			.await
			.unwrap(),
		);
		let worker = tokio::task::spawn_local(worker.run());
		owner
			.select(peer.then(|| link.to_owned()))
			.unwrap()
			.wait()
			.await
			.unwrap();
		let capture = admit(&owner, if peer { 902 } else { 901 }, vec![file(client, &root, 1)]);
		while answer.borrow().is_none() {
			tokio::task::yield_now().await;
		}
		// FIFO selection is answered while capture remains blocked. The old
		// worker looked up its writer only after this read completed.
		owner
			.select((!peer).then(|| link.to_owned()))
			.unwrap()
			.wait()
			.await
			.unwrap();
		answer
			.borrow_mut()
			.take()
			.unwrap()
			.fulfill(&Argument::Bytes(vec![7]))
			.unwrap();
		let receipt = capture.completion.wait().await.unwrap();
		assert!(
			receipt.standing.unwrap().is_some(),
			"standing follows the admitted writer"
		);
		owner.select(None).unwrap().wait().await.unwrap();
		let local = owner.read(Filter::default()).unwrap().wait().await.unwrap();
		let local_capture: Vec<_> = local
			.iter()
			.filter(|kept| kept.record.coordinates() == &capture.coordinates)
			.collect();
		assert_eq!(
			local_capture.len(),
			usize::from(!peer),
			"selection must not redirect pending capture"
		);
		if peer {
			assert!(
				local.is_empty(),
				"neither peer record nor its standing may land on device"
			);
			owner.select(Some(link.to_owned())).unwrap().wait().await.unwrap();
			let kept = owner.read(Filter::default()).unwrap().wait().await.unwrap();
			assert!(
				kept.iter()
					.any(|kept| kept.record.coordinates() == &capture.coordinates)
			);
		} else {
			assert_eq!(local.len(), 2, "device retains both the line and its standing");
		}
		let report = owner.close().await.unwrap();
		assert_eq!(report.refused, 0);
		assert_eq!(worker.await.unwrap(), report);
		client.session().release(root).unwrap();
	}
}
