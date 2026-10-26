# Personal browser build scripts

The project is a personal fork of zen-browser/desktop pinned in
personal/channels.json. The user authorized Zen Dev for testing and Zen for
eventual daily use, keyword-plus-Tab search and provider-colored badges.

Source mapping:
- src/zen/urlbar/PersonalSiteSearch.mjs: exact alias activation and badge colors.
- src/zen/urlbar/PersonalCommandActions.mjs: native command descriptors and matching.
- scripts/personal/commands.test.mjs: native action, visibility and matching checks.
- src/zen/urlbar/ZenUrlbarController.mjs: native search-mode/theme integration.
- scripts/personal/ui_patch.py: shared native controller injection.
- scripts/personal/build_macos.py: reproducible signed macOS artifact creation.
- personal/launcher.c: native app/profile isolation launcher.
- personal/entitlements.plist: local signing entitlement baseline.
- scripts/personal/site_search.test.mjs: meaningful module tests.
- scripts/personal/apply_to_engine.py: controller overlay after full source import.
- personal/README.md: design, limitations, updating and promotion instructions.
- personal/HANDOFF.md: continuation guide, source map, commands and release state.
- scripts/personal/seed_dev_profile.py: optional search/shortcut-only Dev seed.

Build output apps/manifests stay in ignored dist/. Code signing uses an existing
local keychain identity passed at invocation; no keys/passwords are saved here.
The original /Applications/Zen.app and browser profiles must remain intact
until the custom app passes testing and an intentional backed-up promotion.

Only use app-scoped CUA for native testing. No global Computer/AppleScript or
browser-debugging connection. Run code/file tools for source and packaging.
Record actual native results separately from unit tests and signature checks.
