//! Meta gate, checks that agent scaffolding and documented build commands stay
//! aligned with the canonical project shape.
//! Wired as `zig build meta-check` and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const bans = @import("meta_check/bans.zig");
const binding_runtime_proof = @import("meta_check/binding_runtime_proof.zig");
const binding_spine = @import("meta_check/binding_spine.zig");
const docs = @import("meta_check/docs.zig");
const project_shape = @import("meta_check/project_shape.zig");
const ui = @import("meta_check/ui.zig");
const rooms_ui = @import("meta_check/rooms_ui.zig");
const scaffolding = @import("meta_check/scaffolding.zig");
const c_abi = @import("meta_check/c_abi.zig");
const captp_io_spine = @import("meta_check/captp_io_spine.zig");
const captp_product = @import("meta_check/captp_product.zig");
const zig_docs = @import("meta_check/zig_docs.zig");
const fuzz = @import("meta_check/fuzz.zig");
const namespaces = @import("meta_check/namespaces.zig");
const util = @import("meta_check/util.zig");

/// Create the `meta-check` build step.
pub fn create(b: *Build) *Step {
    const wrapper = b.allocator.create(MetaCheck) catch @panic("OOM");
    wrapper.* = .{ .step = Step.init(.{
        .id = .custom,
        .name = "meta-check",
        .owner = b,
        .makeFn = make,
    }) };
    return &wrapper.step;
}

const MetaCheck = struct {
    step: Step,
};

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const gpa = options.gpa;

    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    const root = b.build_root.handle;

    try scaffolding.expectSymlink(io, gpa, root, &violations, "CLAUDE.md", "AGENTS.md");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/rules", "../.agents/rules");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/skills", "../.agents/skills");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".cursor/skills", "../.agents/skills");
    // The shared UI core. A tool that writes through one of these turns it
    // into a regular file and the brand forks silently; see checkUiCore for
    // the rest of that contract.
    try scaffolding.expectSymlink(io, gpa, root, &violations, "site/assets/tokens.css", "../../ui/tokens.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "apps/rooms/web/ui/tokens.css", "../../../../ui/tokens.css");

    try scaffolding.checkCursorRuleOverlay(io, gpa, root, &violations);
    try scaffolding.checkRequiredSubstrings(io, gpa, root, &violations);
    try scaffolding.checkRuleIndexAgreement(io, gpa, root, &violations);
    try scaffolding.checkSkillCatalog(io, gpa, root, &violations);
    try scaffolding.checkRatchetModuleMap(io, gpa, root, &violations);
    try scaffolding.checkAgentPersonas(io, gpa, root, &violations);
    try scaffolding.checkAgentsRouting(io, gpa, root, &violations);
    try docs.checkMarkdownLinks(io, gpa, root, &violations);
    try docs.checkAdrRelations(io, gpa, root, &violations);
    try docs.checkAdrEvidenceLinks(io, gpa, root, &violations);
    try docs.checkSiteContentLinks(io, gpa, root, &violations);
    try docs.checkSiteTransportTabs(io, gpa, root, &violations);
    try docs.checkSiteNavParity(io, gpa, root, &violations);
    try docs.checkSitePageMetadata(io, gpa, root, &violations);
    try docs.checkResidentRoster(io, gpa, root, &violations);
    try docs.checkQuickStartSnippet(io, gpa, root, &violations);
    try docs.checkStabilityEvidenceParity(io, gpa, root, &violations);
    try docs.checkDanglingReferenceLinks(io, gpa, root, &violations);
    try docs.checkMermaidBlocks(io, gpa, root, &violations);
    try ui.checkUiCore(io, gpa, root, &violations);
    try ui.checkUiPaletteLiterals(io, gpa, root, &violations);
    try ui.checkUiThemeParity(io, gpa, root, &violations);
    try rooms_ui.checkRoomsSelectors(io, gpa, root, &violations);
    try rooms_ui.checkRoomsLayerBans(io, gpa, root, &violations);
    try rooms_ui.checkRoomsConfig(io, gpa, root, &violations);
    try project_shape.checkDocumentedBuildSteps(io, gpa, root, &violations);
    try c_abi.checkAbiVersionLockstep(io, gpa, root, &violations);
    try c_abi.checkAbiFreeingVerb(io, gpa, root, &violations);
    try c_abi.checkAbiReturnShape(io, gpa, root, &violations);
    try c_abi.checkCAbiSurfaceShape(io, gpa, root, &violations);
    try c_abi.checkAbiExportsConsumed(io, gpa, root, &violations);
    try binding_spine.checkBindingConstants(io, gpa, root, &violations);
    try binding_spine.checkBindingHostActionDrains(io, gpa, root, &violations);
    try binding_spine.checkBindingHostActionSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingEmbedderPump(io, gpa, root, &violations);
    try binding_spine.checkBindingEmbedderTrampoline(io, gpa, root, &violations);
    try binding_spine.checkBindingPromiseSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingRustConnSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingGcSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingDialSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingListenSpine(io, gpa, root, &violations);
    try binding_spine.checkBindingEmbedderSpineDocs(io, gpa, root, &violations);
    try binding_spine.checkBindingMagicErrorCodes(io, gpa, root, &violations);
    try binding_spine.checkBindingReflectedFfiWired(io, gpa, root, &violations);
    try binding_spine.checkPythonSigsFactoryArity(io, gpa, root, &violations);
    try binding_runtime_proof.check(io, gpa, root, &violations);
    try binding_spine.checkIrohSidecarAbi(io, gpa, root, &violations);
    try binding_spine.checkWebrtcSidecarAbi(io, gpa, root, &violations);
    try binding_spine.checkIrohSidecarPins(io, gpa, root, &violations);
    try binding_spine.checkSidecarSteadyBytes(io, gpa, root, &violations);
    try captp_product.checkApplicationSurfaceVerbs(io, gpa, root, &violations);
    try captp_product.checkDriverRootShadow(io, gpa, root, &violations);
    try project_shape.checkGatedStepsRideCheck(io, gpa, root, &violations);
    try captp_product.checkPancakeCliSkillAuthority(io, gpa, root, &violations);
    try captp_product.checkPancakeMcpSkillAuthority(io, gpa, root, &violations);
    try captp_product.checkCaptpAgentDogfoodRouting(io, gpa, root, &violations);
    try project_shape.checkExampleIndex(io, gpa, root, &violations);
    try project_shape.checkExampleWiring(io, gpa, root, &violations);
    try docs.checkPlanningDocRoles(io, gpa, root, &violations);
    try docs.checkLivingStateRegistry(io, gpa, root, &violations);
    try bans.runBans(io, gpa, root, &violations, bans.all);
    try captp_product.checkTransportVocabulary(io, gpa, root, &violations);
    try captp_product.checkDesignatorSchemeSync(io, gpa, root, &violations);
    try captp_product.checkAuthenticationMechanismSync(io, gpa, root, &violations);
    try captp_product.checkReferenceRelayIrohLazy(io, gpa, root, &violations);
    try captp_product.checkProductionRelayClassifierLockstep(io, gpa, root, &violations);
    try c_abi.checkCAbiResolve(io, gpa, root, &violations);
    try captp_product.checkRacketScriptBalance(io, gpa, root, &violations);
    try binding_spine.checkIrohLoopConvergence(io, gpa, root, &violations);
    try binding_spine.checkIrohBindingAggregatesComplete(io, gpa, root, &violations);
    try captp_io_spine.check(io, gpa, root, &violations);
    try scaffolding.checkRuleFrontmatter(io, gpa, root, &violations);
    try project_shape.checkLayerOwnership(io, gpa, root, &violations);
    try project_shape.checkTestPlacement(io, gpa, root, &violations);
    try project_shape.checkTestSuiteWiring(io, gpa, root, &violations);
    try project_shape.checkOracleCorpusRegistry(io, gpa, root, &violations);
    try project_shape.checkProtocolCheatsheet(io, gpa, root, &violations);
    try project_shape.checkGeneratedStateIgnores(io, gpa, root, &violations, b.build_root.path orelse ".");
    try project_shape.checkRepositoryUrl(io, gpa, root, &violations, b.build_root.path orelse ".");
    try project_shape.checkPathIoCopies(io, gpa, root, &violations);
    try project_shape.checkFootprintBudgetQuotes(io, gpa, root, &violations);
    try fuzz.checkVendoredRunnerLicense(io, gpa, root, &violations);
    try fuzz.checkVendoredTestRunner(io, gpa, root, &violations, b.graph.zig_lib_directory.path orelse ".");
    try fuzz.checkFuzzRegressionSeeds(io, gpa, root, &violations);
    try fuzz.checkFuzzTargetsAreReachable(io, gpa, root, &violations);
    try captp_product.checkSingleJsonEscaper(io, gpa, root, &violations);
    try docs.checkHumanDocVoice(io, gpa, root, &violations);
    try docs.checkStabilityGateList(io, gpa, root, &violations);
    try docs.checkCommunityReviewCiMatrix(io, gpa, root, &violations);
    try docs.checkProseSentenceLength(io, gpa, root, &violations);
    try docs.checkFuzzCorpusSeeds(io, gpa, root, &violations);
    try docs.checkSiteSvgAscii(io, gpa, root, &violations);
    try docs.checkSiteMotionReducedGuard(io, gpa, root, &violations);
    try docs.checkExampleFenceIndent(io, gpa, root, &violations);
    try project_shape.checkRemoveDiscards(io, gpa, root, &violations);
    try project_shape.checkArchiveTables(io, gpa, root, &violations);
    try c_abi.checkDocCAbiCites(io, gpa, root, &violations);
    try c_abi.checkDeletedNodeCProjection(io, gpa, root, &violations);
    try captp_product.checkCaptpVocabulary(io, gpa, root, &violations);
    try c_abi.checkHostPumpImportGate(io, gpa, root, &violations);
    try c_abi.checkCAbiServedSurface(io, gpa, root, &violations);
    try c_abi.checkNoAdrInRuntimeStrings(io, gpa, root, &violations);
    try captp_product.checkCliCaptpDeadlines(io, gpa, root, &violations);
    try captp_product.checkExampleCaptpDeadlines(io, gpa, root, &violations);
    try captp_product.checkCliListenStopWake(io, gpa, root, &violations);
    try captp_product.checkCaptpLabUxHonesty(io, gpa, root, &violations);
    try c_abi.checkUnwiredHostPluginApis(io, gpa, root, &violations);
    try c_abi.checkHostActionArmLockstep(io, gpa, root, &violations);
    try zig_docs.checkZigDocSymbolClaims(io, gpa, root, &violations);
    try namespaces.checkBareKeyedTables(io, gpa, root, &violations);

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("meta-check: {s}\n", .{msg});
        return step.fail("meta-check found {d} scaffolding violation(s)", .{violations.items.len});
    }
}

test {
    // Pull the check modules' unit tests into the meta-check test artifact.
    _ = bans;
    _ = binding_runtime_proof;
    _ = binding_spine;
    _ = c_abi;
    _ = docs;
    _ = project_shape;
    _ = scaffolding;
    _ = captp_io_spine;
    _ = captp_product;
    _ = zig_docs;
    _ = util;
}
