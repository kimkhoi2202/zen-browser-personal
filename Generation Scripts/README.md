# Personal browser build scripts

The project is a personal fork of zen-browser/desktop pinned in
personal/channels.json. The user authorized Zen (Dev) for testing and Zen (Prod) for
daily use, alongside the untouched official Zen app, keyword-plus-Tab search and provider-colored badges.

Source mapping:
- src/zen/urlbar/PersonalSiteSearch.mjs: exact alias activation and badge colors.
- src/zen/urlbar/PersonalCommandActions.mjs: native command descriptors and matching.
- scripts/personal/commands.test.mjs: native action, visibility and matching checks.
- scripts/personal/command_fixture.py: loopback page for native zoom/cache tests.
- src/zen/urlbar/ZenUrlbarController.mjs: native search-mode/theme integration.
- scripts/personal/ui_patch.py: shared native controller injection.
- scripts/personal/build_macos.py: reproducible signed macOS artifact creation.
- personal/launcher.c: native app/profile isolation launcher.
- personal/entitlements.plist: local signing entitlement baseline.
- scripts/personal/site_search.test.mjs: search-mode key handling and provider-label tests.
- scripts/personal/tab_controller.test.mjs: runs the actual injected Tab branch and verifies arrow navigation.
- scripts/personal/apply_to_engine.py: controller overlay after full source import.
- personal/README.md: design, limitations, updating and promotion instructions.
- personal/HANDOFF.md: continuation guide, source map, commands and release state.
- scripts/personal/clone_profile.py: explicit closed-profile backup/copy and private verification report.
- scripts/personal/jsonlz4.py: Mozilla JSONLZ4 codec for metadata/session rebasing.
- scripts/personal/profile_test.py: synthetic migration failure and preservation checks.
- scripts/personal/launcher_test.py: compiles the real launcher against a synthetic engine on macOS.
- personal/Production.md: release source, migration evidence and remaining integration checks.
- scripts/personal/seed_dev_profile.py: optional search/shortcut-only Dev seed.

Build output apps/manifests stay in ignored dist/. Code signing uses an existing
local keychain identity passed at invocation; no keys/passwords are saved here.
The original vendor app and source profile must remain intact in their private
backup/source locations. Do not use the customized /Applications/Zen (Prod).app as the
base for a later artifact build. The parent workspace handoff records paths.

Only use app-scoped CUA for native testing. No global Computer/AppleScript or
browser-debugging connection. Run code/file tools for source and packaging.
Record actual native results separately from unit tests and signature checks.
