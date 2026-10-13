<#
.SYNOPSIS
Work out the next semver version from the conventional commits since the last vX.Y.Z tag.

.DESCRIPTION
feat bumps minor; fix, perf and revert bump patch; a breaking change bumps major, or minor while
the version is 0.x. Other commit types alone make no release, and the version comes back empty.
The repository needs its history and tags (a full clone, or fetch-depth 0).

.EXAMPLE
./Get-NextVersion.ps1 -RepoDir . -FailIfNone
#>
[CmdletBinding()]
param(
	[string]$RepoDir = '.',
	[string]$Ref = 'HEAD',

	# Fail rather than return an empty version when there is nothing to release.
	[switch]$FailIfNone
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

$Next = Get-NextVersion -RepoDir $RepoDir -Ref $Ref
$Since = 'the start'
if ($Next.Previous) { $Since = $Next.Previous }

if (-not $Next.Version)
{
	$Message = "Nothing to release: the $($Next.Commits.Count) commit(s) since $Since are none of feat, fix, perf or revert, and none is breaking."
	if ($FailIfNone)
	{
		Write-CiAnnotation error $Message -Title 'No release'
		throw $Message
	}
	Write-Host $Message
}
else
{
	Write-Host "Next version $($Next.Version), a $($Next.Bump) release since $Since."
	Add-CiSummary "Next version **$($Next.Version)**, a $($Next.Bump) release since $Since ($($Next.Commits.Count) commits)."
}

Set-CiOutput 'version' $Next.Version
$Tag = ''
if ($Next.Version) { $Tag = "v$($Next.Version)" }
Set-CiOutput 'tag' $Tag
Set-CiOutput 'bump' $Next.Bump
Set-CiOutput 'previous' ([string]$Next.Previous)
