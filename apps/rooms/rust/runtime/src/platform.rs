//! Platform execution required by room and direct message effects.
use crate::{clock::Clock, wall_clock::WallClock};
use rooms_glowcap::client::{Deadline, Tasks};
pub trait Platform: Clock + WallClock + Deadline + Tasks + Clone + 'static {}
impl<T: Clock + WallClock + Deadline + Tasks + Clone + 'static> Platform for T {}
