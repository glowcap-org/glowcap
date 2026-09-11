use super::*;
use crate::session_state::{OrdinaryStatus, ResultStatus};
use rooms_application::session::{
	checkpoint::{commands::results::Plan, Checkpoint},
	state::{Inspected, Inspection, Outcome, ResultText},
};
use transactions::Transaction;
impl SessionCommands {
	/// Observe command replay/base checks before external preflight. Commit
	/// still rechecks the command against whichever revision is current then.
	pub fn inspect_command(
		&self,
		id: OperationId,
		base: u64,
		material: DocumentText,
	) -> Result<Admission<Option<u64>>, AdmissionError> {
		self.transaction(material_heap(&id, &material), |answer| Transaction::InspectCommand {
			id,
			base,
			material,
			answer,
		})
	}
	/// A received link selects its base only when the serializer executes it.
	/// Duplicate committed links return the current revision without another write.
	pub fn prepare_room_link(
		&self,
		id: OperationId,
		invitation: rooms_application::session::checkpoint::invitations::RoomLink,
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = invitation.retained_bytes().saturating_add(id.text().heap_bytes());
		self.transaction(heap, |answer| Transaction::ReceiveRoomLink {
			id,
			invitation: Box::new(invitation),
			answer,
		})
	}
	/// The handoff owner supplies the received invitation while the original
	/// accept arguments retain the caller's retry identity.
	pub fn prepare_handed_invitation(
		&self,
		id: OperationId,
		base: u64,
		invitation: DocumentText,
		args: [DocumentText; 2],
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = args.iter().fold(
			id.text().heap_bytes().saturating_add(invitation.heap_bytes()),
			|sum, arg| sum.saturating_add(arg.heap_bytes()),
		);
		self.transaction(heap, |answer| Transaction::AcceptHanded {
			id,
			base,
			invitation,
			args,
			answer,
		})
	}

	pub fn prepare_command(
		&self,
		id: OperationId,
		base: u64,
		command: Command,
		args: Vec<DocumentText>,
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = command_heap(&id, &args, args.capacity());
		self.transaction(heap, |answer| Transaction::Command {
			id,
			base,
			command,
			args,
			answer,
		})
	}

	pub(crate) fn prepare_bridge_command(
		&self,
		id: OperationId,
		base: u64,
		args: Vec<DocumentText>,
		bridge: BridgePreparation,
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = command_heap(&id, &args, args.capacity())
			.saturating_add(bridge.directory.heap_bytes())
			.saturating_add(bridge.scope.heap_bytes())
			.saturating_add(bridge.secrets.retained_bytes())
			.saturating_add(bridge.revision.as_ref().map_or(0, DocumentText::heap_bytes));
		self.transaction(heap, |answer| Transaction::BridgeCommand {
			id,
			base,
			args,
			directory: bridge.directory,
			scope: bridge.scope,
			secrets: bridge.secrets,
			revision: bridge.revision,
			custody: bridge.custody,
			answer,
		})
	}
	pub fn prepare_adoption(
		&self,
		id: OperationId,
		base: u64,
		checkpoint: Checkpoint,
	) -> Result<Admission<u64>, AdmissionError> {
		// The infrequent whole-workspace import is boxed so ordinary requests
		// do not reserve its inline graph header in every channel slot.
		let heap = id.text().heap_bytes().saturating_add(checkpoint.retained_bytes());
		self.transaction(heap, |answer| Transaction::Adopt {
			id,
			base,
			checkpoint: Box::new(checkpoint),
			answer,
		})
	}
	pub fn prepare_replace(
		&self,
		id: OperationId,
		base: u64,
		checkpoint: Checkpoint,
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = id.text().heap_bytes().saturating_add(checkpoint.retained_bytes());
		self.transaction(heap, |answer| Transaction::Replace {
			id,
			base,
			checkpoint: Box::new(checkpoint),
			answer,
		})
	}
	/// Inspect before external preflight, then submit the opaque inspection to
	/// this same owner. A caller-supplied identity cannot substitute for it.
	pub fn inspect_ordinary(
		&self,
		id: OperationId,
		base: u64,
		material: DocumentText,
	) -> Result<Admission<Inspection>, AdmissionError> {
		self.transaction(material_heap(&id, &material), |answer| Transaction::Inspect {
			id,
			base,
			material,
			answer,
		})
	}
	pub fn prepare_ordinary(
		&self,
		id: OperationId,
		base: u64,
		material: DocumentText,
	) -> Result<Admission<OrdinaryStatus>, AdmissionError> {
		self.transaction(material_heap(&id, &material), |answer| Transaction::Prepare {
			id,
			base,
			material,
			answer,
		})
	}
	pub fn prepare_inspected(
		&self,
		inspection: Inspected,
		material: DocumentText,
	) -> Result<Admission<OrdinaryStatus>, AdmissionError> {
		let heap = inspection
			.retained_bytes()
			.saturating_sub(core::mem::size_of::<Inspected>())
			.saturating_add(material.heap_bytes());
		self.transaction(heap, |answer| Transaction::PrepareInspected {
			inspection,
			material,
			answer,
		})
	}
	pub fn commit_ordinary(&self, id: OperationId, material: DocumentText) -> Result<Admission<u64>, AdmissionError> {
		self.transaction(material_heap(&id, &material), |answer| Transaction::Commit {
			id,
			material,
			answer,
		})
	}
	pub fn resolve(&self, id: OperationId, outcome: Outcome) -> Result<Admission<u64>, AdmissionError> {
		self.transaction(id.text().heap_bytes(), |answer| Transaction::Resolve {
			id,
			outcome,
			answer,
		})
	}
	/// The caller may retain the immutable plan for external execution. Every
	/// request charges its full graph conservatively, even when holders share it.
	pub fn prepare_result(
		&self,
		id: OperationId,
		base: u64,
		material: DocumentText,
		plan: Rc<Plan>,
	) -> Result<Admission<ResultStatus>, AdmissionError> {
		let heap = material_heap(&id, &material).saturating_add(plan.retained_bytes());
		self.transaction(heap, |answer| Transaction::ReserveResult {
			id,
			base,
			material,
			plan,
			answer,
		})
	}
	/// Record returned authority, then finish all durable boundaries. Each write
	/// publishes separately, including when a later write or application fails.
	pub fn commit_result(
		&self,
		id: OperationId,
		material: Option<DocumentText>,
		result: ResultText,
	) -> Result<Admission<u64>, AdmissionError> {
		let heap = id
			.text()
			.heap_bytes()
			.saturating_add(material.as_ref().map_or(0, DocumentText::heap_bytes))
			.saturating_add(result.text().heap_bytes());
		self.transaction(heap, |answer| Transaction::CommitResult {
			id,
			material,
			result,
			answer,
		})
	}
	pub fn recover_result(&self, id: OperationId) -> Result<Admission<u64>, AdmissionError> {
		self.transaction(id.text().heap_bytes(), |answer| Transaction::RecoverResult {
			id,
			answer,
		})
	}
	fn transaction<T>(
		&self,
		heap: usize,
		make: impl FnOnce(oneshot::Sender<Result<T, String>>) -> Transaction,
	) -> Result<Admission<T>, AdmissionError> {
		self.admit(core::mem::size_of::<Envelope>().saturating_add(heap), false, |answer| {
			Work::Transaction(make(answer))
		})
	}
}
fn material_heap(id: &OperationId, material: &DocumentText) -> usize {
	id.text().heap_bytes().saturating_add(material.heap_bytes())
}
fn command_heap(id: &OperationId, args: &[DocumentText], capacity: usize) -> usize {
	args.iter().fold(
		capacity
			.saturating_mul(core::mem::size_of::<DocumentText>())
			.saturating_add(id.text().heap_bytes()),
		|sum, arg| sum.saturating_add(arg.heap_bytes()),
	)
}
