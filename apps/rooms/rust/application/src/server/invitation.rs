//! One retryable invitation claim, shared by every entrance it answers.
//! The hosting room owns lifetime and membership policy. This state owns
//! receipt competition and the single successful admission.
use alloc::string::String;

#[derive(Default)]
pub struct Admission {
	winning_receipt: Option<String>,
	admitted: bool,
}
impl Admission {
	pub fn claim(&mut self, receipt: &str) -> Result<(), &'static str> {
		if receipt.len() != 32 || !receipt.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f')) {
			return Err("claimInvitation takes one 128-bit lowercase hexadecimal receipt");
		}
		match self.winning_receipt.as_deref() {
			Some(winner) if winner != receipt => Err("this room invitation was claimed already"),
			Some(_) => Ok(()),
			None => {
				self.winning_receipt = Some(receipt.into());
				Ok(())
			}
		}
	}
	pub fn is_open(&self) -> bool {
		self.winning_receipt.is_some() && !self.admitted
	}
	/// Called only after admission preparation succeeds, in the same turn.
	pub fn admit(&mut self) -> Result<(), &'static str> {
		if !self.is_open() {
			return Err("this room invitation entrance has ended");
		}
		self.admitted = true;
		Ok(())
	}
}
