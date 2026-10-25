# Making a NotesCraft theme

A theme changes how the app looks: colors, type, icons and how round things are. It never changes what
the app does or where things are, and it contains no code. A theme is a folder whose name ends in
`.notecrafttheme`:

```
sunset.notecrafttheme/
  theme.json        the description (required)
  fonts/            font files the theme uses (.ttf, .otf)
  icons/            images that replace icons (.png, .pdf, .jpg)
  README.md         notes, license (optional; .md and .txt are allowed)
```

A complete example is in [`docs/themes/sunset.notecrafttheme`](themes/sunset.notecrafttheme).

## Installing

- Settings ▸ Appearance ▸ Theme ▸ **Add a theme…** and choose the folder in Files, or
- open the folder from Files or share it to NotesCraft.

The app checks the folder first. Anything that is not `theme.json`, a font, an image or a note is
refused, so is a symbolic link, a path that leaves the folder, a package over 20 MB or with more than
400 files. A theme with the id of another installed theme replaces it. Ids starting with
`app.notecraft.` belong to the themes that come with the app. Swipe an added theme in the gallery to
remove it.

## theme.json

```json
{
  "format": 1,
  "id": "com.example.sunset",
  "name": "Sunset",
  "author": "You",
  "version": "1.0",
  "colors":     { "light": { "accent": "#E4572E" }, "dark": { "accent": "#FF7A4D" } },
  "typography": { "design": "rounded", "family": "My Font", "files": ["fonts/MyFont.ttf"], "scale": 1.0 },
  "icons":      { "pencil.tip": "icons/pen.png", "star": "symbol:sparkles" },
  "shape":      { "cornerScale": 1.5 }
}
```

- `format` is 1. `id` is 3 to 64 lowercase letters, digits, dots, dashes and underscores, and
  starts with a letter or digit. `name` is shown in the gallery.
- **colors** are `#RRGGBB` or `#RRGGBBAA`. Give `light`, `dark` or both. A theme with one of them is
  only that scheme, whatever the iPad is set to. A theme with neither (only type, icons, shape) works
  in both. A color you leave out is taken from the Classic theme, so a theme may set a single color.
  Names the app does not know are ignored, so a theme made for a later version still loads.
- **typography.design** is `standard`, `serif`, `rounded` or `monospaced`. `family` names a font in
  `files` (its family or PostScript name); `scale` (0.8 to 1.3) multiplies every size.
- **icons** maps the name of an SF Symbol the app uses to either another symbol (`"symbol:name"`) or
  an image in the package. Images are drawn as templates (their color comes from the app) in a 22 point
  square, so draw them on a square canvas with a transparent background.
- **shape.cornerScale** (0 to 2.5) multiplies corner radii: 0 is square, 1 is as designed.

## Colors

| Name | What it colors |
| --- | --- |
| `background` | the library and the screens behind lists |
| `surface` | the sidebar panel, popovers and cards on the background |
| `surfaceRaised` | the chosen row, tiles and buttons on a surface |
| `field` | search fields and small round buttons |
| `separator` | lines between rows and around panels |
| `textPrimary`, `textSecondary`, `textTertiary` | text, from main to faint |
| `accent`, `accentText` | the main buttons and selections, and the text on them |
| `secondaryAccent` | what is highlighted next to the accent (pen style, eraser mode, welcome icon) |
| `favorite` | the bookmarked star of a document |
| `danger` | delete buttons |
| `editorSurround` | what shows around the pages of a notebook |
| `tabBar` | the strip with the notebook's tab |
| `toolBar`, `toolBarText` | the bar of tools and the icons on it (and on the tab strip) |
| `toolSelection`, `toolSelectionText` | the chosen tool |
| `quickBar`, `quickBarText`, `quickBarOutline` | the rounded bar of controls over the page |
| `sheet`, `sheetText`, `sheetSecondaryText` | dialogs for naming, creating and moving |

Settings ▸ Appearance also lets the reader replace `accent` and `secondaryAccent` on top of any theme.

## Check your theme

Text should be readable on its background in both schemes: a contrast ratio of at least 3 between
`textPrimary` and `background`/`surface`, `accentText` and `accent`, `toolBarText` and `toolBar`,
`toolSelectionText` and `toolSelection`, `quickBarText` and `quickBar`, `sheetText` and `sheet`. The
built-in themes are tested for it (`Tests/NoteCraftCoreTests/ThemeTests.swift`).
