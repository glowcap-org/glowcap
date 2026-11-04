// This is a decoder work limit, not a schema collection bound. Opaque value
// fields move intact. Lists whose element layout differs from Argument need
// one result Vec allocation, owned until result drop or refusal.
struct DecodeBudget {
	remaining: usize,
}
impl DecodeBudget {
	fn step(&mut self) -> Result<(), Error> {
		if self.remaining == 0 {
			return Err(Error::ResourceLimit);
		}
		self.remaining -= 1;
		Ok(())
	}
}
