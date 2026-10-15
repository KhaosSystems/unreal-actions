# unreal-actions

GitHub Actions for Unreal Engine projects, grouped by what they work on.

`plugin/` covers code plugins sold on Fab: it checks a plugin against Fab's requirements, builds
its source zip the way Epic does, runs its tests, releases it, and keeps its README badges current.
`commits/` checks commit messages and works out version numbers from them.

## Plugins

`.github/workflows/ci.yml` in the plugin's repository:

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch:
    inputs:
      release:
        description: Release the next version
        type: boolean
        default: false

concurrency:
  group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' || (github.event_name == 'push' && github.ref_type == 'branch') }}

jobs:
  plugin:
    uses: KhaosSystems/unreal-actions/.github/workflows/plugin.yml@v1
    permissions:
      contents: write
    with:
      engine-versions: '["5.8"]'
      release: ${{ inputs.release == true }}
    secrets:
      discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

The plugin needs a `PlatformAllowList` on every module, a `Config/FilterPlugin.ini`, a copyright
notice naming the descriptor's `CreatedBy` on the first line of every source file, and tests named
`<Plugin>.<Area>.<Case>`. The first run says what is missing.

**Commits** are [conventional commits](https://www.conventionalcommits.org), such as
`fix: crash when saving` or `feat(ui): outline panel`; every pull request and push checks them.

**Release:** Actions > CI > Run workflow on `main`, with *Release the next version* ticked. The
version comes from the commits since the last release: `feat` bumps the minor version; `fix`,
`perf` and `revert` the patch; a breaking change (`feat!:`, or a `BREAKING CHANGE:` footer) the
major, or the minor before 1.0. Commits of other types alone release nothing. The run builds,
tests, tags and publishes; its summary has the project file link and version notes to paste into
the Fab publisher portal. Pushing a `vX.Y.Z` tag yourself still works too.

| Action | |
| --- | --- |
| [`plugin/package`](plugin/package/action.yml) | Fab checks, then the source zip Fab is given, per engine version. |
| [`plugin/build`](plugin/build/action.yml) | BuildPlugin on that zip against a Launcher-installed engine, plus a strict-includes pass. |
| [`plugin/test`](plugin/test/action.yml) | The plugin's automation tests in a headless editor. |
| [`plugin/release`](plugin/release/action.yml) | GitHub release, the `release` branch games follow, and the Fab checklist. |
| [`plugin/badges`](plugin/badges/action.yml) | Tests, engine versions and lines of code, for the README. Public repositories only. |
| [`plugin/vendor`](plugin/vendor/action.yml) | A pull request that updates the copy of the plugin another repository keeps. |
| [`commits/check`](commits/check/action.yml) | Fails when a commit message is not a conventional commit. |
| [`commits/next-version`](commits/next-version/action.yml) | The next semver version from the commits since the last release. |

[`plugin.yml`](.github/workflows/plugin.yml) chains them; they can also be used one by one, as
`KhaosSystems/unreal-actions/<group>/<action>@v1`.

### Badges

```markdown
[![CI](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
![Tests](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/tests.json)
![Unreal Engine](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/unreal.json)
![Lines of code](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/loc.json)
[![Release](https://img.shields.io/github/v/release/OWNER/REPO)](https://github.com/OWNER/REPO/releases)
```

### Using a plugin in a game

Add it as a submodule tracking its `release` branch, which only ever holds released, tested
versions:

```bash
git submodule add -b release https://github.com/OWNER/PLUGIN Plugins/PLUGIN
```

and let Dependabot open a pull request when it moves, in the game's `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: gitsubmodule
    directory: /
    schedule:
      interval: daily
    allow:
      - dependency-name: Plugins/MyStudio* # your plugins; third-party submodules stay put
```

A private plugin cannot be a submodule of a game whose builds and people cannot all read it. The
game keeps a copy in `Plugins/PLUGIN` instead, and each stable release opens a pull request there
that replaces the copy with the release's source package. In the plugin's ci.yml:

```yaml
    with:
      vendor-to: '["OWNER/GAME"]'
    secrets:
      vendor-token: ${{ secrets.VENDOR_TOKEN }}
```

`VENDOR_TOKEN` is a fine-grained token for the game's owner with *Contents* and *Pull requests*
read and write on the game repositories.

## Build machine

Windows with the engine versions from the Epic Games Launcher and Visual Studio's C++ tools. Set
up a runner from an elevated PowerShell (`-WhatIf` first shows what it would do):

```powershell
.\runner\Install-BuildRunner.ps1 -Target my-org -Name unreal -RunnerGroup unreal -RunnerName gh-runner-windows-unreal-01
```

It runs the runner as a service under its own account, kept out of other runners' folders and
SteamCMD. Builds keep their caches in the runner's own workspace, never in the engine's
machine-wide defaults. `.\runner\Get-DiskReport.ps1` shows what is using the disk.

For public repositories, require approval for workflows from all outside contributors (the
organization's Settings > Actions > General), and read a pull request before approving it.

## Changing this repository

Callers use `@v1`; move that tag once a change has run on a real project. `tests\Invoke-SelfTest.ps1`
runs without an engine. Scripts stay ASCII and Windows PowerShell 5.1 compatible.
