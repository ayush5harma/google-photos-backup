# App icon

The finalized F palette combines mint, turquoise, lavender and blue in individually translucent aperture blades, with subdued gradients. The mark combines a muted camera aperture with a prominent opaque white infinity ribbon. Its rising stroke passes in front; an aperture blade covers part of the descending stroke so the loop appears woven around the shutter. Restrained gradients give the blades depth without the earlier bright flower treatment. Light and charcoal tiles support the two appearances.

The canonical artwork is `docs/app-icon.png` and `docs/app-icon-dark.png`, both 1024-pixel RGBA PNGs. The F light and dark designs were generated, compared with the owner and finalized on 2026-10-16. Blade translucency is rendered into the artwork (a visual approximation of 55–60% transparency), not stored as editable layers. A precise rounded-square alpha mask removes generated edge artifacts without changing the central artwork. Preserve these PNGs as source assets; the old procedural flower generator is no longer the source of truth.

`scripts/make-icon.swift` exports the canonical light or dark artwork for the macOS build. The build generates both appearance PNGs and a full-resolution ICNS. AppMark follows the SwiftUI color scheme, and the running app updates its Dock image with its effective appearance. Finder and the app before launch use the static light ICNS for compatibility with macOS 14 and later. Both tiles keep a transparent outer margin.

Windows uses the same light/dark PNGs for its header and multi-resolution ICOs for its running window. The checked-in ICOs contain 16, 24, 32, 48, 64, 128, and 256-pixel representations. Regenerate both after changing the canonical PNGs, for example with Pillow:

```python
from PIL import Image
for suffix in ("", "-dark"):
    Image.open(f"docs/app-icon{suffix}.png").save(
        f"Windows/GooglePhotosBackup.App/Assets/app-icon{suffix}.ico",
        sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)],
    )
```

The title bar follows the window theme; Explorer and the executable use the static light ICO. The README selects the appropriate artwork using the browser color scheme. Both appearances were inspected at 256 and 32 pixels before packaging.

The icon evokes photography and continuous backup; it does not imply Apple or Google affiliation or guarantee storage accounting.
