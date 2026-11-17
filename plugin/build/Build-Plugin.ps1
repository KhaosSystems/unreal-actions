<#
.SYNOPSIS
Compile a plugin source zip against an installed engine the way Fab does, with BuildPlugin.

.DESCRIPTION
Epic compiles every code plugin from the submitted source for each engine version on the listing,
on Windows and on a Mac, and one failure declines the whole submission. This runs the same
BuildPlugin on the same zip first, on the machine it runs on: Windows or a Mac.

The normal build is what Epic runs, and its output, with binaries, is what the tests load. An
optional second pass with -StrictIncludes turns off unity builds and precompiled headers, which
catches a .cpp that only compiles because some other file included what it needed.

Compiler errors and warnings in the plugin's own sources are reported as annotations on the
original file, so they show up on the pull request diff. Fab declines a plugin whose build warns,
so a pass with any warning there fails, unless -AllowWarnings.

.EXAMPLE
./Build-Plugin.ps1 -PackageZip ./dist/MyPlugin-1.2.0-UE5.8.zip -EngineVersion 5.8 -WorkDir C:\t\b -StrictIncludes
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$PackageZip,
	[Parameter(Mandatory)][string]$EngineVersion,

	# Scratch folder. Keep it short: plugin intermediates nest deep and Windows paths stop at 260.
	[Parameter(Mandatory)][string]$WorkDir,

	# Defaults to this machine's platform: Win64 on Windows, Mac on a Mac.
	[string]$TargetPlatforms,
	[switch]$StrictIncludes,

	# Where UnrealBuildTool may keep anything, instead of the machine-wide defaults other projects
	# on the build machine use. Defaults to a folder in WorkDir.
	[string]$CacheDir,

	# Report compiler warnings in the plugin's own sources without failing the build.
	[switch]$AllowWarnings
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

$HostPlatform = Get-HostPlatform
if (-not $TargetPlatforms) { $TargetPlatforms = $HostPlatform }

$EngineRoot = Find-UnrealEngine $EngineVersion
$RunUAT = Get-RunUATCommand $EngineRoot
Write-Host "Unreal Engine $((Get-UnrealEngineBuild $EngineRoot).Description) at $EngineRoot"

$WorkDir = Get-FullPath $WorkDir
if (-not $CacheDir) { $CacheDir = Join-Paths $WorkDir 'cache' }
$Cache = Get-PluginCache $CacheDir
Set-UnrealBuildToolIsolation $Cache
Write-Host "UnrealBuildTool caches in $($Cache.Root); remote executors and cache servers off"
$SourceRoot = Join-Paths $WorkDir 'src'
$LogDir = Join-Paths $WorkDir 'logs'
Expand-PluginZip -ZipPath (Get-FullPath $PackageZip) -Destination $SourceRoot
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$PluginFolder = @(Get-ChildItem -LiteralPath $SourceRoot -Directory)
if ($PluginFolder.Count -ne 1) { throw "Expected one plugin folder at the root of $PackageZip." }
$Descriptor = Get-PluginDescriptor $PluginFolder[0].FullName
$PluginName = $Descriptor.Name

$Diagnostics = New-Object System.Collections.Generic.List[object]
$ReportDiagnostic = New-CompileDiagnosticReporter -PluginName $PluginName -Label "UE $EngineVersion $HostPlatform" -Diagnostics $Diagnostics

# An engine cannot load an asset saved by a newer one, and BuildPlugin never loads content, so this
# is the only place a 5.8-saved asset in a 5.7 package gets caught before buyers find it.
$TooNew = Test-PluginContentVersions -PluginDir $Descriptor.Dir -EngineRoot $EngineRoot -EngineVersion $EngineVersion
if ($TooNew -gt 0)
{
	throw "$TooNew asset(s) were saved by a newer engine than Unreal Engine $EngineVersion and cannot load in it."
}

function Invoke-BuildPlugin([string]$PackageDir, [string]$LogName, [string[]]$Extra)
{
	# UAT writes its own and UBT's logs here, so they can be uploaded with the run.
	$env:uebp_LogFolder = Join-Paths $LogDir $LogName
	New-Item -ItemType Directory -Path $env:uebp_LogFolder -Force | Out-Null

	$Arguments = @(
		'BuildPlugin'
		"-Plugin=$($Descriptor.Path)"
		"-Package=$PackageDir"
		"-TargetPlatforms=$TargetPlatforms"
		'-nop4'
		'-utf8output'
	) + $Extra

	$Before = $Diagnostics.Count
	$ExitCode = Invoke-NativeCommand -FilePath $RunUAT.FilePath -ArgumentList (@($RunUAT.Arguments) + $Arguments) -OnLine $ReportDiagnostic
	if ($ExitCode -ne 0)
	{
		throw "BuildPlugin ($LogName) failed with exit code $ExitCode against Unreal Engine $EngineVersion on $HostPlatform. Fab would decline this submission."
	}

	$Failure = Get-CompileWarningFailure -Diagnostics @($Diagnostics | Select-Object -Skip $Before) -Pass "BuildPlugin ($LogName) on $HostPlatform" -EngineVersion $EngineVersion
	if ($Failure -and $AllowWarnings)
	{
		Write-Host "Warnings allowed (allow-warnings): $Failure"
	}
	elseif ($Failure)
	{
		Write-CiAnnotation error $Failure -Title "Warnings in UE $EngineVersion $HostPlatform"
		throw $Failure
	}
}

$PackageDir = Join-Paths $WorkDir 'out' $PluginName

Start-CiGroup "BuildPlugin $PluginName for UE $EngineVersion on $HostPlatform"
Invoke-BuildPlugin -PackageDir $PackageDir -LogName 'BuildPlugin' -Extra @()
Stop-CiGroup

if ($StrictIncludes)
{
	Start-CiGroup "BuildPlugin $PluginName for UE $EngineVersion on $HostPlatform, strict includes"
	$StrictDir = Join-Paths $WorkDir 'strict' $PluginName
	Invoke-BuildPlugin -PackageDir $StrictDir -LogName 'BuildPlugin-StrictIncludes' -Extra @('-StrictIncludes')
	Remove-Item -LiteralPath (Join-Paths $WorkDir 'strict') -Recurse -Force
	Stop-CiGroup
}

# BuildPlugin always builds the editor for this machine. Its module list is UnrealEditor.modules on
# every platform (ModuleManifest.GetStandardFileName; a Mac build is one universal binary, so it
# has no architecture suffix).
$Modules = Join-Paths $PackageDir 'Binaries' $HostPlatform 'UnrealEditor.modules'
if ((Test-PluginAllowsPlatform $Descriptor $HostPlatform) -and -not (Test-Path -LiteralPath $Modules))
{
	throw "BuildPlugin reported success but $Modules is missing; the editor would not load the plugin."
}

Write-Host "Built $PluginName for Unreal Engine $EngineVersion on $HostPlatform into $PackageDir"
Set-CiOutput 'plugin-dir' $PackageDir
Set-CiOutput 'plugin' $PluginName
