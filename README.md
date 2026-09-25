# confexport

`confexport` exports and imports portable Lite XL configuration profiles.

## Commands

- `confexport:export`: export the current configuration to a directory.
- `confexport:import`: preview, back up, and import a profile.
- `confexport:preview`: inspect a profile manifest without importing it.
- `confexport:restore-latest-backup`: restore the latest automatic backup.
- `confexport:bootstrap-import`: import the profile currently opened as a
  project; this command only exists in profiles exported with the bootstrap.
- `confexport:sync-setup`: clone or connect the configured Git repository.
- `confexport:sync-status`: show the local branch, working-tree state, and
  ahead/behind counts.
- `confexport:sync-pull`: fast-forward the repository, then preview and import
  its profile through the normal backup flow.
- `confexport:sync-push`: export a new snapshot, preview changed files, commit,
  and push after confirmation.

An exported profile contains `init.lua`, `user_settings.lua`, an LPM addon
inventory, custom plugins and libraries, and custom color schemes in `colors/`,
matching Lite XL's native directory and module namespace.

Managed addons are restored through LPM instead of being copied into the
profile. Session data, workspace state, caches, logs, and downloadable runtimes
are not exported.

## Optional bootstrap

The `Include Bootstrap` setting is enabled by default and can be disabled like
the other export options. It adds `.lite_project.lua`, a copy of `confexport`,
and a pure-Lua JSON implementation to the profile. It is an additional entry
point only: the profile format and the regular `confexport:import` command do
not depend on it.

On a new computer, open the exported directory as a Lite XL project and run
`confexport:bootstrap-import`. Merely opening it only registers the command: it
does not write files, make network requests, or start an import. Before applying
anything, the same preview detects existing user plugins, libraries, colors,
and settings, warns when the installation is not empty, and offers the normal
backup behavior.

If LPM is missing or cannot restore addons, the importer offers to continue
with local files only. Managed addons can then be installed later. Confexport
does not silently download or execute an LPM binary.

## Git synchronization

Git synchronization transports ordinary confexport profiles; it does not
replace or alter the profile format. Configure `Sync Repository`, then run
`confexport:sync-setup`. The remote can be hosted by GitHub, GitLab, Forgejo, or
any other Git server.

When `Sync Repository` is empty, confexport reuses the `origin` of its local
clone when available. Otherwise, the repository prompt suggests up to eight
recently used remotes, so their URLs do not need to be copied again. This
plugin-specific history is stored in `.confexport/repositories.json` under the
Lite XL user directory; URLs containing embedded passwords are never retained.

Confexport calls the local `git` executable directly without shell scripts. It
never stores credentials: HTTPS credentials are handled by Git's credential
manager, and SSH credentials by the user's SSH agent. Repository URLs embedding
a username and password are refused.

Pulls accept fast-forward updates only. Pushes require a clean working tree and
refuse to overwrite remote commits. Divergent histories and all merge conflicts
must be resolved manually. Nothing is committed until the exported file list is
shown and the user confirms the operation.

Before a push, `init.lua`, `user_settings.lua`, and `manifest.json` are scanned
locally for probable credentials such as tokens, passwords, private keys, or
credential-bearing URLs. Values are never shown. Suspected secrets block the
push by default; reviewed files can be added to `Secret Scan Exclusions`, or the
blocking option can be disabled explicitly. This is a heuristic safety check,
not a guarantee that every secret will be detected.

## Portability

The source platform and architecture are recorded as provenance only; they do
not prevent importing on another system. LPM resolves managed addons again for
the destination platform.

Custom plugins, libraries, or color schemes containing native binaries (`.so`,
`.dll`, `.dylib`, `.exe`, static libraries, object files, ELF, PE, or Mach-O)
are excluded as complete components so that a partially copied addon cannot be
imported accidentally. The manifest records what was excluded.

Absolute paths found in Lua and common text configuration formats are recorded
by filename and line number in the manifest. Their values are not rewritten or
copied into the report, and they never block an import. Confexport displays a
review warning when the source platform or architecture differs.

## Security

Profiles can contain executable Lua code, including `.lite_project.lua`. Only
open and import profiles from sources you trust. Confexport validates the
profile format, shows a summary, asks for confirmation, and creates a backup
before replacing matching local files.

## Requirements

- Lite XL mod version 3
- the standard `json` library for a regular installation (the optional
  bootstrap carries its own copy)
- LPM on `PATH`, bundled with Lite XL, or configured through `plugin_manager`
  only when restoring managed addons
- Git available on `PATH` only when using synchronization
