<#
.SYNOPSIS
Build a plugin's docs bundle for docs.khaos.systems and check it.

.DESCRIPTION
The bundle is Content/Docs plus a docs.json manifest, written to <OutDir>/<section>/<slug>/<version>/
as the README of KhaosSystems/docs-content describes. Each problem is reported on the plugin's own
file and line: as an error that fails the script with -Strict, otherwise as a warning.

With -Tag the bundle is that release's, and it is also zipped as <Repo>-<version>-docs.zip, with a
.sha256, to attach to the release. Without, it is a preview, in a folder named preview: what CI
checks on every run, and what to build locally to try the docs on the website.

.EXAMPLE
./plugin/docs/New-DocsBundle.ps1 -PluginDir ../MyPlugin -OutDir ../docs-content -EngineVersions 5.8
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$PluginDir,
	[Parameter(Mandatory)][string]$OutDir,

	# Engine versions as '5.7,5.8' or a JSON array, recorded in docs.json.
	[string]$EngineVersions,

	# The release tag, vX.Y.Z. Omit for a preview.
	[string]$Tag,

	# owner/name. Defaults to GITHUB_REPOSITORY, then the checkout's origin remote.
	[string]$Repository,

	# Whether the repository is private. Defaults to asking GitHub with gh, if it is installed.
	[switch]$Private,

	# Fail on problems instead of warning about them.
	[switch]$Strict
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

$Descriptor = Get-PluginDescriptor $PluginDir
if (-not (Test-Path -LiteralPath (Join-Paths $Descriptor.Dir 'Content' 'Docs') -PathType Container))
{
	if ($Strict)
	{
		$Message = "$($Descriptor.Name) has no Content/Docs to publish. Add the docs, or turn publish-docs off."
		Write-CiAnnotation error $Message -Title 'Docs'
		throw $Message
	}
	Write-Host "$($Descriptor.Name) has no Content/Docs; nothing to check."
	Set-CiOutput 'bundle-dir' ''
	Set-CiOutput 'zip' ''
	return
}

function Get-GitLine([string[]]$Arguments)
{
	$Result = Invoke-NativeQuiet git (@('-C', $Descriptor.Dir) + $Arguments)
	if ($Result.ExitCode -ne 0) { return $null }
	return ($Result.Output | Select-Object -First 1)
}

if (-not $Repository) { $Repository = $env:GITHUB_REPOSITORY }
if (-not $Repository)
{
	$Match = [regex]::Match([string](Get-GitLine @('remote', 'get-url', 'origin')), 'github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$')
	if ($Match.Success) { $Repository = $Match.Groups[1].Value }
}
if (-not $Repository) { throw 'Give the repository with -Repository owner/name.' }

$IsPrivate = [bool]$Private
if (-not $PSBoundParameters.ContainsKey('Private') -and (Get-Command gh -ErrorAction SilentlyContinue))
{
	$IsPrivate = (Invoke-NativeQuiet gh @('api', "repos/$Repository", '--jq', '.private')).Output -contains 'true'
}

$Commit = Get-GitLine @('rev-parse', 'HEAD')
if (-not $Commit) { throw "$PluginDir is not a git checkout. The bundle records the commit its docs come from." }

$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Released = [DateTime]::UtcNow.ToString('yyyy-MM-dd', $Invariant)
$Version = ''
if ($Tag)
{
	$Version = (ConvertFrom-ReleaseVersion $Tag).VersionName
	$Ref = $Tag
	# A re-run keeps the date of the release it completes, so it builds the same bundle.
	$Published = (Invoke-NativeQuiet gh @('release', 'view', $Tag, '--repo', $Repository, '--json', 'publishedAt', '--jq', '.publishedAt')).Output | Select-Object -First 1
	if ([string]$Published -match '^(\d{4}-\d{2}-\d{2})') { $Released = $Matches[1] }
}
else
{
	$Ref = $env:GITHUB_HEAD_REF
	if (-not $Ref) { $Ref = Get-GitLine @('branch', '--show-current') }
	if (-not $Ref) { $Ref = $env:GITHUB_REF_NAME }
	if (-not $Ref) { $Ref = 'HEAD' }
	$Stamp = Get-GitLine @('log', '-1', '--format=%ct', '--', 'Content/Docs')
	if ($Stamp) { $Released = [DateTimeOffset]::FromUnixTimeSeconds([long]$Stamp).UtcDateTime.ToString('yyyy-MM-dd', $Invariant) }
}

$Engines = @()
if ($EngineVersions) { $Engines = ConvertFrom-EngineVersions $EngineVersions }

Start-CiGroup "Docs of $($Descriptor.Name)"
$Bundle = New-DocsBundle -PluginDir $Descriptor.Dir -OutDir $OutDir -Version $Version -Ref $Ref -Commit $Commit -Repo $Repository -Private $IsPrivate -Engines $Engines -Released $Released
Write-Host "$($Bundle.Folder):"
$Bundle.Files | ForEach-Object { Write-Host "  $_" }
$Result = Test-DocsBundle -BundleDir $Bundle.Dir -AsWarnings:(-not $Strict)
Stop-CiGroup

$Pages = @($Bundle.Files | Where-Object { $_ -match '\.md$' }).Count
$Summary = @(
	"### Docs: $($Bundle.Manifest.name) $(Split-Path $Bundle.Folder -Leaf)"
	''
	"``$($Bundle.Folder)``: $Pages page(s), $($Bundle.Files.Count - $Pages - 1) image(s)."
)

if ($Result.Errors -gt 0)
{
	if ($Strict)
	{
		Add-CiSummary ($Summary -join "`n")
		throw "The docs of $($Descriptor.Name) have $($Result.Errors) problem(s). See the errors above."
	}
	$Summary += ''
	$Summary += "$($Result.Errors) problem(s) would stop publish-docs; see the warnings."
}

$Zip = ''
if ($Tag)
{
	$Zip = New-DocsBundleZip -BundleDir $Bundle.Dir -OutDir $OutDir
	Write-Host "Wrote $([IO.Path]::GetFileName($Zip)) (sha256 $(Get-FileSha256 $Zip))"
}

Add-CiSummary ($Summary -join "`n")
Set-CiOutput 'bundle-dir' $Bundle.Dir
Set-CiOutput 'zip' $Zip
