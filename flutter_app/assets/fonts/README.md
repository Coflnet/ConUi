# Bundled fonts

The web build is made with `--no-web-resources-cdn`, which bundles the
Flutter renderer itself - but Flutter web still separately fetches fonts
over the network on demand, so the app also needs its own fonts bundled
to avoid that. See item 3 of the production rollout brief: the only host
this app may contact is its own origin and the OpenStreetMap tile server.

## Roboto-Regular.ttf, Roboto-Medium.ttf, Roboto-Bold.ttf

Copied unchanged from this project's Flutter SDK (3.44.4) at
`bin/cache/artifacts/material_fonts/`, where Flutter itself ships them for
local rendering (golden tests etc.) - the exact same files Flutter's
Material widgets ask for as the default `Roboto` family, and exactly what
Flutter web would otherwise download from `fonts.gstatic.com` on first
render (or every offline reopening). Declaring them as this app's own
`Roboto` family in `pubspec.yaml` satisfies that request locally instead.

Licensed under the Apache License 2.0 - see `Roboto-LICENSE.txt` (copied
from the same SDK directory).

Only the three weights the app's Material 3 text theme and its own
`FontWeight.bold`/`w500`/`w600` usages need are bundled (Regular 400,
Medium 500, Bold 700); a `w600` request is synthesized from the nearest
available weight rather than fetched, and other weights (Light, Black,
Italic, ...) aren't included since nothing in this app asks for them.

## NotoSansSymbols.ttf

Roboto doesn't cover every symbol glyph (e.g. arrows). Declared as a
`fontFamilyFallback` in `main.dart`'s `ThemeData`, it's only consulted
for a character Roboto itself lacks, so it never triggers a network
fallback fetch either. Not currently exercised by any text this app
renders, but bundled up front as the same safety margin the sibling
`RfindFlutter` project uses for this exact problem, and to cover whatever
localisation/ICU punctuation ends up in the German/English ARB files.

Unmodified, from the official Google Fonts repository
(`ofl/notosanssymbols`), licensed under the SIL Open Font License 1.1 -
see `NotoSansSymbols-OFL.txt`.

## Verifying no font request happens

Load the app in headless Chromium with network logging and confirm no
request to `fonts.gstatic.com` (or any host besides the app's own origin
and the OpenStreetMap tile server) appears - see the production rollout
brief's item 3 and item 6h for the exact check.
