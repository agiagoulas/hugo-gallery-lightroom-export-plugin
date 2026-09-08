# Hugo Album — a Lightroom Classic export plugin

Exports the photos you have selected straight into a [Hugo](https://gohugo.io) site built on
[hugo-theme-gallery](https://github.com/nicokaiser/hugo-theme-gallery), as a finished album bundle:
correctly sized JPEGs under sequential names, plus a ready-made `index.md`.

It replaces the manual half of publishing an album — make a folder, export, resize, hand-write the
front matter — with one Export dialog. It never pushes: on a git-deployed site pushing *is* the
deploy, and that stays a deliberate act in a terminal.

```
Export → Hugo Album          content/venice/
  Title: Venice          →     venice-01.jpg … venice-42.jpg
  Categories: travel           index.md
  ☑ Create branch and commit   (on branch album/venice)
```

## Requirements

- Lightroom Classic (macOS — the git integration shells out to `/usr/bin/git`)
- A Hugo site in a **git working copy**, using hugo-theme-gallery's album layout

## Install

1. **File → Plug-in Manager → Add**, select `HugoAlbum.lrdevplugin`.
2. In the same window, set **Site folder** to your Hugo site's working copy. The panel says
   immediately whether it found a Hugo config, a git repo, and your albums folder.
3. Select photos → **File → Export** → *Export To: Hugo Album*.

Everything in the Plug-in Manager is a once-per-machine setting. The Export dialog only asks for
what genuinely differs album to album.

## Settings

| | |
|---|---|
| **Site folder** | The working copy. Must contain a Hugo config (`hugo.toml`, `config.yaml`, `config/_default/…` — any of the names Hugo accepts) and a `.git`. |
| **Albums in** | Relative path to where album bundles live, forward slashes. `content` if albums sit at the content root; `content/albums` if they are grouped in a section. |
| **Long edge / Quality** | Defaults 2048px and 92. hugo-theme-gallery never serves anything above 1600px, so 2048 is invisible on the page while leaving headroom — and small enough that photos can live in git. |
| **Write lat/lng** | Off by default. `lat`/`lng` are **not** part of hugo-theme-gallery; they only mean anything if your site has its own map layout reading them. Turning this on adds a Location field to the Export dialog. |

## What the export does

| | |
|---|---|
| **Size** | Your long edge, JPEG, sRGB — so a resize-on-commit step in your repo finds nothing left to do, and the downscale comes straight from the RAW instead of a second JPEG round through another tool. |
| **Metadata** | Full EXIF, no "minimize metadata" — this is what keeps `FNumber/ExposureTime/ISO/FocalLength/LensModel/Model` alive for the theme's lightbox captions. GPS is stripped from the files themselves. |
| **Filenames** | `<slug>-01.jpg` … zero-padded to at least two digits, so `sort_by: Name` still orders them correctly past nine. |
| **Front matter** | `date`, `title`, `sort_by`, `categories`, `description`, `resources` — theme-standard keys only (plus `lat`/`lng` if you enabled them). |
| **Auto-filled** | `date` from the earliest capture time, coordinates from the first photo carrying GPS. Both editable in the dialog. |
| **Cover** | Six rules: highest star rating, a colour label, the pick flag, first photo, last photo, or an explicit photo number. Ties and multiple matches go to the first in order, and the dialog says so. If nothing matches, the key is left out entirely and the theme falls back to the first image. |
| **Order** | The Lightroom order by default; capture time or filename if you prefer. |
| **Git** | Optionally `checkout -b album/<slug>`, `add -- <albums folder>/<slug>`, `commit`. Never `push`. |

The Export button stays dimmed with a reason underneath until the settings, title and slug are all
usable and the album folder is free — a misconfiguration can't get half an album onto disk.

Generated front matter looks like this:

```yaml
---
date: 2026-05-02
title: "Venice"
sort_by: Name
categories: ["travel", "2026"]
description: "A long weekend in Venice."
resources:
  - src: venice-17.jpg
    params:
      cover: true
---
```

## Testing

The two modules that could silently corrupt an album — slug/filename generation and YAML escaping —
import nothing from the Lightroom SDK, so they run outside Lightroom:

```bash
make test
```

Needs a Lua 5.1-compatible interpreter (`brew install luajit`). Everything else has to be exercised
in Lightroom; the log is at

```
~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoAlbum.log
```

not in `~/Documents/`, which is where older tutorials point and the usual reason `LrLogger` gets
reported as broken.

### Manual end-to-end run

1. Select 3 photos, one with a red label. Export → *Hugo Album*.
2. With no site folder set, the Export button should be dimmed. Set it in the Plug-in Manager → it
   enables, and stays set for every later export.
3. Type title `Test Album` → the slug fills in as `test-album`, and the preview shows
   `test-album-01.jpg … test-album-03.jpg`, the cover, the date and the destination path.
4. Untick *Create branch and commit*. Export.
5. Check the files — this is also what proves `updateExportSettings` actually took effect:
   ```bash
   exiftool -s -ImageWidth -ImageHeight -FNumber -ExposureTime -ISO -FocalLength -Model -LensModel content/test-album/*.jpg
   ```
   Long edge exactly your setting, all caption fields present, no `GPSLatitude`.
6. `hugo server` → the album renders, the lightbox caption shows the exposure line, and the cover
   is the photo you labelled.
7. `rm -rf content/test-album`, then export again with the same slug → the Export button dims with
   "content/test-album already exists."
8. Export once more with git enabled → branch `album/test-album`, one commit, `git show --stat`
   listing 3 JPEGs and `index.md`.

## Development

```
HugoAlbum.lrdevplugin/
  Info.lua                             manifest
  HugoAlbumExportServiceProvider.lua   locked export settings + processRenderedPhotos
  HugoAlbumExportDialogSections.lua    the Export dialog section
  HugoAlbumPluginInfoProvider.lua      the Plug-in Manager panel
  HugoAlbumPrefs.lua                   settings and their defaults
  HugoAlbumSlug.lua                    slug, transliteration, filename padding   (no SDK)
  HugoAlbumFrontMatter.lua             front-matter rendering and YAML escaping  (no SDK)
  HugoAlbumCoords.lua                  coordinate parsing                        (no SDK)
  HugoAlbumMetadata.lua                catalog reads: date, GPS, cover
  HugoAlbumRepo.lua                    site validation and the git wrapper
  HugoAlbumLog.lua                     shared logger
```

**Editing an existing `.lua` file** only needs *Reload Plug-in* in the Plug-in Manager. **Adding a
new one needs Lightroom restarted.** Reload re-runs the scripts Lightroom already knows about but
does not go looking for files that appeared since, and removing and re-adding the plugin is not
enough either — the file list is held for the session, not for the plugin entry. The symptom is
unmistakable: *"Could not load toolkit script: <Module>"* or *"No script by the name <File>.lua"*,
naming exactly the file you just created.

### Things here that are load-bearing and not obvious

- **`LR_size_maxHeight` is what constrains `longEdge`**, not `LR_size_maxWidth`. Setting only the
  width silently does nothing.
- **`git` runs with an explicit `PATH` prefix.** Lightroom launched from Finder has a minimal
  environment, and a pre-commit hook that starts `command -v exiftool >/dev/null || exit 0` would
  otherwise skip its check silently — worse than failing loudly.
- **`LrTasks.execute` returns `system()`-shaped status** on macOS, commonly `exitcode * 256`. Only
  `== 0` is a reliable test.
- **Nothing that can yield may run in `startDialog` or a property observer.** An observer runs
  inside the property table's assignment metamethod, and Lua 5.1 cannot yield across a C boundary
  at all — plain `pcall` included, which is why `LrTasks.pcall` exists. Reading the catalog or the
  file system from there produces *"Yielding is not allowed within a C or metamethod call"* and the
  dialog never opens. That is why validation is split into a pure half (`Repo.validateFields`,
  called on every keystroke) and an IO half (`Repo.validatePaths`, run in a task and cached).
- **The two rendition iterators are not interchangeable.** `exportSession:renditions()` just walks
  the list; `exportContext:renditions()` is what *starts* the rendering. `skipRender()` is only
  legal before rendering has begun, so an abort has to iterate the session.
- **`photosToExport()` yields a bare photo** — `for photo in ...`, not `for i, photo in ...`.
  Getting that wrong gives a silently empty list, not an error. The plugin sidesteps it by taking
  the photo order from `exportSession:renditions()`.
- **`visible` is not bindable** and layout containers (`row`, `column`, `spacer`) do not accept it
  at all, so conditional rows are built as conditionals in Lua instead.

One thing is observed rather than documented, so check it if the cover ever picks the wrong photo:
whether `colorNameForLabel` returns the English colour names under a custom or localised Label Set.
The *Flagged as pick* cover rule is locale-independent if it doesn't.

## Licence

MIT — see [LICENSE](LICENSE).
