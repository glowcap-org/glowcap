// Presence is fixed stack scratch. A missing optional argument ends the supplied
// prefix; a later Some is refused before arguments acquire wire custody.
fn optional_argument_count(present: &[bool]) -> Result<usize, Error> {
	let count = present.iter().take_while(|value| **value).count();
	if present[count..].iter().any(|value| *value) {
		return Err(Error::InvalidArgument);
	}
	Ok(count)
}
