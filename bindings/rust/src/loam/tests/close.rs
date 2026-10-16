//! Closing a Host while a storage work is in flight. Each work runs as its
//! own task, so the close driver settles storage before it releases the
//! attachment.
use super::*;
use std::sync::{Arc, Condvar, Mutex};

/// Holds every storage work until the test opens the gate.
#[derive(Default)]
struct Gate {
	state: Mutex<(bool, usize)>,
	changed: Condvar,
}
impl Gate {
	fn open(&self) {
		self.state.lock().unwrap().0 = true;
		self.changed.notify_all();
	}
	fn entered(&self) -> usize {
		self.state.lock().unwrap().1
	}
}
struct Held {
	inner: Arc<dyn Executor>,
	gate: Arc<Gate>,
}
impl Executor for Held {
	fn work_run(&self, work: *mut ffi::GlowcapLoamWork) -> i32 {
		let mut state = self.gate.state.lock().unwrap();
		state.1 += 1;
		while !state.0 {
			state = self.gate.changed.wait(state).unwrap();
		}
		drop(state);
		self.inner.work_run(work)
	}
	fn restore(
		&self,
		attachment: *mut ffi::GlowcapLoamAttachment,
		object: *const ffi::GlowcapLoamObject,
		out_ref: *mut crate::sys::GlowcapReference,
	) -> i32 {
		self.inner.restore(attachment, object, out_ref)
	}
	fn commit(&self) -> i32 {
		self.inner.commit()
	}
	fn collect(&self, work_limit: usize) -> i32 {
		self.inner.collect(work_limit)
	}
	fn recover(&self) -> i32 {
		self.inner.recover()
	}
	fn release(&self) -> i32 {
		self.inner.release()
	}
	fn last_error(&self, buf: &mut [u8]) -> usize {
		self.inner.last_error(buf)
	}
}
struct HeldVolatile(Arc<Gate>);
impl Engine for HeldVolatile {}
impl super::super::executor::sealed::Open for HeldVolatile {
	fn open(
		self,
		schemas: &[ffi::GlowcapLoamSchema],
		limits: &ffi::GlowcapLoamLimits,
	) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
		let volatile = Volatile {
			identity: [4; 16],
			capacity_bytes: 8 * 1024 * 1024,
		};
		let (inner, store) = super::super::executor::sealed::Open::open(volatile, schemas, limits)?;
		Ok((Arc::new(Held { inner, gate: self.0 }), store))
	}
}

#[tokio::test]
async fn host_close_settles_a_storage_work_in_flight() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), async {
				let gate = Arc::new(Gate::default());
				let policy = dependencies::descriptor();
				let mut store = Store::open(HeldVolatile(Arc::clone(&gate)), &[SCHEMA], Limits::default()).unwrap();
				let resource = store.create_resource(&policy, SCHEMA, 1, b"before", 0).unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let mut attachment = store.attach(&host, vec![registration()]).unwrap();
				let (use_ref, control) = attachment.restore(resource).unwrap();
				let pair = vec![Argument::Reference(use_ref), Argument::Reference(control)];
				host.publish("resource", move || {
					let pair = pair.clone();
					Box::new(move |_, _| Ok(Argument::List(pair.clone())))
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let catalog = client.fetch("resource").await.unwrap();
				let opened = client.send(&catalog, "open", &[]).await.unwrap();
				let root = Ref::try_from(&opened.as_list().unwrap()[0]).unwrap();
				let request = [
					Argument::Integer(1),
					Argument::String("set".to_owned()),
					Argument::Bytes(b"after".to_vec()),
				];
				let mutation = tokio::task::spawn_local(async move { client.send(&root, "mutate", &request).await });
				while gate.entered() == 0 {
					tokio::time::sleep(std::time::Duration::from_millis(1)).await;
				}
				// The Host closes while its storage work is held, and the work
				// retires only once the close driver is already waiting. The
				// gate opens off this thread, so a failed close that drops the
				// held task still lets its blocking join finish.
				let release = Arc::clone(&gate);
				let opener = std::thread::spawn(move || {
					std::thread::sleep(std::time::Duration::from_millis(50));
					release.open();
				});
				let closed = host.close(PendingWork::Cancel).await;
				opener.join().unwrap();
				closed.unwrap();
				// The mutation may commit or fail with the closed session, and
				// either way it settles.
				mutation.await.unwrap().map(drop).unwrap_or_else(drop);
				attachment.close().await.unwrap();
				// Host close closed the listener with its loop.
				drop(server);
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().map(drop).unwrap_or_else(drop);
				store.close().unwrap();
			})
			.await
			.expect("closing over held storage has a finite budget");
		})
		.await;
}
