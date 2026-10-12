//! Managed send identity accompanies the sender's ordinary full notification.
//! It grants no authority and is never inferred from nicknames or message text.
pub const POST: &str = "postCorrelated";
pub const POST_FILES: &str = "postFilesCorrelated";
pub const TAG: &str = "operation";

pub fn valid(value: &str) -> bool {
	crate::session::state::OperationId::accepts_utf16(value.encode_utf16())
}
