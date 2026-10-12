//! Scalar admission fixes the target. The archive worker restores exact custody.
use super::*;
use rooms_application::content::session::custody::{self, Coordinate, FieldKey};

/// One Rc retains the existing private writer, platform and exact archive
/// coordinate from admission through capture and storage. The bounded inbox
/// and eight outgoing workers own preparation. MAX_PENDING and MAX_BYTES bound
/// queued restoration. No URI, workspace snapshot or archive capability is
/// copied. One boxed restoration future lends this owner to the archive worker.
/// Resolving before dispatch would make archive downtime prevent delivery.
struct Target<P> {
	writer: Rc<super::super::executor::Writer>,
	platform: P,
	coordinate: Coordinate,
}
pub(in crate::session::managed) fn selected<P: Tasks + Deadline + Clone + 'static>(
	writer: Rc<super::super::executor::Writer>,
	platform: P,
	key: FieldKey<custody::ArchiveAccess>,
) -> Destination {
	Destination::Restoring(Rc::new(Target {
		writer,
		platform,
		coordinate: Coordinate {
			role: custody::Role::ArchiveAccess,
			key: FieldKey::new(key.slot(), key.generation()),
		},
	}))
}
impl<P: Tasks + Deadline + Clone + 'static> crate::archive::session::Restore for Target<P> {
	fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>() + 2 * core::mem::size_of::<usize>()
	}
	fn reference(&self) -> Pin<Box<dyn Future<Output = Result<Ref>> + '_>> {
		Box::pin(async {
			let root = self.writer.root()?;
			let coordinate =
				serde_json::to_string(&self.coordinate).map_err(|_| loam::refusal("invalid recording coordinate"))?;
			let args = [root.clone().into(), Argument::List(vec![coordinate.into()])];
			let reply = self
				.platform
				.within(rooms_application::room::authority::REQUEST_TIMEOUT_MS, async {
					self.writer.host.send(&root, "restore-custody", &args).await
				})
				.await
				.ok_or_else(|| loam::refusal("recording target restoration did not answer"))??;
			let Some([held]) = reply.as_list() else {
				return Err(loam::refusal("invalid recording target restoration"));
			};
			Ref::try_from(held).map_err(|_| loam::refusal("recording target has no capability"))
		})
	}
}
