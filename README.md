# QuarantineClear

<img src="docs/icon.png" alt="QuarantineClear icon" width="128">

Removes the `com.apple.quarantine` flag from macOS app bundles, so apps that macOS refuses
to open can start. Drag them in, or let it scan `/Applications`.

It also tells you *whether* a flagged app is actually blocked, which the flag alone can't
answer. [That part matters more than the fix](#a-flag-is-not-a-broken-app).

---

## Read this first

Removing a quarantine flag disables a macOS security control. It is how malware gets to
run, and it is the thing the control exists to prevent.

- Use it on software you've obtained from a source you trust and checked yourself.
- No network access, no `sudo`, no launch agent, no background process. It runs when you
  launch it and stops.
- **Clearing is not reversible.** The download origin stored in the attribute is destroyed
  with it. The app shows you that origin before you clear anything.
- If you're unsure whether an app is legitimate, this is the wrong tool. Check the
  developer's signature and checksums first.

The app isn't sandboxed, on purpose: the App Sandbox denies the `/Applications` attribute
writes that are the entire point. It needs no privileges — `/Applications` is
`root:admin`, and admins can write there.

---

## Install

```sh
git clone https://github.com/MRZ07/QuarantineClear.git
cd QuarantineClear
./Install.sh
```

That builds, runs the tests, signs, and copies the app to `/Applications`. If you can't
write there, it installs to `~/Applications` and tells you why. It never runs `sudo`.

**Build from source rather than downloading a release.** Release builds are ad-hoc signed
and not notarised, so Gatekeeper quarantines them on download — the same flag this tool
removes. If you do download one, clear it once by hand:

```sh
xattr -rd com.apple.quarantine ~/Downloads/QuarantineClear.zip
unzip QuarantineClear.zip && open QuarantineClear.app
```

---

## Use it

`/Applications` loads on open. Otherwise drop any number of `.app` bundles, or a folder,
anywhere in the window.

- **Click** a row for details: download URL, which app set the flag, when, the signature,
  and how many files inside the bundle carry it.
- **Double-click** a row to launch the app.
- **Fix Selected (n)** clears what you picked, **Fix All (n)** clears every flagged bundle.
  A progress bar runs across, and each bundle reports *verified clean* or a failure.
- **Ask Gatekeeper** in a row's details gets a real verdict for that one bundle.

Search filters by name or path.

---

## A flag is not a broken app

macOS only consults Gatekeeper the first time an app is opened. Once you've approved an app
it runs from then on whether or not the flag is still there. So *carrying a flag* does not
mean *won't open* — and a list that paints every flagged app orange is lying to you.

This app checks the seal of every flagged bundle in the background after the scan, and the
dot answers what it found:

- **orange** — Gatekeeper would refuse it. Fix it.
- **grey** — flagged, but opens fine. The flag is inert.
- **hollow** — still checking. A filled dot would claim a verdict that doesn't exist yet.

Measured over the flagged apps in `/Applications` on one machine: 39 flagged, 37 grey,
2 orange — and the 2 match `spctl` exactly. A seal check costs about 5 seconds for 39
bundles, which is why it runs after the scan and fills rows in one by one instead of
blocking the window.

**Fix All** targets the orange rows only. An explicit selection still clears whatever you
picked — naming a row outranks the verdict.

One limit, stated plainly: the row's **Ask Gatekeeper** button runs the real `spctl`
check on demand. The background pass predicts its answer, and has agreed with it every
time it has been measured against, but `spctl` is the ground truth and the button is
there for when you want it.

---

## CLI

Same engine as the app, so the two can't disagree.

```sh
quarantine-clear scan [--scope immediate|recursive] [--deep] [--verify] [--json] <path>...
quarantine-clear fix  [--dry-run] [--json] <path>...
```

`scan --verify` runs the same seal pass the app runs in the background and marks the
rows Gatekeeper would refuse as `BLOCKED`.

```console
$ quarantine-clear scan ~/Applications
SomeApp  FLAGGED       -          https://example.com/SomeApp.dmg
Xcode    clean         -          /Applications/Xcode.app

1 flagged of 2 in Applications.
```

`scan` reads the bundle root only, which is what makes it fast. `--deep` walks each bundle
for per-file counts; on `/Applications` that's hundreds of thousands of paths, so it's opt-in.

Exit codes: `0` success, `1` a failure or an unverifiable result, `2` usage, `3` scan error.

---

## How it works

It calls `getxattr` and `removexattr` directly instead of shelling out to `xattr`. That
CLI is a poor fit here, and wrapping it produces a tool that lies to you. Measured on
macOS 26:

| `xattr` behaviour | Consequence |
| --- | --- |
| Exits **1** on an already-clean file | A wrapper reports "failed" for apps that were never blocked |
| Prints **nothing** on success | A real failure looks identical to a success |
| Exits **0** on a silent write failure | "Fixed" gets reported for an app that is still blocked |

So every state in the UI is a fresh read of the filesystem, and a clear is only reported as
successful after re-walking the bundle and re-reading. `xattr -c` is never used — a test
asserts that `com.apple.macl` and `com.apple.provenance` survive a clear.

Traversal never follows a symlink (`lstat` plus the kernel-level `XATTR_NOFOLLOW` flag) and
never crosses a device boundary, so a crafted bundle can't use this to strip flags from
files outside itself. A test plants exactly that symlink and asserts the out-of-tree file is
untouched.

```
Sources/
  QuarantineCore/     engine, no UI
    Xattr.swift             libc attribute access
    BundleWalker.swift      symlink-safe, device-bounded traversal
    AppScanner.swift        bundle discovery, derived state
    ClearService.swift      mutate, then verify by re-reading
    GatekeeperAssessor.swift  the honest answer, on demand
  QuarantineCLI/      command-line front end
  QuarantineClearApp/ SwiftUI front end
```

The icon is generated from `Tools/IconRenderer.swift`. No `.icns` is committed, so the app
and this README can't drift apart.

## Build

macOS 14+ and a Swift 6 toolchain. No Xcode project, no third-party dependencies.

```sh
swift build
swift test              # 48 tests
./Scripts/build-app.sh  # universal arm64 + x86_64, ad-hoc signed
```

`build-app.sh` runs the tests first, so a failing test blocks the build.

## Troubleshooting

**Permission denied on an app.** You aren't in the `admin` group. The CLI prints the exact
`errno`; the app won't escalate for you.

**Still won't open after fixing.** The flag wasn't the only problem. Open the row and read
the signature line — `com.apple.provenance` and a broken signature also block execution, and
no attribute removal fixes either.

**Only some files were cleared.** Expected, and reported. A bundle is a tree; the detail pane
shows the exact count.

## Licence

MIT. Removing a macOS security control is your responsibility — use it only on software you
trust.
