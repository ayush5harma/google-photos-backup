# App icon

The mark combines eight translucent Photos-inspired color lenses with one continuous infinity loop. A pearl glass tile supports light interfaces; a graphite tile supports dark interfaces. The silhouette and spacing are identical in both appearances. There is no separate badge, lettering, cloud or arrow.

The reproducible AppKit artwork lives in `scripts/make-icon.swift`:

```sh
swift scripts/make-icon.swift docs/app-icon.png light
swift scripts/make-icon.swift docs/app-icon-dark.png dark
```

The macOS build generates both appearance PNGs and a full-resolution ICNS. AppMark follows the SwiftUI color scheme, and the running app updates its Dock image with its effective appearance. Finder and the app before launch use the static light ICNS for compatibility with macOS 14 and later. Both tiles keep a transparent outer margin.

Windows uses the same light/dark PNGs for its header and multi-resolution ICOs for its running window. The title bar follows the window theme; Explorer and the executable use the static light ICO. The README selects the appropriate artwork using the browser color scheme.

The icon evokes photo storage and unlimited backup; it does not imply Apple or Google affiliation or guarantee storage accounting.
