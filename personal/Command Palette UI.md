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

## Installed local update

Installed at `/Applications/Zen.app` on October 31, 2026, as personal.14 from
`b6e28ada56ba3c4ea9dd5b9c7e65746abf81d8f5`. Apple notarization was Accepted;
the ticket was stapled and validated and Gatekeeper accepted the installed
candidate. The native engine still satisfies the outer app's Developer ID
designated requirement. No release, push, tag or GitHub Actions run was made.

All 96 Node checks and 11 Python checks pass. Native production-profile checks on
the preceding candidate verified the YouTube badge, five recent searches with
the first selected, Up/Down navigation, Tab preserving selection, actual Zoom Out
execution and the absence of the zoom indicator inside the floating palette.
The zoom test was reset. The final package additionally uses Arc's dark-blue
Actions badge and explicitly selects the first Actions result; those changes
have source/contract checks but their final native recheck is **pending**.

The computer-control service began timing out globally during the final recheck.
Only this task's candidate process was terminated. Its interrupted test profile
was retained separately; the verified pre-test daily profile was restored. All
11,945 fingerprints match the checkpoint before installation/launch. It contains
484 saved tabs, 375 bookmarks, 80 bookmark folders, 34,130 history visits and 12
user extensions. The original Dev profile was restored and its installed app was
not replaced. Other browser previews, simulators and the independent PiP build
were left running. The user was asked to open the installed Zen from the Dock;
do not report that this final reopening/visual check passed without new evidence.

Private rollback, signing/notarization and installation evidence:
`~/Library/Application Support/Zen Personal/Backups/Command Palette 2026-10-31`.
The runtime artifact and Apple report are in ignored
`dist/command-palette-production-14-ready`; see Generation Scripts/README.md for
the timestamp-signing recovery script and its archive/source verification.

The shared input patch sets the placeholder; the controller loads its Fluent
resource and stylesheet. Both the artifact packager and full-source jar/module
registries include the new files. Tests cover URL origin/path isolation, Unicode
decoding, recency, deduplication, private mode, history preferences, query
cancellation and existing keyboard behavior. Shared native view/manager patches
retain and select the matching engine's recent-search result even with Zen's
ordinary web-search heuristic hidden, and select the first Actions result.

Build locally with scripts/personal/build_macos.py from a verified official base.
Never use an installed custom app as the input. Keep profiles and rollback copies
outside Git. Source checks, native testing, signing/notarization and installation
are separate steps. Nothing in this change authorizes a GitHub publication or
resuming the stopped PiP work.
