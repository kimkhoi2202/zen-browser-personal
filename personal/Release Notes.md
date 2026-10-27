Unofficial Zen (Prod), based on **Zen 1.23.4b**, with personal revision **personal.6**.

Download the macOS universal DMG in Assets, open it, and drag Zen (Prod) into Applications.
The macOS application supports Apple Silicon and Intel binary architectures. Native
smoke testing was performed on Apple Silicon; Intel hardware testing is pending.

- Exact configured search alias + Tab activates native site search.
- Up/Down navigate address-bar suggestions; Tab preserves the current suggestion.
- Provider-colored search badges omit redundant alias suffixes.
- Arc-style commands use Zen's existing command rows and browser actions.
- The top toolbar is enabled by default.
- Copy URL sits on the right of the address bar, immediately before the site-controls button, with the existing spacing retained.
- Developer-ID signed and Apple-notarized app and disk image, with stapled tickets.
- Every build, test, signing and packaging step runs locally; GitHub Actions is disabled.

Official Zen and Zen (Dev) can remain installed. Zen (Prod) keeps a separate local profile.
Your existing personal Zen (Prod) profile is retained when replacing the application.
New users start with their own empty profile; personal browsing data is not bundled.

**Updates are manual:** download and install subsequent releases from this repository.
No automatic browser updater is included. Search aliases must be configured in your
own profile. Password-manager integration, passkeys and DRM have separate requirements.
For 1Password desktop unlock and Touch ID, add Zen (Prod) separately in the
1Password desktop app's Settings > Browser > Add Browser. Trusting official Zen
does not also trust this app. See https://support.1password.com/additional-browsers/.

This stable release deliberately uses the latest published Zen release, not unreleased
upstream development commits. GitHub's comparison with upstream dev may show the fork
behind even when the packaged browser uses the current stable engine.

Source and license details accompany the release in Source.md. SHA256SUMS.txt and
Build.json identify the downloaded binary and its exact source commit. Native Firefox
engine compilation is not claimed: the package reuses the official released engine
with the fork's source-controlled UI changes and isolated application identity.
