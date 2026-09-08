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
make test        # needs a Lua 5.1 interpreter: brew install luajit
```

Everything else has to be exercised in Lightroom. The log is at
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

- **`LR_size_maxHeight` is what constrains `longEdge`**, not `LR_size_maxWidth`. Setting only the
  width does nothing at all.

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

## Observed rather than documented

One behaviour is worth re-checking if the cover ever picks the wrong photo: `colorNameForLabel` is
documented as returning one of six English strings, but it reflects the catalog's Label Set text,
so a custom or localised set returns something else. The comparison is case-insensitive, and the
rules that need no label at all are the way around it.
