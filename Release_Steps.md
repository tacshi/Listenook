# Release Steps

Listenook is released locally from `main`. Public installers, updater archives,
and `listenook-latest.json` live in the separate public repository
`tacshi/Listenook-Release`; the source repository does not need to be public.

## First Listenook installation and update feeds

Existing MeowSTT users install Listenook manually once; first launch migrates
local data. The public repository keeps its existing `latest.json` frozen for
MeowSTT clients. Never replace it with a Listenook manifest or installer.
Listenook reads `main/listenook-latest.json`, and the publisher writes only that
file. Skipped platforms may retain an earlier **Listenook** package, never a
MeowSTT package. Until the first Listenook release, the new feed is not published.
Keep old release tags and assets intact so historical download links work.

The publisher also recognizes an existing `../MeowSTT-Release` checkout when
`../Listenook-Release` is absent. Its origin must point to
`tacshi/Listenook-Release`; `RELEASE_REPO_DIR` can explicitly select another checkout.

## One-time setup

Clone the release repository next to this checkout:

```sh
git clone git@github.com:tacshi/Listenook-Release.git ../Listenook-Release
```

Keep that checkout on its `main` branch; the updater's raw manifest URL points
to `main`. The publisher refuses a dirty checkout or an unexpected `origin` and
fast-forwards it before reading the previous manifest.
An empty release repository is supported: the first publish initializes a small
README commit before creating the GitHub release.

The repository must be public because installed apps fetch its raw manifest and
release assets without GitHub credentials. Re-authenticate the GitHub CLI before
the first release (the token on this machine was invalid when this workflow was
added):

```sh
gh auth login -h github.com
gh auth status
```

Configure the existing macOS Developer ID identity and `Listenook` notarytool
profile as described in `README.md`. Configure Windows signing through the
existing `LISTENOOK_WINDOWS_*` environment variables when a certificate is
available.

## Release

After the desired commit is merged and pushed to `main`, build Windows x64 on a
native x64 Windows host:

```powershell
git switch main
git pull
.\scripts\win-release.ps1 1.2.0
```

Copy both generated files from `build\` to `build/` on the Mac:

- `Listenook-1.2.0-windows-x64-release-setup.exe`
- `Listenook-1.2.0-windows-x64-release-setup.exe.build.json`

Then publish on the Mac:

```sh
git switch main
git pull
./scripts/release.sh 1.2.0
```

The script verifies that the Windows artifact came from the exact same commit,
builds and notarizes both macOS architectures, uploads every asset, and only
then pushes `listenook-latest.json`. Clients retry failed checks automatically and see a
persistent **Restart to Update** action after the package is verified.

Release notes are generated from commit subjects. To override them, create
`release-notes/Listenook-1.2.0.md` before running the publisher.
Before any build starts, the publisher displays the staged notes. Enter `e` to
open them in `$EDITOR` (then `$VISUAL`, falling back to `vi`), save and exit,
review the updated text, and enter `y` to continue.

## Dry runs and recovery

An unsigned, non-publishing dry run that does not require the Windows artifact:

```sh
LISTENOOK_MAC_SIGN_IDENTITY=- ./scripts/release.sh 1.2.0 --skip-windows --no-upload
```

Useful publisher options:

- `--skip-windows` publishes only the new macOS entries and preserves the last
  Windows entry in `listenook-latest.json`.
- `--reuse-artifacts` reuses `build/release/` after a late upload failure.
- `--no-upload` builds the artifacts and manifest without changing GitHub.
- `--no-tag` publishes without creating the source tag.
- `--allow-branch` bypasses the `main`/origin check for a deliberate test build.

If GitHub release creation succeeds but a later step fails, rerun with
`--reuse-artifacts`; the script updates the existing release assets with
`--clobber` and again publishes the manifest last.
