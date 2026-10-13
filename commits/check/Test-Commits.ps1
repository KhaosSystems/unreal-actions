<#
.SYNOPSIS
Fail when a commit in a range is not a conventional commit of a known type.

.DESCRIPTION
Versions and release notes are worked out from commit messages, so a message like "Fix: thing" or
"fixed stuff" would quietly leave a change out of both. Merge commits are skipped, and so is what
git revert writes. The repository needs the history of the range (fetch-depth 0).

.EXAMPLE
./Test-Commits.ps1 -RepoDir . -Base origin/main -Head HEAD
#>
[CmdletBinding()]
param(
	[string]$RepoDir = '.',

	# The commit before the range: a pull request's base, or what a push replaced. Empty or all
	# zeros, as for a newly pushed branch, means there is nothing to compare against.
	[string]$Base,

	[string]$Head = 'HEAD'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

if (-not $Base -or $Base -match '^0+$')
{
	Write-Host 'No earlier commit to compare against; nothing to check.'
	return
}

$Bad = Test-ConventionalCommits -RepoDir $RepoDir -Range "$Base..$Head"
if ($Bad -gt 0)
{
	Add-CiSummary "$Bad commit message(s) are not conventional commits; see the annotations."
	throw "$Bad commit message(s) are not conventional commits."
}
Write-Host 'Every commit message is a conventional commit.'
