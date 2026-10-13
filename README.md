# unreal-actions

GitHub Actions for Unreal Engine projects, grouped by what they work on.

`plugin/` covers code plugins sold on Fab: it checks a plugin against Fab's requirements, builds
its source zip the way Epic does, runs its tests, releases it, and keeps its README badges current.

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

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref_type != 'tag' }}

jobs:
  plugin:
    uses: KhaosSystems/unreal-actions/.github/workflows/plugin.yml@v1
    permissions:
      contents: write
    with:
      engine-versions: '["5.8"]'
    secrets:
      discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

The plugin needs a `PlatformAllowList` on every module, a `Config/FilterPlugin.ini`, a copyright
notice naming the descriptor's `CreatedBy` on the first line of every source file, and tests named
`<Plugin>.<Area>.<Case>`. The first run says what is missing.

**Release:** push a `vX.Y.Z` tag. The run summary has the project file link and version notes to
paste into the Fab publisher portal, per engine version.

| Action | |
| --- | --- |
| [`plugin/package`](plugin/package/action.yml) | Fab checks, then the source zip Fab is given, per engine version. |
| [`plugin/build`](plugin/build/action.yml) | BuildPlugin on that zip against a Launcher-installed engine, plus a strict-includes pass. |
| [`plugin/test`](plugin/test/action.yml) | The plugin's automation tests in a headless editor. |
| [`plugin/release`](plugin/release/action.yml) | GitHub release, the `release` branch games follow, and the Fab checklist. |
| [`plugin/badges`](plugin/badges/action.yml) | Tests, engine versions and lines of code, for the README. Public repositories only. |

[`plugin.yml`](.github/workflows/plugin.yml) chains them; they can also be used one by one, as
`KhaosSystems/unreal-actions/plugin/<action>@v1`.

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
