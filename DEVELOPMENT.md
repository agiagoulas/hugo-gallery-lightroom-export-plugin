# Development notes

## Layout

```
HugoAlbum.lrdevplugin/
  Info.lua                             manifest
  HugoAlbumExportServiceProvider.lua   locked export settings + processRenderedPhotos
  HugoAlbumExportDialogSections.lua    the Export dialog section
  HugoAlbumPluginInfoProvider.lua      the Plug-in Manager panel
  HugoAlbumPrefs.lua                   settings and their defaults
  HugoAlbumSlug.lua                    slug, transliteration, filename padding   (no SDK)
  HugoAlbumFrontMatter.lua             front matter and YAML escaping            (no SDK)
  HugoAlbumCoords.lua                  coordinate parsing                        (no SDK)
  HugoAlbumMetadata.lua                catalog reads: date, GPS, cover
  HugoAlbumRepo.lua                    site validation and the git wrapper
  HugoAlbumLog.lua                     shared logger
```

The three modules marked *no SDK* import nothing from Lightroom. That is deliberate: they are the
ones that could silently write a broken `index.md`, so they stay runnable — and testable — outside
the host.

```bash
make test        # brew install luajit
```

That runs two suites, ~190 assertions. `test-pure.lua` covers the three SDK-free modules directly,
including the front-matter merge over hand-edited files. `test-commands.lua` stubs the SDK and
loads the real modules, so what it asserts is what would actually happen: the git command lines on
both platforms, `Repo.inspectAlbum`, the consent rule before appending, the batched metadata layer
and the cover rules, `Prefs` clamping and folder normalisation, and `updateExportSettings`.

`luajit` specifically, not any Lua 5.1 — that is what the Makefile calls and what the plugin runs
under inside Lightroom.

What is left for Lightroom is the parts that need a real catalog and a real export session: the
dialog's behaviour, and the rendition loop. The log is at
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoAlbum.log` — not in `~/Documents/`, which is
where older tutorials point and the usual reason `LrLogger` looks broken.

## Reloading

**Editing a `.lua` file** needs only *Reload Plug-in* in the Plug-in Manager. **Adding a new one
needs Lightroom restarted.** Reload re-runs the scripts Lightroom already knows about but does not
go looking for files that appeared since, and removing and re-adding the plugin is not enough
either — the file list is held for the session, not for the plugin entry. The symptom is
unmistakable: *"Could not load toolkit script: &lt;Module&gt;"* or *"No script by the name
&lt;File&gt;.lua"*, naming exactly the file you just created.

## Load-bearing and not obvious

Each of these is also commented at the point in the code where it matters. They are collected here
because every one of them fails *silently* — no error, just wrong output or a dialog that never
opens.

- **The size cap is on the short edge, and both `LR_size_maxHeight` and `LR_size_maxWidth` carry
  it.** Which one Lightroom reads for a `shortEdge` resize is not documented, so setting them to
  the same number is load-bearing rather than belt-and-braces. The value string `shortEdge` is not
  a guess — it appears in Lightroom's own `Export.lrmodule/…/ExportImageSizingSection.lua`
  alongside `dimensions`, `longEdge`, `megapixels` and `percentage`.

- **Nothing that can yield may run in `startDialog` or a property observer.** An observer runs
  inside the property table's assignment metamethod, and Lua 5.1 cannot yield across a C boundary
  at all — plain `pcall` included, which is why `LrTasks.pcall` exists. Reading the catalog or the
  file system from there produces *"Yielding is not allowed within a C or metamethod call"* and the
  dialog never opens. This is why validation is split into a pure half (`Repo.validateFields`,
  called on every keystroke) and an IO half (`Repo.validatePaths`, run in a task and cached).

- **The two rendition iterators are not interchangeable.** `exportSession:renditions()` just walks
  the list; `exportContext:renditions()` is what *starts* the rendering. `skipRender()` is only
  legal before rendering has begun, so an abort has to iterate the session — calling it on the
  context fails with *"must not be called after exportSession has started rendering"*, which then
  masks whatever the real reason for the abort was.

- **`LrDialogs.message` at `'info'` does not show while an export is being torn down.** The same
  call at `'warning'` or `'critical'` does. This cost three attempts to find: the summary for a
  cancelled export was silent, and everything around the call — including the Prefs access that
  builds its text — was byte-identical to a version that had been showing it. The only difference
  was that correctly classifying a cancel had moved the style from `'critical'` to `'info'`. The
  cancel summary is logged immediately before the dialog for exactly this reason, so the log tells
  you whether the handler ran or the dialog was swallowed.

- **Never raise out of the rendition loop.** A failure inside it is reported with
  `rendition:renditionIsDone(false, msg)`, collected, and the loop continues so the iterator
  drains; the failures are reported once at the end. Raising instead leaves renditions unconsumed
  and Lightroom waiting on the iterator. This shape is verified — cancelling an export mid-render
  reports cleanly and does not hang — so it is not the tangle it looks like, and collapsing it back
  into an `error()` would reintroduce the hang.

- **`photosToExport()` yields a bare photo** — `for photo in ...`, not `for i, photo in ...`.
  Getting that wrong gives a silently empty list, not an error. The plugin sidesteps it entirely by
  taking the photo order from `exportSession:renditions()`, which is by definition the exact set
  that will be rendered and iterates as `(index, rendition)`.

- **`LrTasks.execute` returns `system()`-shaped status** on macOS, commonly `exitcode * 256`. Only
  `== 0` is a reliable test; never compare against `1`.

- **`git` runs with an explicit `PATH` prefix.** Lightroom launched from Finder has a minimal
  environment, and a pre-commit hook that starts `command -v exiftool >/dev/null || exit 0` would
  otherwise skip its check silently — worse than failing loudly.

- **`visible` is not bindable**, and layout containers (`row`, `column`, `spacer`) do not accept it
  at all. Conditional rows are therefore built as conditionals in Lua while the view is
  constructed, which is enough here because those settings cannot change while the dialog is open.

- **`height_in_lines` must match the string's actual line count.** Too small and the Plug-in
  Manager clips the text with no warning.

- **`dateTimeOriginal` is not a Unix timestamp** — it counts seconds from 2001-01-01 UTC, so
  `os.date` on it is about 31 years out. Use `dateTimeOriginalISO8601`, or `LrDate.timeToIsoDate`.

## Catalog reads

`Metadata.read` fetches everything the album needs — capture date, filename, rating, pick flag,
colour label, GPS — in one `catalog:batchGetRawMetadata` call per selection, and everything
downstream works from that table. Two reasons it is worth keeping that way:

- The sort comparator runs O(n log n) times. Reading the catalog inside it, as it once did, paid
  for values that cannot change mid-sort thousands of times over on a large selection.
- The dialog caches the result for the selection, so changing the cover rule or the order costs no
  catalog access at all.

There is a per-photo fallback if the batch call ever fails, because a single unsupported key would
otherwise take the whole Export dialog down with it.

## Platforms

Everything platform-specific sits in one block at the top of `HugoAlbumRepo.lua`, branching on the
SDK's `WIN_ENV` global: which git to run, whether to prepend a `PATH`, and how to quote. The
Windows half is written but unverified — [docs/windows-port.md](docs/windows-port.md) covers what
differs and what the **Test git** button proves.

## Observed rather than documented

One behaviour is worth re-checking if the cover ever picks the wrong photo: `colorNameForLabel` is
documented as returning one of six English strings, but it reflects the catalog's Label Set text,
so a custom or localised set returns something else. The comparison is case-insensitive, and the
rules that need no label at all are the way around it.
