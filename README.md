# Auto Title Update Sync

Auto Title Update Sync is an Aurora utility script that scans Aurora's local content database for installed Xbox 360 titles, builds a processing queue, queries a provider for title update metadata, and then either simulates or stages TU files to a configurable destination.

The script is built for the public [XboxUnity/AuroraScripts](https://github.com/XboxUnity/AuroraScripts) repository structure and only relies on documented AuroraScripts capabilities. It does not assume a documented public Lua API exists to directly install or register title updates inside Aurora.

This repository is packaged so the repository root is the script folder itself. Copy the repository contents into:

```text
AuroraScripts/UtilityScripts/AutoTitleUpdateSync/
```

## What It Does

- Scans Aurora's local database with the `sql` permission instead of assuming a web API exists for installed games.
- Extracts each title's name, Title ID, Media ID when available, and source path information.
- Builds an internal queue that can process one title or all titles.
- Supports `Scan only`, `Dry run`, `Download one selected game`, `Download all games`, and `Resume previous sync`.
- Uses a provider abstraction with a live `XboxUnityProvider` by default and a fully runnable `MockProvider` fallback.
- Downloads to a staging path first, then copies to the resolved final TU path only after verification.
- Writes timestamped log output to disk.
- Saves resumable queue state to disk.

## Repository Layout

```text
.
|- Main.lua
|- README.md
|- THIRD_PARTY_NOTICES.md
|- config.lua
|- icon.png
\- lib/
   |- Downloader.lua
   |- GameScanner.lua
   |- Logger.lua
   |- PathResolver.lua
   |- PathUtils.lua
   |- ProviderFactory.lua
   |- QueueProcessor.lua
   |- State.lua
   |- Ui.lua
   |- json.lua
   \- providers/
      |- MockProvider.lua
      \- XboxUnityProvider.lua
```

## Required Permissions

The script declares:

```lua
scriptPermissions = { "sql", "filesystem", "http" }
```

- `sql`: read Aurora's local content database
- `filesystem`: write logs, state, staged downloads, and TU output files
- `http`: query a remote provider and download update files

ZIP extraction is not enabled by default in this version because the public TU provider path is intentionally conservative and does not assume a documented archive workflow is available.

## Installation

1. Download or clone this repository.
2. Copy the repository contents into `AuroraScripts/UtilityScripts/AutoTitleUpdateSync/`.
3. Make sure Aurora can see the new script folder.
4. Launch the script from Aurora's utility scripts area.

## Switching Providers

Edit [config.lua](config.lua):

- Set `provider = "xboxunity"` for live TU lookup and download from XboxUnity.
- Set `provider = "mock"` for a testable, offline-safe run with sample data.

`XboxUnityProvider` now uses the public XboxUnity title update endpoints directly:

- `https://xboxunity.net/Resources/Lib/TitleUpdateInfo.php?titleid=...`
- `https://xboxunity.net/Resources/Lib/TitleUpdate.php?tuid=...`

No API key is required for the public lookup and download flow used by this script.

## Destination Path Logic

All final TU placement logic is isolated in [PathResolver.lua](lib/PathResolver.lua).

Important notes:

- The public AuroraScripts docs do not document a direct `install TU` Lua API.
- This script therefore treats TU handling as a file workflow.
- By default, lowercase TU filenames are routed to `Content\\0000000000000000\\{TitleID}\\000B0000\\`.
- By default, uppercase TU filenames are routed to `Cache\\`.
- You may need to change `target_subpath_template` in `config.lua` or edit `resolveTuDestination()` once you confirm the exact path convention for your setup.

## Dry-Run Mode

Dry-run mode performs scanning, queue building, provider lookups, and destination resolution without writing TU payload files to staging or final output paths.

This version still writes the normal log file and queue state file during dry-run so you can inspect what would have happened and resume a canceled run.

Important:

- Choosing `Dry run` in the menu is the only mode that suppresses TU payload writes.
- Choosing `Download one selected game` or `Download all games` performs a real write attempt.
- The `dry_run` value in [config.lua](config.lua) is kept for compatibility and reference, but the menu selection is what controls whether the current run writes files.
- If Aurora does not expose the server filename before download, dry-run will still show the real TU version but will mark the final destination as pending server filename resolution.

## Logging And Debugging

Log output is written to the path configured in `log_path`, which defaults to:

```text
Hdd1:\Aurora\AutoTU\autotu.log
```

State is written to:

```text
Hdd1:\Aurora\AutoTU\state.json
```

If a run is interrupted and the state file is still valid, the next launch will prompt:

```text
Resume previous sync?
```

## Known Limitations

- No documented public AuroraScripts API was assumed for direct TU install or activation.
- The default destination logic is intentionally centralized and conservative, not guaranteed correct for every Aurora setup.
- `XboxUnityProvider` depends on the public XboxUnity endpoints remaining reachable and response-compatible.
- AuroraScripts `Http.Get` does not publicly document response-header access, so the downloader first tries to preserve the server filename automatically and falls back to a staged filename if Aurora does not expose it cleanly.
- Queue cancellation is checked between queued items and retry boundaries. This version does not rely on undocumented streaming download callbacks.
- Archive extraction is not automatically performed in this version.

## Placeholder And Undocumented Areas

These parts are intentionally isolated because public documentation is incomplete:

- [GameScanner.lua](lib/GameScanner.lua): database table assumptions and schema discovery
- [PathResolver.lua](lib/PathResolver.lua): final TU destination path logic
- [XboxUnityProvider.lua](lib/providers/XboxUnityProvider.lua): provider response normalization and Media ID fallback behavior

## icon.png

`icon.png` is currently a placeholder copy from another utility script so the folder is immediately usable inside Aurora. Replace it with a custom icon when you have one.

## Attribution

- Framework target: [XboxUnity/AuroraScripts](https://github.com/XboxUnity/AuroraScripts)
- Embedded JSON library: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
