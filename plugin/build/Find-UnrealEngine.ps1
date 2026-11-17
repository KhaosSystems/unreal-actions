<#
.SYNOPSIS
Fail early, and clearly, when this machine does not have an engine version the plugin targets.

.DESCRIPTION
Prints which engine build will be used, so a run records exactly what it was tested against. A
missing engine is an error rather than a skipped version: Fab compiles the plugin for every engine
version on the listing, so a version that cannot be built here would ship untested.

On a Mac it also checks that xcode-select points at Xcode, which UnrealBuildTool compiles with.

.EXAMPLE
./Find-UnrealEngine.ps1 -EngineVersion 5.8
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$EngineVersion
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

$HostPlatform = Get-HostPlatform
$Root = Find-UnrealEngine $EngineVersion
$Build = Get-UnrealEngineBuild $Root
Write-Host "Unreal Engine $($Build.Description) at $Root"

if ($HostPlatform -eq 'Mac')
{
	$Developer = Get-XcodeDeveloperDir
	$Problem = Get-XcodeProblem $Developer
	if ($Problem)
	{
		Write-CiAnnotation error "$Problem ($([Environment]::MachineName))" -Title 'Xcode not found'
		throw $Problem
	}
	Write-Host "Xcode at $Developer"
}

Add-CiSummary "Built against Unreal Engine $($Build.Description) on $([Environment]::MachineName) ($HostPlatform)."
Set-CiOutput 'root' $Root
