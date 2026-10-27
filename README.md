# Zen (Prod) — Personal Zen fork

An **unofficial fork of [Zen Browser](https://github.com/zen-browser/desktop)** with Arc-style site-search activation, colored search badges, native command-bar actions, and a top toolbar. This project is maintained independently of the Zen team.

[Download releases](https://github.com/kimkhoi2202/zen-browser-personal/releases) · [Installation and updates](personal/Public%20Release.md) · [Build locally](personal/Releasing.md)

## Downloads

The public package is a signed and Apple-notarized macOS universal DMG. Apple Silicon is the native smoke-test platform; Intel hardware testing is pending. Windows and Linux builds are not provided.

Drag Zen (Prod) into Applications. It can coexist with official Zen and Zen (Dev), and uses its own profile on your Mac. No developer browsing data, accounts or extensions are included. Site-search shortcuts use the engines and aliases configured in your profile.

Browser updates are manual: download each new release from this repository. This fork does not use the official Zen binary updater. Release notes identify the upstream stable version, personal revision, exact source commit and checksum.

## Features

- Type an exact configured search alias, then Tab, to enter native site search.
- Navigate address-bar suggestions with Up/Down; Tab preserves the selected suggestion.
- Provider-colored search badges display concise names such as YouTube and Chordify.
- Search Arc-style browser commands through Zen's existing command results and UI.
- Use Zen's top toolbar by default.

## Development

Read [the agent handoff](personal/HANDOFF.md) and [local release instructions](personal/Releasing.md). The custom app reuses the official released engine and packages source-controlled UI overlays. A full native engine compile is a separate build path.

All release preparation, tests, signing, notarization and packaging run locally. GitHub Actions is disabled in this fork. Signing and notarization credentials remain in the maintainer's local Keychain.

GitHub's fork comparison follows upstream dev. Its behind count can include unreleased changes; public builds use the latest reviewed stable release, as pinned in [channels.json](personal/channels.json).

## Source and licenses

Zen and this fork use [MPL-2.0](LICENSE). Keep original license notices. Each release includes Source.md with the exact fork source and the complete upstream engine source. Third-party notices are retained in the application's about:license page.

Report fork-specific issues [here](https://github.com/kimkhoi2202/zen-browser-personal/issues). For official Zen, visit [zen-browser.app](https://zen-browser.app/).
