# Arc reference palette — personal.14

Requested October 31, 2026: match Arc's floating command and site-search UI,
including the user's YouTube reference. The normal toolbar and original Copy
URL placement are unchanged. Existing Actions, destinations, aliases, Tab mode
entry and Up/Down result navigation continue to use native Zen APIs.

`zen-personal-command-palette.css` styles only the floating palette: a 765px
maximum width, 64px input row, 50px result slots, a separator, pill-shaped mode
badge and provider-colored selection. YouTube uses Arc's bright red. Page action
buttons (including page zoom) are absent from the floating input. Search mode's
localized placeholder is Search…. The existing native result rows remain the
keyboard and accessibility implementation.

`PersonalSiteSearchHistory.sys.mjs` adds engine-scoped local recent searches
on entry, without requiring a character. It uses native FormHistory plus at most
100 search URLs for the current engine from Places, deduplicates them and returns
at most five native search suggestions. It never reads another browser's profile
or sends a request. Private windows and disabled history/form-fill suggestions
do not use this provider. FormHistory is read only when form fill is enabled;
Zen disables that by default, while visited search URLs remain available through
the independently enabled browsing history. Native remote providers remain eligible when typing.
There are no added timers, animations, observers or background polling.

The shared input patch sets the placeholder; the controller loads its Fluent
resource and stylesheet. Both the artifact packager and full-source jar/module
registries include the new files. Tests cover URL origin/path isolation, Unicode
decoding, recency, deduplication, private mode, history preferences, query
cancellation and existing keyboard behavior. Native verification is pending.

Build locally with scripts/personal/build_macos.py from a verified official base.
Never use an installed custom app as the input. Keep profiles and rollback copies
outside Git. Source checks, native testing, signing/notarization and installation
are separate steps. Nothing in this change authorizes a GitHub publication or
resuming the stopped PiP work.
