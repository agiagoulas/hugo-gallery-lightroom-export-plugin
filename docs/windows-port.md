# Windows support

**Status: experimental and unverified.** The code paths exist and are believed correct, but the
plugin has only ever been run on macOS. If you use it on Windows, the section at the bottom says
what to report.

## What was platform-specific

Only one thing in the plugin ever leaves the Lightroom SDK: the git wrapper in
`HugoGalleryRepo.lua`. Everything else — the dialog, the export settings, filenames, front matter,
file IO — goes through `LrPathUtils`, `LrFileUtils` and `io`, which Adobe keeps portable. There is
exactly one `LrTasks.execute` in the whole plugin, no `os.execute` and no `io.popen`.

Three things differed, and all three now branch on the SDK's `WIN_ENV` global, in one block at the
top of that file:

| | macOS | Windows |
|---|---|---|
| git | `/usr/bin/git` — Lightroom from Finder has a minimal environment | probes `C:\Program Files\Git\cmd\git.exe` and the `(x86)` variant, then falls back to a bare `git`, which the installer normally puts on the system PATH |
| `PATH` prefix | prepended so the repo's own hooks find Homebrew tools | omitted — it is sh syntax, and cmd.exe would read it as a program name |
| Quoting | POSIX single quotes, `'` escaped as `'\''` | double quotes; a path containing `"` is refused rather than mangled, because cmd.exe cannot escape one |

Plus the cmd.exe workaround: when a command line contains quoted paths, the **whole line** needs
one further pair of double quotes around it or cmd mis-parses it. Long known, never documented.
It matters here as soon as the site folder or the temp directory contains a space — and both
routinely do.

One further change was not about git at all: `index.md` is now written with `io.open(path, 'wb')`.
In text mode, Lua on Windows turns every `\n` into `\r\n`, so the same album would carry different
line endings depending on who exported it.

## What is checked automatically

`make test` runs `test-commands.lua`, which stubs the SDK, loads the real `HugoGalleryRepo`, and
asserts the command line it builds — for both platforms. It covers the git path probe and its
fallback, the omitted `PATH` prefix, double-quoting, the outer cmd.exe wrapper, and that a path
containing a `"` is refused. That is not proof the plugin works on Windows, but it does mean the
string handed to `cmd.exe` is the intended one.

## Testing it for real

The Plug-in Manager has a **Test git** button. It runs the two command shapes the plugin actually
builds — one without a path, one with your site folder — and shows both command lines verbatim
along with their exit status and output. The second is the interesting one: the site folder is
where quoting breaks first.

Expected on a working setup:

```
Platform: Windows
git: C:\Program Files\Git\cmd\git.exe

""C:\Program Files\Git\cmd\git.exe" "--version" > "C:\Users\...\Temp\hugo-gallery-export-git-123.txt" 2>&1"
  -> status 0: git version 2.4x.x.windows.1

""C:\Program Files\Git\cmd\git.exe" -C "C:\Users\...\My Site" "rev-parse" "--abbrev-ref" "HEAD" > "..." 2>&1"
  -> status 0: main
```

A non-zero status, or output like `'C:\Program' is not recognized`, means the quoting is wrong.

## Still unverified

- The whole Windows path, end to end. Nobody has run it.
- The log location. On macOS it is
  `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoGallery.log`; the Windows equivalent is
  documented nowhere reliable, so the plugin does not claim one.
- Whether `LrTasks.execute`'s exit status is scaled the same way. It does not currently matter —
  the code only ever tests `== 0` — but it would if anyone wanted to distinguish git's exit codes.

## Reporting

Open an issue with the full output of **Test git**, your Lightroom Classic version, and where your
site folder lives (a path with a space in it is the interesting case). That is enough to fix the
quoting without access to a Windows machine.
