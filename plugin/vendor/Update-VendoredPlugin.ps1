<#
.SYNOPSIS
Open a pull request in another repository that updates its copy of the plugin to a release.

.DESCRIPTION
Games take public plugins as submodules that follow the release branch, and Dependabot proposes
each release. A private plugin cannot be a submodule of a repository whose builds and people cannot
all read it, so the game keeps a copy in its own history instead, and this proposes each release
as a pull request that replaces the copy with the release's source package: the files Fab buyers
get, compiled and tested before the release was made.

Only the plugin folder and the files at the root of the repository are checked out, and Git LFS
content is not downloaded, so a large game repository costs seconds. LFS still applies to the new
files, from the repository's own .gitattributes.

The pull request comes from one branch per plugin, plugins/<name>. A newer release replaces the
branch and retitles the open pull request, as Dependabot does, so commits added to that branch by
hand are lost then; make follow-up changes on a branch of your own.

Needs GH_TOKEN, a token that can push branches and open pull requests in the repository, and
SOURCE_TOKEN, one that can read this repository's releases (the workflow's own token can).

.EXAMPLE
./Update-VendoredPlugin.ps1 -PackageDir ./dist -Repository my-org/MyGame -Tag v1.2.0
#>
[CmdletBinding()]
param(
	# Folder with the zips from the package action.
	[Parameter(Mandatory)][string]$PackageDir,

	# The repository that keeps a copy, owner/name.
	[Parameter(Mandatory)][string]$Repository,

	# Release tag in this repository, for the link and notes.
	[Parameter(Mandatory)][string]$Tag,

	# Where the copy lives in that repository. Defaults to Plugins/<plugin name>.
	[string]$Path,

	# Which engine's zip to copy, when there are several. Defaults to the newest.
	[string]$EngineVersion,

	# Branch to propose the update to. Defaults to the repository's default branch.
	[string]$Base,

	# The plugin's repository, owner/name.
	[string]$SourceRepository = $env:GITHUB_REPOSITORY,

	[string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'vendor'),

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

if (-not $env:GH_TOKEN) { throw "GH_TOKEN is not set; give a token that can push to $Repository." }

# The release ----------------------------------------------------------------------------------

$Zips = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.zip' | ForEach-Object {
	$Match = [regex]::Match($_.Name, '-UE(\d+\.\d+)\.zip$')
	if ($Match.Success) { [pscustomobject]@{ File = $_; Engine = [version]$Match.Groups[1].Value } }
} | Sort-Object Engine)
if ($Zips.Count -eq 0) { throw "No source zips in $PackageDir." }

$Zip = $Zips[-1]
if ($EngineVersion)
{
	$Zip = $Zips | Where-Object { $_.Engine -eq [version]$EngineVersion } | Select-Object -First 1
	if (-not $Zip) { throw "No zip for Unreal Engine $EngineVersion in $PackageDir." }
}

Reset-Directory $WorkDir
$Unpacked = Join-Paths $WorkDir 'package'
Expand-PluginZip -ZipPath $Zip.File.FullName -Destination $Unpacked
$PluginDir = @(Get-ChildItem -LiteralPath $Unpacked -Directory)[0].FullName
$Descriptor = Get-PluginDescriptor $PluginDir
$Version = Get-JsonValue $Descriptor.Json 'VersionName' $Tag
if (-not $Path) { $Path = "Plugins/$($Descriptor.Name)" }
$Path = $Path.Replace('\', '/').Trim('/')

$ReleaseUrl = "https://github.com/$SourceRepository/releases/tag/$Tag"
$Notes = ''
if ($env:SOURCE_TOKEN)
{
	$TargetToken = $env:GH_TOKEN
	$env:GH_TOKEN = $env:SOURCE_TOKEN
	try { $Notes = (Invoke-NativeQuiet gh @('api', "repos/$SourceRepository/releases/tags/$Tag", '--jq', '.body')).Output -join "`n" }
	finally { $env:GH_TOKEN = $TargetToken }
	# The checksum table is for Fab submissions, not for reviewers of the update.
	$Notes = ($Notes -split '(?m)^### Packages')[0].Trim()
}

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

if ($Previous) { $Title = "chore(deps): bump $Path from $Previous to $Version" }
else { $Title = "chore(deps): add $Path $Version" }

$Branch = "plugins/$($Descriptor.Name)"
Invoke-Git -C $Clone -c 'user.name=github-actions[bot]' -c 'user.email=41898282+github-actions[bot]@users.noreply.github.com' commit -q -m $Title -m "Copied from the $Tag source package of $SourceRepository ($ReleaseUrl)."
Write-Host "$Title`n$($Changes.Count) files changed:"
$Changes | ForEach-Object { Write-Host "  $_" }
if ($DryRun) { Write-Host "Dry run: not pushing $Branch to $Repository."; exit 0 }
Invoke-Git -C $Clone push --force --quiet origin "HEAD:refs/heads/$Branch"

# The pull request -----------------------------------------------------------------------------

$Body = @(
	"Updates ``$Path`` to [$($Descriptor.Name) $Version]($ReleaseUrl): the release's source package for Unreal Engine $($Zip.Engine), which was compiled and tested before the release was made."
	''
	$Notes
	''
	'---'
	"Opened by the release workflow of $SourceRepository. A newer release replaces this branch and updates this pull request."
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
	if (-not $Url) { throw "Opening a pull request from $Branch into $Base in $Repository failed." }
}

Write-Host "$Title`n$Url"
Add-CiSummary "Proposed $($Descriptor.Name) $Version to ${Repository}: $Url"
Set-CiOutput 'url' $Url
