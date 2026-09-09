# Hugo Album

A Lightroom Classic export plugin for [Hugo](https://gohugo.io) sites built on
[hugo-theme-gallery](https://github.com/nicokaiser/hugo-theme-gallery). Select photos, fill in a
title, export — you get a finished album folder with correctly sized JPEGs and a ready-made
`index.md`.

```
Export → Hugo Album              content/venice/
  Title: Venice              →     venice-01.jpg … venice-42.jpg
  Categories: travel               index.md
  ☑ Create branch and commit       (on branch album/venice)
```

It never pushes. On a git-deployed site pushing *is* the deploy, so that stays a deliberate act in
a terminal — the most it will do is create a branch and commit.

## Requirements

Lightroom Classic, and a Hugo site using hugo-theme-gallery's album layout, in a git working copy.

Developed and used on macOS with Lightroom Classic 15. It should work further back — nothing here
is new SDK — but that is the only version it has actually run on. Windows support exists and has
never been run by anyone: see [docs/windows-port.md](docs/windows-port.md) and the **Test git**
button in the Plug-in Manager.

## Install

1. Download the repository — *Code → Download ZIP*, or clone it. The plugin is the
   `HugoAlbum.lrdevplugin` folder **inside** it, not the folder you downloaded.
2. **File → Plug-in Manager → Add**, select that `HugoAlbum.lrdevplugin` folder.
3. In the same window, set **Site folder**. The panel tells you straight away whether it found a
   Hugo config, a git repo and your albums folder.
4. Select photos → **File → Export** → *Export To: Hugo Album*.

Everything in the Plug-in Manager is set once per machine; the Export dialog only asks for what
differs album to album.

## Settings

| | |
|---|---|
| **Site folder** | Your site's working copy. Needs a `.git` and a Hugo config under one of the standard names (`hugo.toml`, `config.yaml`, `config/_default/…` and the rest). |
| **Albums in** | Where album bundles live, relative, forward slashes. `content`, or `content/albums` if they are grouped in a section. |
| **Long edge / Quality** | 2048px and 92 by default. The theme never serves above 1600px, so 2048 is invisible on the page while leaving headroom — and small enough that photos can live in git. |
| **Write lat/lng** | Off by default. These are **not** theme keys; they only matter if your site has its own map layout. Turning it on adds a Location field to the Export dialog. |

## What you get

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

- **Filenames** are zero-padded (`venice-01.jpg`), so `sort_by: Name` still orders them correctly
  past nine.
- **EXIF is kept** — aperture, shutter, ISO, lens — because that is what the theme's lightbox
  captions are built from. GPS is stripped from the files themselves.
- **The date** comes from the earliest capture time, offered as a menu of the dates your selection
  spans.
- **The cover** can be the highest-rated photo, a colour label, the pick flag, the first or last
  photo, or an explicit number. Nothing matching just leaves the key out, and the theme falls back
  to the first image.
- **Order** follows Lightroom by default; capture time and filename are also available.

The Export button stays dimmed with the reason underneath until everything is usable, so a
misconfiguration cannot leave half an album on disk.

## Adding to an album that already exists

When the title you type resolves to an album that is already there, the Export button stays dimmed
and says so. Tick **Add to the existing album** and the photos are appended: numbering continues
from the highest one already there (`venice-43.jpg`…), and existing files are never renamed.

The tick is deliberate, and it clears itself whenever the slug changes — typing *Dolomites New*
passes through the exact slug `dolomites` on the way, and appending to that album, or absorbing its
metadata, is never what you meant.

`index.md` is **merged, not rewritten**. Title, date, description, categories and coordinates are
updated from the dialog — and the dialog is prefilled with what the file already says, so you are
editing rather than retyping. Everything else is preserved exactly: `featured`, `layout`, `menu`, a
manual `sort_by: Params.weight`, the per-photo `title:` captions and `weight:` params, and any
Markdown below the front matter. The `resources` block is never rewritten, so **the cover of an
existing album is left alone** — change it in the file.

Two things follow from "merge never deletes": clearing a field in the dialog keeps whatever the
file had rather than removing the key, and the title you type wins, which is how you retitle an
album. The preview names the current title so the change is never invisible.

## Development

Layout, tests, and the SDK behaviours worth knowing before changing anything:
[DEVELOPMENT.md](DEVELOPMENT.md).

## Licence

MIT — see [LICENSE](LICENSE).
