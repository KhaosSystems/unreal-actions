<#
.SYNOPSIS
Publish a plugin's badges: tests, supported engine versions and lines of code.

.DESCRIPTION
Writes shields.io endpoint files (tests.json, unreal.json, loc.json) to a branch of their own,
which a README shows through https://img.shields.io/endpoint?url=<raw file URL>. Only public
repositories work: shields.io reads the files without signing in.

Commits only when a badge changed. Needs a token that can push, in GH_TOKEN.

.EXAMPLE
./Update-Badges.ps1 -PluginDir ./plugin -EngineVersions 5.8 -ResultsDir ./results -Repository KhaosSystems/KhaosDocs
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$PluginDir,
	[Parameter(Mandatory)][string]$EngineVersions,

	# Folder holding the test-results.json of each engine version, in any subfolders.
	[string]$ResultsDir,

	[Parameter(Mandatory)][string]$Repository,
	[string]$Branch = 'badges',

	# Where to push instead of the GitHub repository, such as a local repository in tests.
	[string]$RemoteUrl
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/KhaosPluginCI.psm1') -Force

if (-not $RemoteUrl)
{
	if (-not $env:GH_TOKEN) { throw 'GH_TOKEN is not set; the badges branch cannot be pushed.' }
	$RemoteUrl = "https://x-access-token:$($env:GH_TOKEN)@github.com/$Repository.git"
}

$Engines = ConvertFrom-EngineVersions $EngineVersions
$Descriptor = Get-PluginDescriptor $PluginDir
$Results = @()
if ($ResultsDir -and (Test-Path -LiteralPath $ResultsDir))
{
	$Results = @(Get-ChildItem -LiteralPath $ResultsDir -Filter '*.json' -Recurse | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json })
}
$Badges = Get-PluginBadges -Engines $Engines -Results $Results -Lines (Measure-PluginSource $Descriptor)

$Work = Join-Paths ([IO.Path]::GetTempPath()) ('badges-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null

function Invoke-Git([string[]]$Arguments)
{
	$Result = Invoke-NativeQuiet git (@('-C', $Work) + $Arguments)
	return $Result.ExitCode
}

try
{
	if ((Invoke-Git @('init', '-q')) -ne 0) { throw 'git init failed.' }
	if ((Invoke-Git @('remote', 'add', 'origin', $RemoteUrl)) -ne 0) { throw 'git remote add failed.' }

	# Continue the branch when it exists, so its history is a log of badge changes.
	if ((Invoke-Git @('fetch', '-q', '--depth', '1', 'origin', $Branch)) -eq 0)
	{
		if ((Invoke-Git @('checkout', '-q', '-B', $Branch, 'FETCH_HEAD')) -ne 0) { throw "Checking out $Branch failed." }
	}
	elseif ((Invoke-Git @('checkout', '-q', '--orphan', $Branch)) -ne 0)
	{
		throw "Creating $Branch failed."
	}

	foreach ($Name in $Badges.Keys)
	{
		Write-Utf8File (Join-Paths $Work $Name) $Badges[$Name]
		Write-Host "  $Name  $($Badges[$Name])"
	}

	if ((Invoke-Git @('add', '-A')) -ne 0) { throw 'git add failed.' }
	$Status = Invoke-NativeQuiet git @('-C', $Work, 'status', '--porcelain')
	if (-not ($Status.Output | Where-Object { $_ }))
	{
		Write-Host 'Badges unchanged.'
		return
	}

	$Identity = @('-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com')
	if ((Invoke-Git ($Identity + @('commit', '-q', '-m', 'Update badges'))) -ne 0) { throw 'Committing the badges failed.' }
	if ((Invoke-Git @('push', '-q', 'origin', "HEAD:refs/heads/$Branch")) -ne 0) { throw "Pushing the $Branch branch failed." }
	Write-Host "Updated the badges on the $Branch branch."
}
finally
{
	Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
