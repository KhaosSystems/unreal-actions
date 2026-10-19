<#
.SYNOPSIS
Open a pull request in a game repository that updates its copy of a plugin to the plugin's latest
release.

.DESCRIPTION
Games take public plugins as submodules that follow the plugin's release branch, and Dependabot
proposes each release. A private plugin cannot be a submodule of a game whose builds and people
cannot all read it, so the game keeps a copy in its own history instead, and runs this on a
schedule. It finds the plugin's latest stable release and, when that differs from the copy,
proposes a pull request replacing the copy with the release's source package: the files Fab buyers
get, compiled and tested before the release was made.

The game pulls, so the plugin repository never needs to know which games use it or hold a token
that can write to them; the game holds one that can only read the plugin's releases.

Only the plugin folder and the files at the root of the game repository are checked out, and Git
LFS content is not downloaded, so a large game repository costs seconds. LFS still applies to the
new files, from the repository's own .gitattributes.

The pull request comes from one branch per plugin, plugins/<name>. A newer release replaces the
branch and retitles the open pull request, as Dependabot does, so commits added to that branch by
hand are lost then; make follow-up changes on a branch of your own. A pull request closed without
merging is not reopened for the same release.

Needs PLUGIN_TOKEN, a token that can read the plugin repository's releases, and GH_TOKEN, one that
can push branches and open pull requests in the game repository (the workflow's own token can).

.EXAMPLE
./Update-PluginCopy.ps1 -Plugin my-org/MyPlugin -Repository my-org/MyGame -DryRun
#>
[CmdletBinding()]
param(
	# The plugin's repository, owner/name.
	[Parameter(Mandatory)][string]$Plugin,

	# The game repository that keeps a copy, owner/name.
	[string]$Repository = $env:GITHUB_REPOSITORY,

	# Where the copy lives in the game repository. Defaults to Plugins/<plugin name>.
	[string]$Path,

	# Which engine's zip to copy, when the release has several. Defaults to the newest.
	[string]$EngineVersion,

	# Branch to propose the update to. Defaults to the game repository's default branch.
	[string]$Base,

	[string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'update-plugin'),

	# Clone, replace and commit, then stop before pushing.
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

function Invoke-Git
{
	$ExitCode = Invoke-NativeCommand -FilePath 'git' -ArgumentList $args
	if ($ExitCode -ne 0) { throw "git $($args -join ' ') failed with exit code $ExitCode." }
}

<# gh against the plugin repository, with the token that can read it. #>
function Invoke-PluginGh([string[]]$Arguments)
{
	$GameToken = $env:GH_TOKEN
	$env:GH_TOKEN = $env:PLUGIN_TOKEN
	try { return Invoke-NativeQuiet gh $Arguments }
	finally { $env:GH_TOKEN = $GameToken }
}

if (-not $env:PLUGIN_TOKEN) { throw "PLUGIN_TOKEN is not set; give a token that can read $Plugin's releases." }
if (-not $env:GH_TOKEN) { throw "GH_TOKEN is not set; give a token that can push to $Repository." }
if (-not $Repository) { throw 'Give the game repository with -Repository.' }

# The release ----------------------------------------------------------------------------------

# The latest release GitHub reports is never a prerelease or a draft.
$Response = Invoke-PluginGh @('api', "repos/$Plugin/releases/latest")
if ($Response.ExitCode -ne 0)
{
	$Check = Invoke-PluginGh @('api', "repos/$Plugin", '--jq', '.full_name')
	if ($Check.ExitCode -ne 0) { throw "Cannot read $Plugin with the token given. It needs read access to the repository's contents." }
	Write-Host "$Plugin has no stable release yet."
	Add-CiSummary "$Plugin has no stable release yet."
	exit 0
}
$Release = ($Response.Output -join "`n") | ConvertFrom-Json
$Tag = $Release.tag_name

$Zips = @($Release.assets | ForEach-Object {
	$Match = [regex]::Match($_.name, '-UE(\d+\.\d+)\.zip$')
	if ($Match.Success) { [pscustomobject]@{ Name = $_.name; Engine = [version]$Match.Groups[1].Value } }
} | Sort-Object Engine)
if ($Zips.Count -eq 0) { throw "$Plugin $Tag has no source zips." }

$Zip = $Zips[-1]
if ($EngineVersion)
{
	$Zip = $Zips | Where-Object { $_.Engine -eq [version]$EngineVersion } | Select-Object -First 1
	if (-not $Zip) { throw "$Plugin $Tag has no zip for Unreal Engine $EngineVersion." }
}

Reset-Directory $WorkDir
$Download = Invoke-PluginGh @('release', 'download', $Tag, '--repo', $Plugin, '--pattern', $Zip.Name, '--dir', $WorkDir)
if ($Download.ExitCode -ne 0) { throw "Downloading $($Zip.Name) from $Plugin $Tag failed." }

$Unpacked = Join-Paths $WorkDir 'package'
Expand-PluginZip -ZipPath (Join-Paths $WorkDir $Zip.Name) -Destination $Unpacked
$PluginDir = @(Get-ChildItem -LiteralPath $Unpacked -Directory)[0].FullName
$Descriptor = Get-PluginDescriptor $PluginDir
# Each zip is stamped with the engine it was built for, and an older engine refuses a plugin stamped
# with a newer one. The game compiles the copy with its own engine, so the stamp goes.
Write-Utf8File $Descriptor.Path (Remove-DescriptorField $Descriptor.Raw 'EngineVersion')
$Version = Get-JsonValue $Descriptor.Json 'VersionName' $Tag
if (-not $Path) { $Path = "Plugins/$($Descriptor.Name)" }
$Path = $Path.Replace('\', '/').Trim('/')

# The checksum table is for Fab submissions, not for reviewers of the update.
$Notes = ([string]$Release.body -split '(?m)^### Packages')[0].Trim()

# The copy -------------------------------------------------------------------------------------

# Authenticate git the way actions/checkout does, without writing the token to disk.
$Basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:GH_TOKEN"))
if (Test-GitHubActions) { Write-Host "::add-mask::$Basic" }
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
$env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $Basic"
$env:GIT_LFS_SKIP_SMUDGE = '1'
$env:GIT_TERMINAL_PROMPT = '0'

$Clone = Join-Paths $WorkDir 'repo'
# Checked out after the clone rather than by it: git 2.45.1 refuses a clone that runs the LFS
# post-checkout hook.
$CloneArguments = @('clone', '--depth', '1', '--filter=blob:none', '--sparse', '--no-checkout', '--quiet')
if ($Base) { $CloneArguments += @('--branch', $Base) }
Invoke-Git @CloneArguments "https://github.com/$Repository.git" $Clone
if (-not $Base) { $Base = (Invoke-NativeQuiet git @('-C', $Clone, 'branch', '--show-current')).Output | Select-Object -First 1 }
Invoke-Git -C $Clone sparse-checkout set '--' $Path
Invoke-Git -C $Clone checkout --quiet $Base

$Target = Join-Paths $Clone $Path
$Previous = $null
if (Test-Path -LiteralPath $Target)
{
	$Old = @(Get-ChildItem -LiteralPath $Target -Filter '*.uplugin' -File)
	if ($Old.Count -eq 1)
	{
		try { $Previous = Get-JsonValue ([IO.File]::ReadAllText($Old[0].FullName) | ConvertFrom-Json) 'VersionName' } catch { }
	}
	Invoke-Git -C $Clone rm -r -q --ignore-unmatch '--' $Path
	if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
}
New-Item -ItemType Directory -Path $Target -Force | Out-Null
Copy-Item -Path (Join-Path $PluginDir '*') -Destination $Target -Recurse -Force

# git add stores LFS-tracked files as pointers only with the filter set up, and git push uploads
# their content only with the LFS hooks installed.
$Attributes = Join-Paths $Clone '.gitattributes'
if ((Test-Path -LiteralPath $Attributes) -and (Select-String -LiteralPath $Attributes -Pattern 'filter=lfs' -Quiet))
{
	Invoke-Git -C $Clone lfs install --local
}
Invoke-Git -C $Clone add -A '--' $Path

$Changes = @((Invoke-NativeQuiet git @('-C', $Clone, 'diff', '--cached', '--name-status', '--no-renames')).Output)
if ($Changes.Count -eq 0)
{
	Write-Host "$Repository already has $($Descriptor.Name) $Version in $Path."
	Add-CiSummary "$Repository already has $($Descriptor.Name) $Version in ``$Path``."
	exit 0
}

# A scheduled run finds the same release again until the pull request is merged. When the branch
# already holds exactly this copy, there is nothing to push: the pull request is either open, or
# was closed without merging, which is a decision this does not overrule.
$Branch = "plugins/$($Descriptor.Name)"
$NewTree = (Invoke-NativeQuiet git @('-C', $Clone, 'write-tree', "--prefix=$Path/")).Output | Select-Object -First 1
if ((Invoke-NativeQuiet git @('-C', $Clone, 'fetch', '--quiet', '--depth', '1', '--filter=blob:none', 'origin', "refs/heads/$Branch")).ExitCode -eq 0)
{
	$BranchTree = (Invoke-NativeQuiet git @('-C', $Clone, 'rev-parse', "FETCH_HEAD:$Path")).Output | Select-Object -First 1
	if ($NewTree -and $BranchTree -eq $NewTree)
	{
		Write-Host "$Branch already proposes $($Descriptor.Name) $Version."
		Add-CiSummary "``$Branch`` already proposes $($Descriptor.Name) $Version to $Repository."
		exit 0
	}
}

if ($Previous) { $Title = "chore(deps): bump $Path from $Previous to $Version" }
else { $Title = "chore(deps): add $Path $Version" }

Invoke-Git -C $Clone -c 'user.name=github-actions[bot]' -c 'user.email=41898282+github-actions[bot]@users.noreply.github.com' commit -q -m $Title -m "Copied from the $Tag source package of $Plugin ($($Release.html_url))."
Write-Host "$Title`n$($Changes.Count) files changed:"
$Changes | ForEach-Object { Write-Host "  $_" }
if ($DryRun) { Write-Host "Dry run: not pushing $Branch to $Repository."; exit 0 }
Invoke-Git -C $Clone push --force --quiet origin "HEAD:refs/heads/$Branch"

# The pull request -----------------------------------------------------------------------------

$Body = @(
	"Updates ``$Path`` to [$($Descriptor.Name) $Version]($($Release.html_url)): the release's source package for Unreal Engine $($Zip.Engine), which was compiled and tested before the release was made."
	''
	$Notes
	''
	'---'
	'Opened by the plugin update workflow. A newer release replaces this branch and updates this pull request.'
) -join "`n"
$BodyFile = Join-Paths $WorkDir 'body.md'
Write-Utf8File $BodyFile $Body

$Owner = $Repository.Split('/')[0]
$Existing = (Invoke-NativeQuiet gh @('api', "repos/$Repository/pulls?state=open&head=${Owner}:$Branch", '--jq', '.[0].html_url // empty')).Output | Select-Object -First 1
if ($Existing)
{
	$Number = $Existing.Split('/')[-1]
	& gh api -X PATCH "repos/$Repository/pulls/$Number" -f "title=$Title" -F "body=@$BodyFile" --silent
	if ($LASTEXITCODE -ne 0) { throw "Updating $Existing failed." }
	$Url = $Existing
}
else
{
	$Url = (Invoke-NativeQuiet gh @('api', '-X', 'POST', "repos/$Repository/pulls", '-f', "title=$Title", '-f', "head=$Branch", '-f', "base=$Base", '-F', "body=@$BodyFile", '--jq', '.html_url')).Output | Select-Object -First 1
	if (-not $Url) { throw "Opening a pull request from $Branch into $Base in $Repository failed. The repository must allow GitHub Actions to create pull requests (Settings > Actions > General)." }
}

Write-Host "$Title`n$Url"
Add-CiSummary "Proposed $($Descriptor.Name) ${Version}: $Url"
Set-CiOutput 'url' $Url
