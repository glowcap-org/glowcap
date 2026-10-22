//! Static source-contract gate for cross-file facts the compiler cannot hold:
//! scaffolding, docs, generated mirrors, ABI spines, and product structure.
//! Wired as `zig build source-check` and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const bans = @import("source_check/bans.zig");
const native_identifier = @import("source_check/bans/native_identifier.zig");
const binding_runtime_proof = @import("source_check/binding_runtime_proof.zig");
const bs_iroh = @import("source_check/binding_spine/iroh.zig");
const bs_constants = @import("source_check/binding_spine/constants.zig");
const bs_close = @import("source_check/binding_spine/close_authority.zig");
const bs_host_actions = @import("source_check/binding_spine/host_actions.zig");
const bs_verb_spines = @import("source_check/binding_spine/verb_spines.zig");
const bs_embedder = @import("source_check/binding_spine/embedder.zig");
const bs_ffi_surface = @import("source_check/binding_spine/ffi_surface.zig");
const bs_browser_ffi = @import("source_check/binding_spine/browser_ffi.zig");
const bs_webrtc = @import("source_check/binding_spine/webrtc.zig");
const bs_viewer = @import("source_check/binding_spine/viewer.zig");
const bs_python_sigs = @import("source_check/binding_spine/python_sigs.zig");
const docs_adr = @import("source_check/docs/adr.zig");
const docs_links = @import("source_check/docs/links.zig");
const docs_site = @import("source_check/docs/site.zig");
const docs_maps = @import("source_check/docs/maps.zig");
const docs_inventories = @import("source_check/docs/inventories.zig");
const docs_claim_parity = @import("source_check/docs/claim_parity.zig");
const docs_snippets = @import("source_check/docs/snippets.zig");
const docs_kinds = @import("source_check/docs/kinds.zig");
const docs_ocapn_conformance = @import("source_check/docs/ocapn_conformance.zig");
const docs_temporary = @import("source_check/docs/temporary.zig");
const docs_public_paths = @import("source_check/docs/public_paths.zig");
const section_refs = @import("source_check/docs/section_refs.zig");
const bench_figures = @import("source_check/docs/bench_figures.zig");
const source_comments = @import("source_check/docs/source_comments.zig");
const docs_static_docs = @import("source_check/docs/static_docs.zig");
const docs_headers = @import("source_check/docs/headers.zig");
const docs_code_names = @import("source_check/docs/code_names.zig");
const docs_corpus = @import("source_check/docs/corpus.zig");
const docs_voice = @import("source_check/docs/voice.zig");
const ps_hygiene = @import("source_check/project_shape/hygiene.zig");
const ps_layers = @import("source_check/project_shape/layers.zig");
const ps_packages = @import("source_check/project_shape/packages.zig");
const ps_license_manifests = @import("source_check/project_shape/license_manifests.zig");
const ps_registries = @import("source_check/project_shape/registries.zig");
const ps_examples = @import("source_check/project_shape/examples.zig");
const ps_steps = @import("source_check/project_shape/steps.zig");
const ps_execution_deadlines = @import("source_check/project_shape/execution_deadlines.zig");
const ps_zig_module_surface = @import("source_check/project_shape/zig_module_surface.zig");
const ps_budgets = @import("source_check/project_shape/budgets.zig");
const ps_playwright = @import("source_check/project_shape/playwright.zig");
const ps_npm_pins = @import("source_check/project_shape/npm_pins.zig");
const ps_formatting = @import("source_check/project_shape/formatting.zig");
const ps_zig_version = @import("source_check/project_shape/zig_version.zig");
const ps_dependency_doc = @import("source_check/project_shape/dependency_doc.zig");
const doc_orphans = @import("source_check/doc_orphans.zig");
const prerelease_versions = @import("source_check/prerelease_versions.zig");
const rust_unsafe_floor = @import("source_check/rust_unsafe_floor.zig");
const rooms_scenes = @import("source_check/rooms_scenes.zig");
const runtime_paths = @import("source_check/runtime_paths.zig");
const test_wiring = @import("source_check/test_wiring.zig");
const ui = @import("source_check/ui.zig");
const css_wellformed = @import("source_check/css_wellformed.zig");
const css_lightdark = @import("source_check/css_lightdark.zig");
const rooms_ui = @import("source_check/rooms_ui.zig");
const rooms_avatar = @import("source_check/rooms_avatar.zig");
const mark_assets = @import("source_check/mark_assets.zig");
const prose_file_claims = @import("source_check/prose_file_claims.zig");
const rooms_session_access = @import("source_check/rooms_session_access.zig");
const rooms_rust_tasks = @import("source_check/rooms_rust_tasks.zig");
const rooms_rust_ownership = @import("source_check/rooms_rust_ownership.zig");
const rooms_proofs = @import("source_check/rooms_proofs.zig");
const rooms_protocol = @import("source_check/rooms_protocol.zig");
const scaffolding = @import("source_check/scaffolding.zig");
const agents_catalog = @import("source_check/agents_catalog.zig");
const c_abi_authority = @import("source_check/c_abi/authority.zig");
const c_abi_versions = @import("source_check/c_abi/versions.zig");
const c_abi_surface = @import("source_check/c_abi/surface.zig");
const c_abi_resolve = @import("source_check/c_abi/resolve.zig");
const c_abi_resolve_ports = @import("source_check/c_abi/resolve_ports.zig");
const c_abi_resolve_cases = @import("source_check/c_abi/resolve_cases.zig");
const c_abi_cites = @import("source_check/c_abi/cites.zig");
const c_abi_errdefer = @import("source_check/c_abi/errdefer.zig");
const c_abi_wiring = @import("source_check/c_abi/wiring.zig");
const c_abi_mirrors = @import("source_check/c_abi/mirrors.zig");
const captp_io_spine = @import("source_check/captp_io_spine.zig");
const binding_literals = @import("source_check/binding_literals.zig");
const binding_posture = @import("source_check/binding_posture.zig");
const cp_node_actions = @import("source_check/captp_product/node_actions.zig");
const cp_vocabulary = @import("source_check/captp_product/vocabulary.zig");
const cp_pins = @import("source_check/captp_product/pins.zig");
const cp_codes = @import("source_check/captp_product/codes.zig");
const cp_relay = @import("source_check/captp_product/relay.zig");
const cp_racket = @import("source_check/captp_product/racket.zig");
const cp_skills = @import("source_check/captp_product/skills.zig");
const cp_deadlines = @import("source_check/captp_product/deadlines.zig");
const cp_cli_ux = @import("source_check/captp_product/cli_ux.zig");
const cp_rooms_profile = @import("source_check/captp_product/rooms_profile.zig");
const cp_rooms_signaling = @import("source_check/captp_product/rooms_signaling.zig");
const zig_docs = @import("source_check/zig_docs.zig");
const zig_doc_names = @import("source_check/zig_doc_names.zig");
const zig_dead_fns = @import("source_check/zig_dead_fns.zig");
const fuzz = @import("source_check/fuzz.zig");
const file_length = @import("source_check/file_length.zig");
const zig_duplicate_bodies = @import("source_check/zig_duplicate_bodies.zig");
const namespaces = @import("source_check/namespaces.zig");
const signing_domain = @import("source_check/signing_domain.zig");
const util = @import("source_check/util.zig");

/// Create the `source-check` build step.
pub fn create(b: *Build) *Step {
    const exe = b.addExecutable(.{
        .name = "source-check-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check/source_check_main.zig"),
            .target = b.graph.host,
            // This analyzer scans the whole source tree on every gate. Keep
            // safety checks while optimizing its parsing and traversal loops.
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "model", .module = modelModule(b, b.graph.host, .ReleaseSafe) }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArg(b.root.toString(b.allocator) catch @panic("OOM"));
    run.addArg(zigLibPath(b));
    return &run.step;
}

/// The codec-neutral model, which some checks read by reflection rather than
/// by parsing its text. It imports nothing, so the check tool takes it alone.
pub fn modelModule(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/ocapn/model/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    root_path: []const u8,
    zig_lib_path: []const u8,
) !usize {
    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    try scaffolding.expectSymlink(io, gpa, root, &violations, "CLAUDE.md", "AGENTS.md");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/rules", "../.agents/rules");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/skills", "../.agents/skills");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".cursor/skills", "../.agents/skills");
    try scaffolding.expectAbsent(io, gpa, root, &violations, ".codex/skills", "Codex loads .agents/skills directly");
    // The shared UI core. A tool that writes through one of these turns it
    // into a regular file and the brand forks silently; see checkUiCore for
    // the rest of that contract. tokens.css is the palette. mark.css is the
    // stacked lockup both surfaces draw.
    try scaffolding.expectSymlink(io, gpa, root, &violations, "site/assets/tokens.css", "../../ui/tokens.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "apps/rooms/web/ui/tokens.css", "../../../../ui/tokens.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "site/assets/mark.css", "../../ui/mark.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "apps/rooms/web/ui/mark.css", "../../../../ui/mark.css");

    try scaffolding.checkCursorRuleOverlay(io, gpa, root, &violations);
    try scaffolding.checkRequiredSubstrings(io, gpa, root, &violations);
    try agents_catalog.checkSkillCatalog(io, gpa, root, &violations);
    try agents_catalog.checkAgentPersonas(io, gpa, root, &violations);
    try agents_catalog.checkAgentsRouting(io, gpa, root, &violations);
    try docs_links.checkMarkdownLinks(io, gpa, root, &violations);
    try docs_links.checkRepoBlobLinks(io, gpa, root, &violations);
    try docs_adr.checkAdrCitations(io, gpa, root, &violations, root_path);
    try docs_adr.checkAdrFrontmatter(io, gpa, root, &violations);
    try docs_adr.checkAdrRelations(io, gpa, root, &violations);
    try docs_adr.checkAdrEvidenceLinks(io, gpa, root, &violations);
    try docs_site.checkSiteContentLinks(io, gpa, root, &violations);
    try docs_site.checkSiteTransportTabs(io, gpa, root, &violations);
    try docs_site.checkSiteNavParity(io, gpa, root, &violations);
    try docs_maps.checkModuleMapLayers(io, gpa, root, &violations);
    try docs_site.checkSitePageMetadata(io, gpa, root, &violations);
    try docs_inventories.checkResidentRoster(io, gpa, root, &violations);
    try docs_snippets.checkQuickStartSnippet(io, gpa, root, &violations);
    try docs_snippets.checkRelaySnippetsUseWss(io, gpa, root, &violations);
    try docs_inventories.checkStabilityEvidenceParity(io, gpa, root, &violations);
    try docs_claim_parity.checkStabilityAreaTableRecurringClaims(io, gpa, root, &violations);
    try docs_claim_parity.checkSiteStabilitySummary(io, gpa, root, &violations);
    try docs_claim_parity.checkExamplesLeadWithRooms(io, gpa, root, &violations);
    try docs_claim_parity.checkDeliverOneWay(io, gpa, root, &violations);
    try docs_claim_parity.checkSessionIsAView(io, gpa, root, &violations);
    try docs_links.checkDanglingReferenceLinks(io, gpa, root, &violations);
    try docs_ocapn_conformance.checkManifest(io, gpa, root, &violations);
    try docs_snippets.checkMermaidBlocks(io, gpa, root, &violations);
    try ui.checkUiCore(io, gpa, root, &violations);
    try ui.checkUiPaletteLiterals(io, gpa, root, &violations);
    try css_wellformed.checkCssWellFormed(io, gpa, root, &violations);
    try css_lightdark.checkCssLightDarkGuard(io, gpa, root, &violations);
    try ui.checkUiProductTokens(io, gpa, root, &violations);
    try ui.checkUiThemeParity(io, gpa, root, &violations);
    try rooms_ui.checkRoomsSelectors(io, gpa, root, &violations);
    try rooms_ui.checkRoomsTextCatalog(io, gpa, root, &violations);
    try rooms_ui.checkRoomsTextVoice(io, gpa, root, &violations);
    try prose_file_claims.checkProseFileClaims(io, gpa, root, &violations);
    try rooms_session_access.checkRoomsSessionAccess(io, gpa, root, &violations);
    try rooms_rust_tasks.checkRoomsRustTasks(io, gpa, root, &violations);
    try rooms_rust_ownership.check(io, gpa, root, &violations);
    try rooms_ui.checkRoomsLayerBans(io, gpa, root, &violations);
    try rooms_ui.checkRoomsControlSurfaces(io, gpa, root, &violations);
    try rooms_ui.checkRoomsBootStates(io, gpa, root, &violations);
    try rooms_ui.checkRoomsCustomProperties(io, gpa, root, &violations);
    try rooms_ui.checkRoomsCardWidths(io, gpa, root, &violations);
    try rooms_ui.checkRoomsTypeRamp(io, gpa, root, &violations);
    try rooms_ui.checkRoomsGapSteps(io, gpa, root, &violations);
    try rooms_ui.checkRoomsComposedTokens(io, gpa, root, &violations);
    try rooms_ui.checkRoomsRequestDeadlines(io, gpa, root, &violations);
    try rooms_ui.checkRoomsRailRow(io, gpa, root, &violations);
    try rooms_ui.checkRoomsConfig(io, gpa, root, &violations);
    try rooms_avatar.checkAvatarRamp(io, gpa, root, &violations);
    try mark_assets.checkMarkAssets(io, gpa, root, &violations);
    try rooms_proofs.checkRoomsProofChildren(io, gpa, root, &violations);
    try rooms_protocol.check(io, gpa, root, &violations);
    try ps_steps.checkDocumentedBuildSteps(io, gpa, root, &violations);
    try ps_license_manifests.check(io, gpa, root, &violations);
    try ps_execution_deadlines.check(io, gpa, root, &violations);
    try file_length.check(io, gpa, root, &violations);
    try zig_duplicate_bodies.check(io, gpa, root, &violations);
    try c_abi_versions.checkAbiVersionLockstep(io, gpa, root, &violations);
    try c_abi_versions.checkPrereleaseProviderAbiVersions(io, gpa, root, &violations);
    try c_abi_surface.checkAbiFreeingVerb(io, gpa, root, &violations);
    try c_abi_mirrors.checkAbiReturnShape(io, gpa, root, &violations);
    try c_abi_surface.checkCAbiSurfaceShape(io, gpa, root, &violations);
    try c_abi_surface.checkCAbiHeaderCommentSeparation(io, gpa, root, &violations);
    try c_abi_surface.checkLocatorAuthoritySplit(io, gpa, root, &violations);
    try c_abi_errdefer.checkCConventionErrdefer(io, gpa, root, &violations);
    try c_abi_surface.checkAbiExportsConsumed(io, gpa, root, &violations);
    try c_abi_mirrors.checkBindingStructPins(io, gpa, root, &violations);
    try c_abi_mirrors.checkTraceVocabulary(io, gpa, root, &violations);
    try c_abi_authority.checkDriverAdmissionAuthority(io, gpa, root, &violations);
    try c_abi_authority.checkDriverFailureAuthority(io, gpa, root, &violations);
    try c_abi_authority.checkHostFailureAuthority(io, gpa, root, &violations);
    try c_abi_authority.checkHostSemanticAuthority(io, gpa, root, &violations);
    try bs_constants.checkBindingConstants(io, gpa, root, &violations);
    try bs_constants.checkArchitectureConstantClaims(io, gpa, root, &violations);
    try bs_close.checkDriverEventFailureProjection(io, gpa, root, &violations);
    try bs_close.checkDriverRetirementAuthority(io, gpa, root, &violations);
    try bs_close.checkBindingCloseProjectionAuthority(io, gpa, root, &violations);
    try bs_close.checkBindingClosePolicyAuthority(io, gpa, root, &violations);
    try bs_host_actions.checkBindingHostActionDrains(io, gpa, root, &violations);
    try bs_host_actions.checkBindingHostActionSpine(io, gpa, root, &violations);
    try bs_embedder.checkBindingEmbedderPump(io, gpa, root, &violations);
    try bs_embedder.checkBindingEmbedderTrampoline(io, gpa, root, &violations);
    try bs_verb_spines.checkBindingPromiseSpine(io, gpa, root, &violations);
    try bs_verb_spines.checkBindingRustConnSpine(io, gpa, root, &violations);
    try bs_verb_spines.checkBindingGcSpine(io, gpa, root, &violations);
    try bs_verb_spines.checkBindingDialSpine(io, gpa, root, &violations);
    try bs_verb_spines.checkBindingListenSpine(io, gpa, root, &violations);
    try bs_embedder.checkBindingEmbedderSpineDocs(io, gpa, root, &violations);
    try bs_embedder.checkBindingMagicErrorCodes(io, gpa, root, &violations);
    try bs_ffi_surface.checkBindingReflectedFfiWired(io, gpa, root, &violations);
    try bs_browser_ffi.checkBrowserFfiResolver(io, gpa, root, &violations);
    try bs_python_sigs.checkPythonSigsFactoryArity(io, gpa, root, &violations);
    try bs_viewer.checkTraceViewerVocabulary(io, gpa, root, &violations);
    try binding_runtime_proof.check(io, gpa, root, &violations);
    try bs_ffi_surface.checkIrohSidecarAbi(io, gpa, root, &violations);
    try bs_ffi_surface.checkWebrtcSidecarAbi(io, gpa, root, &violations);
    try bs_ffi_surface.checkSidecarPins(io, gpa, root, &violations);
    try bs_ffi_surface.checkSidecarSteadyBytes(io, gpa, root, &violations);
    try bs_ffi_surface.checkIrohAcceptQueueBound(io, gpa, root, &violations);
    try bs_webrtc.checkSignalAndIceCaps(io, gpa, root, &violations);
    try cp_skills.checkApplicationSurfaceVerbs(io, gpa, root, &violations);
    try cp_cli_ux.checkDriverRootShadow(io, gpa, root, &violations);
    try cp_skills.checkGlowcapCliSkillAuthority(io, gpa, root, &violations);
    try cp_skills.checkGlowcapMcpSkillAuthority(io, gpa, root, &violations);
    try cp_skills.checkGriddleSkillTruth(io, gpa, root, &violations);
    try cp_skills.checkCaptpAgentDogfoodRouting(io, gpa, root, &violations);
    try ps_examples.checkExampleIndex(io, gpa, root, &violations);
    try ps_examples.checkExampleWiring(io, gpa, root, &violations);
    try docs_temporary.checkOwners(io, gpa, root, &violations);
    try docs_temporary.checkRoadmapItems(io, gpa, root, &violations);
    try docs_temporary.checkLinkDirection(io, gpa, root, &violations);
    try docs_public_paths.check(io, gpa, root, &violations);
    try section_refs.check(io, gpa, root, &violations);
    try bench_figures.check(io, gpa, root, &violations);
    try source_comments.check(io, gpa, root, &violations);
    try docs_static_docs.check(io, gpa, root, &violations);
    try docs_headers.check(io, gpa, root, &violations);
    try docs_code_names.check(io, gpa, root, &violations);
    try bans.runBans(io, gpa, root, &violations, bans.all);
    try native_identifier.check(io, gpa, root, &violations);
    try cp_vocabulary.checkTransportVocabulary(io, gpa, root, &violations);
    try cp_pins.checkDurablePinWriters(io, gpa, root, &violations);
    try cp_codes.checkHostErrorCodeMap(io, gpa, root, &violations);
    try cp_relay.checkReferenceRelayIrohLazy(io, gpa, root, &violations);
    try cp_relay.checkProductionRelayClassifierLockstep(io, gpa, root, &violations);
    try cp_rooms_profile.checkRoomsWireProfile(io, gpa, root, &violations);
    try cp_rooms_profile.checkRoomsPeerMinting(io, gpa, root, &violations);
    try cp_rooms_profile.checkRoomsInputParseFailures(io, gpa, root, &violations);
    try cp_rooms_signaling.checkRoomsWebrtcIceCaps(io, gpa, root, &violations);
    try c_abi_resolve.checkCAbiResolve(io, gpa, root, &violations);
    try c_abi_resolve_ports.checkCAbiResolvePorts(io, gpa, root, &violations);
    try c_abi_resolve_cases.checkCAbiResolveCases(io, gpa, root, &violations);
    try cp_racket.checkRacketScriptBalance(io, gpa, root, &violations);
    try cp_racket.checkBindingTestAggregate(io, gpa, root, &violations);
    try bs_iroh.checkIrohLoopConvergence(io, gpa, root, &violations);
    try bs_iroh.checkIrohBindingAggregatesComplete(io, gpa, root, &violations);
    try captp_io_spine.check(io, gpa, root, &violations);
    try binding_literals.check(io, gpa, root, &violations);
    try binding_posture.check(io, gpa, root, &violations);
    try agents_catalog.checkRuleFrontmatter(io, gpa, root, &violations);
    try ps_layers.checkLayerOwnership(io, gpa, root, &violations);
    try ps_layers.checkTestPlacement(io, gpa, root, &violations);
    try ps_zig_module_surface.check(io, gpa, root, &violations);
    try ps_packages.checkTsPackagePublishSurface(io, gpa, root, &violations);
    try doc_orphans.check(io, gpa, root, &violations);
    try prerelease_versions.check(io, gpa, root, &violations);
    try rust_unsafe_floor.check(io, gpa, root, &violations);
    try rooms_scenes.check(io, gpa, root, &violations);
    try runtime_paths.check(io, gpa, root, &violations);
    try test_wiring.check(io, gpa, root, &violations);
    try ps_registries.checkOracleCorpusRegistry(io, gpa, root, &violations);
    try ps_registries.checkProtocolCheatsheet(io, gpa, root, &violations);
    try ps_registries.checkGeneratedStateIgnores(io, gpa, root, &violations, root_path);
    try ps_registries.checkRepositoryUrl(io, gpa, root, &violations, root_path);
    try ps_hygiene.checkPathIoCopies(io, gpa, root, &violations);
    try ps_hygiene.checkRawNuls(io, gpa, root, &violations);
    try ps_hygiene.checkRoomsTestHeaders(io, gpa, root, &violations);
    try ps_budgets.checkFootprintBudgetQuotes(io, gpa, root, &violations);
    try ps_playwright.checkPlaywrightPin(io, gpa, root, &violations);
    try ps_npm_pins.checkSharedNpmPins(io, gpa, root, &violations);
    try ps_formatting.check(io, gpa, root, &violations);
    try ps_zig_version.check(io, gpa, root, &violations);
    try ps_dependency_doc.check(io, gpa, root, &violations);
    try ps_hygiene.checkDevcontainerBashScripts(io, gpa, root, &violations);
    _ = zig_lib_path;
    try fuzz.checkFuzzRegressionSeeds(io, gpa, root, &violations);
    try fuzz.checkFuzzTargetsAreReachable(io, gpa, root, &violations);
    try cp_cli_ux.checkSingleJsonEscaper(io, gpa, root, &violations);
    try docs_voice.checkHumanDocVoice(io, gpa, root, &violations);
    try docs_inventories.checkStabilityWorkflow(io, gpa, root, &violations);
    try docs_inventories.checkCommunityReviewCiMatrix(io, gpa, root, &violations);
    try docs_inventories.checkFirstReadProvenance(io, gpa, root, &violations);
    try docs_voice.checkProseSentenceLength(io, gpa, root, &violations);
    try docs_voice.checkParagraphLength(io, gpa, root, &violations);
    try docs_inventories.checkFuzzCorpusSeeds(io, gpa, root, &violations);
    try docs_site.checkSiteSvgAscii(io, gpa, root, &violations);
    try docs_site.checkSiteMotionReducedGuard(io, gpa, root, &violations);
    try docs_site.checkSiteDiagramTokens(io, gpa, root, &violations);
    try docs_site.checkSiteDiagramTextFill(io, gpa, root, &violations);
    try docs_snippets.checkExampleFenceIndent(io, gpa, root, &violations);
    try ps_hygiene.checkRemoveDiscards(io, gpa, root, &violations);
    try ps_hygiene.checkDiscardedErrors(io, gpa, root, &violations);
    try ps_steps.checkArchiveTables(io, gpa, root, &violations);
    try c_abi_cites.checkDocCAbiCites(io, gpa, root, &violations);
    try c_abi_cites.checkDeletedNodeCProjection(io, gpa, root, &violations);
    try cp_vocabulary.checkCaptpVocabulary(io, gpa, root, &violations);
    try c_abi_wiring.checkHostPumpImportGate(io, gpa, root, &violations);
    try c_abi_cites.checkCAbiServedSurface(io, gpa, root, &violations);
    try c_abi_wiring.checkNoAdrInRuntimeStrings(io, gpa, root, &violations);
    try cp_deadlines.checkCliCaptpDeadlines(io, gpa, root, &violations);
    try cp_deadlines.checkExampleCaptpDeadlines(io, gpa, root, &violations);
    try cp_deadlines.checkCliListenStopWake(io, gpa, root, &violations);
    try cp_cli_ux.checkCaptpLabUxHonesty(io, gpa, root, &violations);
    try c_abi_wiring.checkUnwiredHostPluginApis(io, gpa, root, &violations);
    try c_abi_wiring.checkHostActionArmLockstep(io, gpa, root, &violations);
    try cp_node_actions.check(io, gpa, root, &violations);
    try zig_docs.checkZigDocSymbolClaims(io, gpa, root, &violations);
    try zig_docs.checkMemoryLedgerSymbolClaims(io, gpa, root, &violations);
    try zig_doc_names.checkZigDocBareNames(io, gpa, root, &violations);
    try zig_dead_fns.checkZigDeadPrivateFns(io, gpa, root, &violations);
    try namespaces.checkBareKeyedTables(io, gpa, root, &violations);
    try signing_domain.checkSigningDomains(io, gpa, root, &violations);

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("source-check: {s}\n", .{msg});
    }
    return violations.items.len;
}

fn zigLibPath(b: *Build) []const u8 {
    const zig_dir = std.fs.path.dirname(b.graph.zig_exe) orelse ".";
    return b.pathJoin(&.{ zig_dir, "lib" });
}

test {
    _ = @import("toolchain_check.zig");
    // Pull the check modules' unit tests into the source-check test artifact.
    _ = bans;
    _ = fuzz;
    _ = binding_runtime_proof;
    _ = bs_ffi_surface;
    _ = c_abi_wiring;
    _ = c_abi_resolve;
    _ = c_abi_resolve_ports;
    _ = c_abi_resolve_cases;
    _ = cp_node_actions;
    _ = docs_adr;
    _ = docs_links;
    _ = docs_site;
    _ = docs_maps;
    _ = docs_claim_parity;
    _ = docs_kinds;
    _ = docs_ocapn_conformance;
    _ = @import("source_check/docs/ocapn_conformance_transaction_test.zig");
    _ = docs_temporary;
    _ = section_refs;
    _ = bench_figures;
    _ = source_comments;
    _ = docs_static_docs;
    _ = docs_public_paths;
    _ = docs_headers;
    _ = docs_code_names;
    _ = docs_corpus;
    _ = docs_snippets;
    _ = file_length;
    _ = zig_duplicate_bodies;
    _ = ps_packages;
    _ = ps_formatting;
    _ = ps_npm_pins;
    _ = ps_steps;
    _ = ps_execution_deadlines;
    _ = ps_zig_module_surface;
    _ = ps_dependency_doc;
    _ = scaffolding;
    _ = captp_io_spine;
    _ = cp_deadlines;
    _ = cp_cli_ux;
    _ = cp_skills;
    _ = cp_racket;
    _ = cp_rooms_profile;
    _ = cp_rooms_signaling;
    _ = rooms_rust_ownership;
    _ = rooms_protocol;
    _ = cp_pins;
    _ = zig_docs;
    _ = zig_doc_names;
    _ = zig_dead_fns;
    _ = signing_domain;
    _ = util;
    _ = @import("source_check/docs/reader_voice.zig");
    _ = @import("source_check/rooms_ui/text_voice.zig");
}
