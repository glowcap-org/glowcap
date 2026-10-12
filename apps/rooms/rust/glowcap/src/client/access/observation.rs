//! Exact shared observation capabilities and retained registration requests.
use super::*;
use glowcap::loam::{ObservationCursor, ObservationDescription};

/// Keep the original sequence through timeout or lost reply. A new sequence
/// creates a different durable observation, not recovery of the original one.
/// The two-element spine and seven verb bytes are owned here until registration
/// is confirmed. The ordinary binding copies them only at vow admission.
pub struct ObservationRequest {
	arguments: std::cell::RefCell<[Argument; 3]>,
	live: bool,
}
impl ObservationRequest {
	pub fn new(sequence: u32) -> Result<Self, Error> {
		if sequence == 0 {
			return Err(glowcap::loam::refusal("invalid observation sequence").into());
		}
		Ok(Self {
			arguments: std::cell::RefCell::new([i64::from(sequence).into(), "observe".into(), Argument::Void]),
			live: false,
		})
	}
	/// Runtime registrations share the home session's live marker. Their unique
	/// request identity prevents concurrent viewers from sharing cancellation
	/// custody. The request owns one verb and 16 nonce bytes through exact replay.
	pub fn new_live(sequence: u32, identity: [u8; 16]) -> Result<Self, Error> {
		if sequence == 0 {
			return Err(glowcap::loam::refusal("invalid observation sequence").into());
		}
		Ok(Self {
			arguments: std::cell::RefCell::new([
				i64::from(sequence).into(),
				"observe-live".into(),
				Argument::Bytes(identity.to_vec()),
			]),
			live: true,
		})
	}
}
/// Owns the reply once. All descriptions borrow its immutable metadata.
pub struct ObservationState(Argument);
validated_reply!(ObservationState, ObservationDescription);
/// Receive and cancellation are independent exact capabilities. Dropping this
/// handle releases local custody. Retire durable registration explicitly with
/// cancel. Cancellation refusal keeps this handle available for exact retry.
pub struct Observation<D> {
	caller: Caller<D>,
	receiver: Ref,
	canceller: Ref,
}
impl<D: Deadline> Observation<D> {
	/// Adopt exact receiver and cancellation custody, including restored strong
	/// fields after reopening. This does not create a new durable registration.
	pub fn new(client: Client<D>, receiver: Ref, canceller: Ref) -> Self {
		Self {
			caller: Caller::Remote(client),
			receiver,
			canceller,
		}
	}
	pub fn local(host: glowcap::Host, platform: D, receiver: Ref, canceller: Ref) -> Self {
		Self {
			caller: Caller::Local { host, platform },
			receiver,
			canceller,
		}
	}
	pub async fn register(client: Client<D>, source: &Ref, request: &ObservationRequest) -> Result<Self, Error> {
		Self::register_through(Caller::Remote(client), source, request).await
	}
	pub async fn register_local(
		host: glowcap::Host,
		platform: D,
		source: &Ref,
		request: &ObservationRequest,
	) -> Result<Self, Error> {
		Self::register_through(Caller::Local { host, platform }, source, request).await
	}
	pub(crate) async fn register_through(
		caller: Caller<D>,
		source: &Ref,
		request: &ObservationRequest,
	) -> Result<Self, Error> {
		let mut conflicts = 0;
		let reply = loop {
			// Vow admission copies the borrowed arguments synchronously. No
			// RefCell guard or extra argument copy survives the pending call.
			let (sequence, pending) = {
				let arguments = request.arguments.borrow();
				let Some(sequence) = arguments[0].as_i64() else {
					return Err(glowcap::loam::refusal("observation request holds no sequence").into());
				};
				(
					sequence,
					caller.call(
						source,
						"mutate",
						&arguments[..if request.live { 3 } else { 2 }],
						"access observation registration did not answer",
					),
				)
			};
			match pending.await {
				Ok(reply) => break reply,
				Err(Error::Binding(failure))
					if request.live
						&& failure.kind() == glowcap::ErrorKind::Broken
						&& failure.message() == Some("OperationConflict")
						&& conflicts < 4 =>
				{
					// This precise refusal proves the slot belongs to a different
					// request. A timeout never permits resequencing or fresh work.
					conflicts += 1;
					let next = caller
						.call(
							source,
							"mutation-sequence",
							&[],
							"access observation sequence did not answer",
						)
						.await?;
					let next = next
						.as_i64()
						.filter(|value| *value > sequence && u32::try_from(*value).is_ok())
						.ok_or_else(|| glowcap::loam::refusal("invalid observation sequence"))?;
					let mut arguments = request.arguments.borrow_mut();
					if arguments[0].as_i64() == Some(sequence) {
						arguments[0] = next.into();
					}
				}
				Err(error) => return Err(error),
			}
		};
		let Some([Argument::Reference(receiver), Argument::Reference(canceller)]) = reply.as_list() else {
			return Err(glowcap::loam::refusal("observation returned no receive and cancellation custody").into());
		};
		Ok(Self {
			caller,
			receiver: receiver.clone(),
			canceller: canceller.clone(),
		})
	}
	pub fn receiver(&self) -> &Ref {
		&self.receiver
	}
	pub fn canceller(&self) -> &Ref {
		&self.canceller
	}
	/// One outgoing cursor copies 56 bytes into the binding's owned Argument.
	/// Its temporary allocation ends immediately after vow admission, before
	/// waiting. The caller keeps the exact cursor for interruption recovery.
	pub fn poll(
		&self,
		cursor: Option<&ObservationCursor>,
	) -> impl Future<Output = Result<ObservationState, Error>> + use<'_, D> {
		let args = cursor.map(|cursor| Argument::Bytes(cursor.to_vec()));
		read(self.caller.call(
			&self.receiver,
			"poll",
			args.as_slice(),
			"access observation did not answer",
		))
	}
	/// Wait for change, cancellation or session closure. The caller retains the
	/// actual future across interruption. Cancellation retires the registration.
	/// The admitted receive must still be observed before closing its attachment.
	/// Idle time does not expire a durable subscription.
	pub fn receive(
		&self,
		cursor: &ObservationCursor,
	) -> impl Future<Output = Result<ObservationState, Error>> + use<D> {
		read(
			self.caller
				.wait(&self.receiver, "receive", &[Argument::Bytes(cursor.to_vec())]),
		)
	}
	pub async fn cancel(&self) -> Result<bool, Error> {
		self.caller
			.call(
				&self.canceller,
				"cancel",
				&[],
				"access observation cancellation did not answer",
			)
			.await?
			.as_bool()
			.ok_or_else(|| glowcap::loam::refusal("invalid observation cancellation acknowledgement").into())
	}
}

async fn read(pending: impl Future<Output = Result<Argument, Error>>) -> Result<ObservationState, Error> {
	ObservationState::validated(pending.await?)
}
