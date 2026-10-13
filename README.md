# unreal-actions

GitHub Actions for Unreal Engine code plugins sold on Fab. They check a plugin against Fab's
requirements, build its source zip the way Epic does, run its tests, release it, and keep its
README badges current.

## Use in a plugin

`.github/workflows/ci.yml`:

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
    uses: KhaosSystems/unreal-actions/.github/workflows/unreal-plugin.yml@v1
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

## Actions

| Action | |
| --- | --- |
| [`package`](package/action.yml) | Fab checks, then the source zip Fab is given, per engine version. |
| [`build`](build/action.yml) | BuildPlugin on that zip against a Launcher-installed engine, plus a strict-includes pass. |
| [`test`](test/action.yml) | The plugin's automation tests in a headless editor. |
| [`release`](release/action.yml) | GitHub release, the `release` branch games follow, and the Fab checklist. |
| [`badges`](badges/action.yml) | Tests, engine versions and lines of code, for the README. Public repositories only. |

[`unreal-plugin.yml`](.github/workflows/unreal-plugin.yml) chains them; a plugin can also use them
one by one.

## Badges

```markdown
[![CI](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
![Tests](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/tests.json)
![Unreal Engine](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/unreal.json)
![Lines of code](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/OWNER/REPO/badges/loc.json)
[![Release](https://img.shields.io/github/v/release/OWNER/REPO)](https://github.com/OWNER/REPO/releases)
```

## Plugins in games

Add the plugin as a submodule tracking its `release` branch, which only ever holds released,
tested versions:

```bash
git submodule add -b release https://github.com/OWNER/PLUGIN Plugins/PLUGIN
```

and have Dependabot open a pull request when it moves, in the game's `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: gitsubmodule
    directory: /
    schedule:
      interval: daily
    allow:
      - dependency-name: Plugins/Khaos*
```

## Build machine

Windows with the engine versions from the Epic Games Launcher and Visual Studio's C++ tools. Set
up a runner from an elevated PowerShell (`-WhatIf` first shows what it would do):

```powershell
.\runner\Install-BuildRunner.ps1 -Target KhaosSystems -Name unreal -RunnerGroup on-prem-unreal -RunnerName gh-runner-windows-unreal-01
```

It runs the runner as a service under its own account, kept out of other runners' folders and
SteamCMD. Builds keep their caches in the runner's own workspace, never in the engine's
machine-wide defaults. `.\runner\Get-DiskReport.ps1` shows what is using the disk.

For public repositories, require approval for workflows from all outside contributors (the
organization's Settings > Actions > General), and read a pull request before approving it.

## Changing this repository

Plugins use `@v1`; move that tag once a change has run on a plugin. `tests\Invoke-SelfTest.ps1`
runs without an engine. Scripts stay ASCII and Windows PowerShell 5.1 compatible.
