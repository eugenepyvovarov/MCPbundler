# MCP Bundler OSS Preparation Specification

## Overview
Prepare the MCP Bundler macOS repository for open-source release with Apache 2.0 licensing. The work focuses on removing licensing/wallet gating, purging secrets, restructuring documentation, aligning all MCP lifecycle references to the 2025-06-18 spec, auditing dependencies (including mcp-swift-sdk), and documenting release packaging (app bundles + Homebrew). No code edits are performed yet in this phase.

## Goals
- Publish a clean, public-ready repo with no secrets or private credentials.
- Remove licensing and wallet gating from the app and tests.
- Convert existing spec_* and plan_* files into curated docs under docs/ after validating against current code.
- Align all MCP lifecycle references with the 2025-06-18 MCP specification revision.
- Ensure all dependencies are public and properly licensed, including mcp-swift-sdk.
- Document manual release packaging for app bundles and Homebrew.
- Mirror updated docs into the Obsidian vault at Thoughts/Y26/P/MCPbundler/.

## Non-goals
- No new features or UI redesigns beyond removing licensing/wallet gating.
- No CI setup.
- No behavioral changes unrelated to OSS prep.
- No edits or repository changes in this phase.

## Decisions (confirmed)
- License: Apache 2.0.
- Remove licensing and wallet gating completely.
- Convert spec/plan files into docs/ and remove spec files; update AGENTS.md accordingly.
- README includes contributing, code of conduct, security, support sections.
- Public OSS repo is ~/Projects/mcp-bundler; source README from ~/Projects/mcp-bundler/README.md.
- Copy sanitized files from staging after each step; do not copy test_data.md.
- No CI.
- Provide app bundles and Homebrew release instructions, included in scripts/release.sh.
- Align MCP lifecycle docs to 2025-06-18.
- Mirror updated docs to the Obsidian vault (use obsidian skill).
- Switch to upstream modelcontextprotocol/swift-sdk (0.10.2) and drop session endpoint hint support.

## Open Questions / To Verify
- Branding/assets: confirm icon and third-party asset ownership, or plan replacements.

## Requirements

### 1) Secrets and repository hygiene
- Remove all credentials from Readme.md, docs, tests, and sample configurations.
- Replace credentials with sanitized placeholders and add example configs if needed.
- Clean tracked build artifacts (build/, dist/, default.profraw, .DS_Store) and ensure .gitignore covers them.
- Optional: include a short secret-safety note in README (e.g., local scanning guidance).
- Keep test_data.md only in staging and ensure it contains no secrets; do not copy to the public repo.

### 2) Remove licensing and wallet gating
- Eliminate licensing/wallet gating logic, UI, persistence, and tests.
- Remove any related configuration or secrets storage.
- Keep the rest of the UX functional and consistent.
- Add a SwiftData migration plan to remove legacy LicenseRecord/WalletAccessRecord data safely.

### 3) Documentation restructuring and MCP alignment
- Create docs/ documentation and migrate validated spec/plan content; keep docs/specs only for the OSS tracking spec.
- Remove outdated specs or rewrite as current docs.
- Update all MCP lifecycle references to the 2025-06-18 revision.
- Update README and docs to link to new locations.
- Mirror updated docs to Obsidian vault at Thoughts/Y26/P/MCPbundler/.

### 4) Dependency and licensing audit
- Locate and verify mcp-swift-sdk source.
- If private, replace with a public fork or upstream release.
- Collect third-party license notices as needed (Apache 2.0 compatible).
- Document dependency sources and constraints in README or docs.
 - If switching to upstream swift-sdk, remove session endpoint hint usage in MCPBundler and adjust tests.

### 5) Release packaging
- Document manual steps to build and publish app bundles.
- Document Homebrew cask publishing (tap location, formula template, checksum flow).
- Update release scripts in scripts/release.sh to include packaging steps.

### 6) Tests review
- Review tests for removed features and secret usage.
- Update test fixtures to sanitized values and align with new behavior.

### 7) Clean public repository
- After code cleanup, create a clean public repo snapshot or rewrite history to remove secrets. Create new snapshot, no history rewrite needed. Just clean repo.
- Re-run secret scanning before publishing.

### 8) Public repo sync
- After each completed step, copy sanitized files from staging (~/Projects/mcp-bundler-macos) to the public repo (~/Projects/mcp-bundler).
- Exclude test_data.md and any flagged sensitive artifacts from the public repo.

## Deliverables
- Updated README content (user-provided), including contributing/code of conduct/security/support sections.
- LICENSE (Apache 2.0) and NOTICE or equivalent third-party attributions.
- docs/ with curated documentation; docs/specs/spec_open_source.md remains as OSS tracking.
- Release documentation for bundles and Homebrew.
- Sanitized example configs or notes where needed.

## Acceptance Criteria
- No secrets present in the repository (including docs/tests).
- Licensing and wallet gating removed from code and tests.
- Docs reflect 2025-06-18 MCP lifecycle requirements.
- Release instructions exist for bundles and Homebrew.
- Docs mirrored to Obsidian vault.

## Plan

**Overall Progress:** `90%`

### Tasks
- [x] 🟩 **Step 1: Inventory and audit**
  - [x] 🟩 Scan repo for secrets/credentials in docs, tests, and samples.
  - [x] 🟩 Map licensing/wallet gating code paths and UI entry points.
  - [x] 🟩 Identify all spec_* and plan_* files for migration to docs/.
  - [x] 🟩 Locate mcp-swift-sdk source and confirm licensing.
  - [x] 🟩 Inventory third-party assets (icons, bundles, fonts).

- [x] 🟩 **Step 2: README and repository hygiene**
  - [x] 🟩 Sync README from ~/Projects/mcp-bundler/README.md into staging.
  - [x] 🟩 Add contributing, code of conduct, security, and support sections to README (if missing).
  - [x] 🟩 Remove credentials from docs/tests and add sanitized placeholders.
  - [x] 🟩 Scrub secrets from test_data.md but keep it only in staging.
  - [x] 🟩 Ensure .gitignore covers build artifacts and local outputs.
  - [x] 🟩 Copy sanitized files to ~/Projects/mcp-bundler (exclude test_data.md).

- [x] 🟩 **Step 3: Remove licensing and wallet gating**
  - [x] 🟩 Delete or refactor licensing/wallet gating services and models.
  - [x] 🟩 Remove related UI and settings flows.
  - [x] 🟩 Update or remove tests tied to gating.
  - [x] 🟩 Add SwiftData migration plan from legacy license/wallet models to the new schema.

- [x] 🟩 **Step 4: Documentation restructure and MCP alignment**
  - [x] 🟩 Create docs/ and migrate validated specs/plans; keep docs/specs only for the OSS tracking spec.
  - [x] 🟩 Build spec inventory appendix and audit each spec/plan against code.
  - [x] 🟩 Convert relevant specs into documentation files and remove spec files.
  - [x] 🟩 Remove outdated specs after code verification.
  - [x] 🟩 Clean remaining spec/plan sections in docs and align language with current code.
  - [x] 🟩 Create docs index and seed core docs from code.
  - [x] 🟩 Prune docs/ to only files listed in docs/index.md (excluding docs/specs).
  - [x] 🟩 Rewrite indexed docs to be end-user focused (explain workflows, not code internals).
  - [x] 🟩 Extend Skills and MCP docs with end-user workflows (folders, sync, marketplaces, optimizations).
  - [x] 🟩 Prune Obsidian Docs/ to match docs/index.md.
  - [x] 🟩 Update all MCP lifecycle references to 2025-06-18.
  - [x] 🟩 Update AGENTS.md to point documentation references to docs/.
  - [x] 🟩 Update README/docs links to new locations.
  - [x] 🟩 Mirror updated docs to Obsidian vault using the obsidian skill.

- [x] 🟩 **Step 5: Dependency and license audit**
  - [x] 🟩 Resolve mcp-swift-sdk source (public fork or upstream).
  - [x] 🟩 Update dependency references if needed (no changes required).
  - [x] 🟩 Add LICENSE (Apache 2.0) and NOTICE/third-party attributions.

- [x] 🟩 **Step 5b: Switch to upstream swift-sdk**
  - [x] 🟩 Update Xcode package references to https://github.com/modelcontextprotocol/swift-sdk (pin 0.10.2).
  - [x] 🟩 Remove session endpoint hint logic (applyEndpointHint/currentRestEndpoint/etc).
  - [x] 🟩 Adjust or remove tests that target session endpoint hints.

- [x] 🟩 **Step 6: Release packaging documentation**
  - Status: complete.
  - [x] 🟩 Document manual bundle release steps.
  - [x] 🟩 Document Homebrew cask steps (tap, formula, checksums).
  - [x] 🟩 Update scripts/release.sh to include packaging steps.

- [x] 🟩 **Step 7: Tests review**
  - Status: complete.
  - [x] 🟩 Update tests to remove secrets and removed features.
  - [x] 🟩 Ensure fixtures use sanitized values and in-memory transports.

- [x] 🟩 **Step 8: Clean public repository snapshot**
  - Status: complete.
  - [x] 🟩 Create a clean repo snapshot (no history rewrite).
  - [x] 🟩 Re-scan for secrets before publishing.
  - [x] 🟩 Tag staging repo before cleanup (pre-oss-cleanup).

- [ ] 🟨 **Step 9: Final OSS readiness check**
  - Status: in progress (final verification sweep).
  - [ ] 🟨 Confirm docs mirrored to Obsidian vault.
  - [ ] 🟨 Verify no private assets or credentials remain.
  - [ ] 🟨 Confirm release documentation completeness.

### Verification (ad hoc)
- [x] 🟩 Run targeted tests after upstream swift-sdk switch:
  - MCPBundlerTests/HTTPSSERemoteClientInMemoryTests
  - MCPBundlerTests/HTTPSSEResponseVariantsTests
  - MCPBundlerTests/TransportStatusAndLoggingTests
  - MCPBundlerTests/StreamingFallbackDecisionTests
  - MCPBundlerTests/UpstreamProviderSessionTests

### Important Implementation Details
- Staging repo: ~/Projects/mcp-bundler-macos.
- Public repo: ~/Projects/mcp-bundler.
- Copy sanitized files to the public repo after each completed step; exclude test_data.md.
- README source of truth: ~/Projects/mcp-bundler/README.md.
- All MCP lifecycle references must match the 2025-06-18 specification.
- Do not include any real API keys or tokens in docs/tests; use placeholders.
- Licensing/wallet gating removal should not break core MCP bundling workflows.
- mcp-swift-sdk must be public and properly licensed before OSS release.
- Obsidian mirror path: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Thoughts/Y26/P/MCPbundler/.

### File-level Changes (key insertion points)
- **Add**
  - LICENSE
  - NOTICE
  - docs/oss-release.md

- **Modify**
  - README.md
  - test_data.md
  - AGENTS.md
  - .gitignore
  - MCPBundler.xcodeproj/project.pbxproj
  - MCPBundler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - docs/index.md
  - docs/app-structure.md
  - docs/headless-stdio.md
  - docs/mcp-runtime.md
  - docs/skills.md
  - docs/importing-servers.md
  - docs/oauth.md
  - docs/diagnostics.md
  - scripts/release.sh
  - MCPBundler/Providers/SDKRemoteHTTPProvider.swift
  - MCPBundler/Services/BundledServer.swift
  - MCPBundler/Services/LicenseManager.swift
  - MCPBundler/Services/BundlerSecrets.swift
  - MCPBundler/Models/Models.swift
  - MCPBundler/Views/Servers/*.swift
  - MCPBundlerTests/HTTPSSERemoteClientInMemoryTests.swift
  - MCPBundlerTests/StreamingFallbackDecisionTests.swift
  - MCPBundlerTests/*.swift

- **Remove**
  - MCPBundlerTests/SessionEndpointAwaiterTests.swift
  - MCPBundlerTests/RemoteEndpointResolverTests.swift
  - MCPBundlerTests/RuntimeSSEHintReliabilityTests.swift
  - MCPBundlerTests/UpstreamProviderHTTPSSERetryTests.swift
  - MCPBundlerTests/UpstreamProviderRehydrateRetryTests.swift
  - MCPBundlerTests/HTTPFirstToSSEFallbackTests.swift

### Progress Calculations
- Total steps: 10 major steps
- Completed: 6
- Overall Progress: `60%`

## Appendix: Spec/Plan Inventory (Audit Results)

Legacy spec/plan docs were consolidated into the end-user docs listed in `docs/index.md`.
Primary code references below are the files checked to confirm the feature exists; they are not exhaustive.

| Original File | Status | Documentation Output | Code Check | Notes |
| --- | --- | --- | --- | --- |
| docs/specs/plan-oauth.md | Consolidated | docs/oauth.md | MCPBundler/Services/OAuthService.swift | OAuth guidance retained. |
| docs/specs/plan_skills.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/SkillsLibraryService.swift | Skills guidance retained. |
| docs/specs/skills_manage+spec.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/NativeSkillsSyncService.swift | Native skills sync documented. |
| docs/specs/skills_manage+todo.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/NativeSkillsSyncService.swift | Legacy plan merged into skills doc. |
| docs/specs/spec-oauth.md | Consolidated | docs/oauth.md | MCPBundler/Services/OAuthService.swift | OAuth implementation documented. |
| docs/specs/spec-stdio-refactoring.md | Consolidated | docs/headless-stdio.md | MCPBundler/Services/StdiosessionController.swift | Headless lifecycle documented. |
| docs/specs/spec_bigresponsetmp+plan.md | Consolidated | docs/mcp-runtime.md | MCPBundler/Services/BundledServer.swift | Large responses documented. |
| docs/specs/spec_client_info+plan.md | Consolidated | docs/diagnostics.md | MCPBundler/Services/BundledServer.swift | Client metadata in logs documented. |
| docs/specs/spec_deeplink+plan.md | Consolidated | docs/importing-servers.md | MCPBundler/Services/InstallLinkService.swift | Install links documented. |
| docs/specs/spec_deeplink-routing.md | Consolidated | docs/importing-servers.md | MCPBundler/AppMain.swift | Install routing summarized. |
| docs/specs/spec_fetch_temp_file+plan.md | Consolidated | docs/mcp-runtime.md | MCPBundler/Services/BundledServer.swift | fetch_temp_file documented. |
| docs/specs/spec_fix_duplicate_issues+plan.md | Consolidated | docs/diagnostics.md | MCPBundler/Services/DataIntegrityService.swift | Integrity repair documented. |
| docs/specs/spec_hide_skills+plan.md | Consolidated | docs/skills.md | MCPBundler/Services/BundledServer.swift | Skills visibility documented. |
| docs/specs/spec_import_servers+plan.md | Consolidated | docs/importing-servers.md | MCPBundler/Services/ExternalConfigImporter.swift | Import flow documented. |
| docs/specs/spec_native_skills_sync+plan.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/NativeSkillsSyncService.swift | Sync behavior documented. |
| docs/specs/spec_open_source.md | Tracking | docs/specs/spec_open_source.md | - | OSS prep tracking/spec. |
| docs/specs/spec_provider_folders+plan.md | Consolidated | docs/app-structure.md | MCPBundler/Models/Models.swift | Provider folders documented. |
| docs/specs/spec_searchcalltool+todo.md | Consolidated | docs/mcp-runtime.md | MCPBundler/Services/BundledServer.swift | Context optimizations documented. |
| docs/specs/spec_skill_folders+plan.md | Consolidated | docs/skills.md | MCPBundler/Models/SkillsModels.swift | Skill folders documented. |
| docs/specs/spec_skills.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/SkillsLibraryService.swift | Skills baseline documented. |
| docs/specs/spec_skills_makreplace+plan.md | Consolidated | docs/skills.md | MCPBundler/Services/Skills/SkillMarketplaceService.swift | Marketplaces documented. |
| docs/specs/spec_skills_v2+plan.md | Consolidated | docs/skills.md | MCPBundler/Services/BundledServer.swift | Instruction copy documented. |
| docs/specs/spec_stdio_cpu_fix.md | Consolidated | docs/headless-stdio.md | MCPBundler/Services/StdioBundlerRunner.swift | Headless behavior documented. |
| docs/specs/spec_update_tools_notification+plan.md | Consolidated | docs/headless-stdio.md | MCPBundler/Services/BundledServer.swift | list_changed documented. |
| docs/specs/spec_wallet_access+plan.md | Removed | - | - | Wallet access gate removed. |
