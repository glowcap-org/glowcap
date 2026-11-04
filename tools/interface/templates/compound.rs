// This is a decoder work limit, not a schema collection bound. Opaque value
// fields move intact. A typed list needs one Vec allocation because its element
// layout differs from Argument, and owns it until result drop or refusal.
struct DecodeBudget {
	remaining: usize,
}
impl DecodeBudget {
	fn step(&mut self, depth: usize) -> Result<(), Error> {
		if depth > MAX_REPLY_DEPTH || self.remaining == 0 {
			return Err(Error::ResourceLimit);
		}
		self.remaining -= 1;
		Ok(())
	}
}
