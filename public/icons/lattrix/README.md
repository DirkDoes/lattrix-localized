# Lattrix brand SVGs

These public assets are served directly from `/icons/lattrix/`.

Each design has `-light.svg` and `-dark.svg` versions. Choose the variant for the background it appears on.

- `lattrix-icon`: main folded icon
- `lattrix-icon-localized`: folded icon with translation speech tag
- `lattrix-text`: Lattrix wordmark
- `lattrix-text-localized`: Lattrix Localized wordmark
- `lattrix-icon-small`: simplified small icon, with 9-unit bands on a 32-unit canvas

Example Rails usage: `image_tag "/icons/lattrix/lattrix-icon-localized-light.svg", alt: "Lattrix Localized"`.

The full-size artwork is unchanged. The app sidebar uses the Localized wordmark when expanded and the Localized icon when collapsed, following the app theme. Both Rails layouts use the small icon as their favicon, following the browser color-scheme preference.
