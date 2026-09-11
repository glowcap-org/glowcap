use super::{form::LeafRef, Answers, Error, Field, Form, Tone};

/// Public answers and transient secrets have separate accessors. The combined
/// submission cannot be serialized or formatted accidentally as stored intent.
pub struct Submission {
	answers: Answers,
	secrets: Answers,
}
impl Submission {
	pub fn answers(&self) -> &Answers {
		&self.answers
	}
	pub fn secrets(&self) -> &Answers {
		&self.secrets
	}
}
impl Form {
	pub fn split(&self, typed: Answers) -> Submission {
		let (answers, secrets) = typed.partition(|id| self.is_secret(id));
		Submission { answers, secrets }
	}
	pub fn submission(&self, action: &str, typed: &Answers, toggles: &[&str]) -> Result<Submission, Error> {
		let action = self
			.actions()
			.iter()
			.find(|a| a.id.as_str() == action)
			.ok_or(Error::Action)?;
		let mut asked = Answers::default();
		if action.tone == Tone::Primary {
			for field in self.fields.as_slice() {
				match field {
					Field::Leaf(leaf) => visit(leaf.as_ref(), typed, &mut asked)?,
					Field::Toggle(toggle) => {
						let on = toggles.contains(&toggle.id.as_str());
						asked.insert(toggle.id.as_str().into(), if on { "on" } else { "" }.into())?;
						if on {
							for leaf in toggle.reveals.as_slice() {
								visit(leaf.as_ref(), typed, &mut asked)?;
							}
						}
					}
				}
			}
		}
		Ok(self.split(asked))
	}
}
fn visit(leaf: LeafRef<'_>, typed: &Answers, asked: &mut Answers) -> Result<(), Error> {
	match typed.get(leaf.id()).filter(|v| v.utf16().next().is_some()) {
		Some(value) => asked.insert(leaf.id().into(), value.clone()),
		None if leaf.required() => Err(Error::Required(leaf.label().clone())),
		None => Ok(()),
	}
}
