// PLANNED: native driver.Session and driver.Server accept stream netlayers.
// iroh has one readiness descriptor for the whole endpoint, so native Zig
// currently uses driver.Bridge with the iroh completion backend. The managed
// C and language-binding providers already adapt that shared readiness.
// From here, the CapTP workflow is transport-independent.
