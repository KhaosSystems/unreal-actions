# Shared helpers for the plugin CI scripts.
#
# Everything here has to run under Windows PowerShell 5.1, which is what the build machine and the
# `shell: powershell` steps use. That rules out ?:, ??, &&, Join-Path with more than two parts and
# [IO.Path]::GetRelativePath, and it is why files are written through .NET rather than
# Set-Content/Out-File, whose UTF-8 in 5.1 always carries a BOM.

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

#region GitHub Actions plumbing

function Test-GitHubActions
{
	return [bool]$env:GITHUB_ACTIONS
}

function ConvertTo-WorkflowCommandData([string]$Value)
{
	return $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function ConvertTo-WorkflowCommandProperty([string]$Value)
{
	return (ConvertTo-WorkflowCommandData $Value).Replace(':', '%3A').Replace(',', '%2C')
}

<#
.SYNOPSIS
Report a problem. On GitHub it becomes an annotation on the run and, given a file, on the diff.
#>
function Write-CiAnnotation
{
	param(
		[Parameter(Mandatory)][ValidateSet('error', 'warning', 'notice')][string]$Level,
		[Parameter(Mandatory)][string]$Message,
		[string]$File,
		[int]$Line = 0,
		[string]$Title
	)

	if (Test-GitHubActions)
	{
		$Properties = @()
		if ($File) { $Properties += "file=$(ConvertTo-WorkflowCommandProperty $File)" }
		if ($Line -gt 0) { $Properties += "line=$Line" }
		if ($Title) { $Properties += "title=$(ConvertTo-WorkflowCommandProperty $Title)" }

		$Command = "::$Level"
		if ($Properties.Count -gt 0) { $Command += ' ' + ($Properties -join ',') }
		Write-Host "${Command}::$(ConvertTo-WorkflowCommandData $Message)"
		return
	}

	$Colors = @{ error = 'Red'; warning = 'Yellow'; notice = 'Cyan' }
	$Where = ''
	if ($File -and $Line -gt 0) { $Where = " ${File}:${Line}" }
	elseif ($File) { $Where = " $File" }
	Write-Host "$($Level.ToUpperInvariant())$Where - $Message" -ForegroundColor $Colors[$Level]
}

function Add-Utf8Text([string]$Path, [string]$Text)
{
	[IO.File]::AppendAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-Utf8File([string]$Path, [string]$Text)
{
	[IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Set-CiOutput([string]$Name, [string]$Value)
{
	if ($env:GITHUB_OUTPUT)
	{
		Add-Utf8Text $env:GITHUB_OUTPUT "$Name=$Value`n"
	}
	else
	{
		Write-Host "  output $Name=$Value"
	}
}

function Add-CiSummary([string]$Markdown)
{
	if ($env:GITHUB_STEP_SUMMARY)
	{
		Add-Utf8Text $env:GITHUB_STEP_SUMMARY "$Markdown`n"
	}
}

function Start-CiGroup([string]$Name)
{
	if (Test-GitHubActions) { Write-Host "::group::$Name" } else { Write-Host "== $Name" -ForegroundColor Cyan }
}

function Stop-CiGroup
{
	if (Test-GitHubActions) { Write-Host '::endgroup::' }
}

#endregion

#region Paths and processes

function Join-Paths
{
	$Result = $args[0]
	for ($Index = 1; $Index -lt $args.Count; ++$Index)
	{
		$Result = [IO.Path]::Combine($Result, $args[$Index])
	}
	return $Result
}

<# A relative path is taken from PowerShell's location, as cmdlets take it. .NET alone uses the process's, which cd does not change. #>
function Get-FullPath([string]$Path)
{
	$Location = (Get-Location -PSProvider FileSystem).ProviderPath
	return [IO.Path]::GetFullPath([IO.Path]::Combine($Location, $Path))
}

<# Delete a directory and recreate it empty. #>
function Reset-Directory([string]$Path)
{
	if (Test-Path -LiteralPath $Path)
	{
		Remove-Item -LiteralPath $Path -Recurse -Force
	}
	New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

<#
.SYNOPSIS
Run a native command, streaming its output, and hand each line to a callback.

.DESCRIPTION
Windows PowerShell 5.1 wraps every stderr line of a redirected native command in an ErrorRecord,
and with $ErrorActionPreference = 'Stop' the first one aborts the script. Preference is relaxed
for the duration of the call and the lines are turned back into plain strings.
#>
function Invoke-NativeCommand
{
	param(
		[Parameter(Mandatory)][string]$FilePath,
		[string[]]$ArgumentList = @(),
		[scriptblock]$OnLine
	)

	Write-Host "> `"$FilePath`" $($ArgumentList -join ' ')" -ForegroundColor DarkGray

	try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try
	{
		& $FilePath @ArgumentList 2>&1 | ForEach-Object {
			$Line = "$_"
			Write-Host $Line
			if ($OnLine) { $null = & $OnLine $Line }
		}
		return $LASTEXITCODE
	}
	finally
	{
		$ErrorActionPreference = $PreviousPreference
		Reset-LastExitCode
	}
}

<#
.SYNOPSIS
Clear the exit code a native command left behind; the helpers return it instead.

.DESCRIPTION
A `shell: powershell` step ends with `exit $LASTEXITCODE`. Left set, a command that was allowed to
fail, such as a probe for a release that does not exist yet, would fail the step.
#>
function Reset-LastExitCode
{
	$global:LASTEXITCODE = 0
}

<#
.SYNOPSIS
Run a native command for its output alone, discarding stderr.
.OUTPUTS
ExitCode and Output, the stdout lines.
#>
function Invoke-NativeQuiet
{
	param(
		[Parameter(Mandatory)][string]$FilePath,
		[string[]]$ArgumentList = @()
	)

	# git writes UTF-8; read as the console's code page, names like Sondergaard with an o-slash break.
	try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

	# See Invoke-NativeCommand: redirecting stderr under 'Stop' would throw on its first line.
	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try
	{
		$Output = @(& $FilePath @ArgumentList 2>$null | ForEach-Object { "$_" })
		return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $Output }
	}
	finally
	{
		$ErrorActionPreference = $PreviousPreference
		Reset-LastExitCode
	}
}

#endregion

#region Unreal Engine

<#
.SYNOPSIS
Find an installed engine by version, e.g. '5.8'.

.DESCRIPTION
If UE_ROOT_<major>_<minor> is set, that is the engine, and it is an error for it to be anything
else; an explicit setting never quietly falls back to another install. Otherwise looks, in order,
at the Epic Games Launcher's install list, the registry key the launcher writes, and the default
install folder. The launcher list comes before the registry because the registry key is not
always written; a 5.8 launcher install was seen without one.

A missing engine is an error, not a warning: Fab compiles the plugin for every engine version on
the listing, so one that cannot be built here is one that would ship untested.
#>
function Find-UnrealEngine
{
	param([Parameter(Mandatory)][string]$Version)

	if ($Version -notmatch '^\d+\.\d+$')
	{
		throw "Engine version must look like '5.8', got '$Version'."
	}

	$OverrideName = 'UE_ROOT_' + $Version.Replace('.', '_')
	$Override = [Environment]::GetEnvironmentVariable($OverrideName)
	if ($Override)
	{
		$Problem = Test-UnrealEngineRoot $Override $Version
		if ($Problem)
		{
			$Message = "$OverrideName is set to '$Override', but $Problem Fix or unset it."
			Write-CiAnnotation error $Message -Title "Unreal Engine $Version not found"
			throw $Message
		}
		return (Get-FullPath $Override).TrimEnd('\')
	}

	$Candidates = New-Object System.Collections.Generic.List[string]

	$LauncherList = Join-Paths $env:ProgramData 'Epic' 'UnrealEngineLauncher' 'LauncherInstalled.dat'
	if (Test-Path -LiteralPath $LauncherList)
	{
		try
		{
			$Installs = ([IO.File]::ReadAllText($LauncherList) | ConvertFrom-Json).InstallationList
			foreach ($Install in $Installs)
			{
				if ($Install.AppName -eq "UE_$Version") { $Candidates.Add($Install.InstallLocation) }
			}
		}
		catch
		{
			Write-CiAnnotation warning "Could not read ${LauncherList}: $($_.Exception.Message)"
		}
	}

	$Registry = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$Version" -Name InstalledDirectory -ErrorAction SilentlyContinue
	if ($Registry) { $Candidates.Add($Registry.InstalledDirectory) }

	if ($env:ProgramFiles) { $Candidates.Add((Join-Paths $env:ProgramFiles 'Epic Games' "UE_$Version")) }

	foreach ($Root in $Candidates)
	{
		if (-not $Root) { continue }
		# A stale launcher entry or registry key can point at a removed or different engine.
		if (Test-UnrealEngineRoot $Root $Version) { continue }
		return (Get-FullPath $Root).TrimEnd('\')
	}

	$Machine = [Environment]::MachineName
	$Message = "Unreal Engine $Version is not installed on $Machine. Install it from the Epic Games Launcher, or set $OverrideName to its root folder. Looked in: $(($Candidates | Select-Object -Unique) -join '; ')"
	Write-CiAnnotation error $Message -Title "Unreal Engine $Version not found"
	throw $Message
}

<#
.SYNOPSIS
Check that a folder is an engine of the given version.
.OUTPUTS
Nothing if it is, otherwise what is wrong, as the end of a sentence.
#>
function Test-UnrealEngineRoot
{
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Version
	)

	if (-not (Test-Path -LiteralPath (Join-Paths $Root 'Engine' 'Build' 'BatchFiles' 'RunUAT.bat')))
	{
		return 'there is no engine there (no Engine\Build\BatchFiles\RunUAT.bat).'
	}

	$Found = (Get-UnrealEngineBuild $Root).Version
	if ($Found -ne $Version)
	{
		return "that is Unreal Engine $Found."
	}
	return $null
}

<#
.SYNOPSIS
Read an engine's version from Engine/Build/Build.version.
.OUTPUTS
Version (major.minor), and Description such as '5.8.2, changelist 56702186, ++UE5+Release-5.8'.
#>
function Get-UnrealEngineBuild
{
	param([Parameter(Mandatory)][string]$Root)

	$Path = Join-Paths $Root 'Engine' 'Build' 'Build.version'
	if (-not (Test-Path -LiteralPath $Path))
	{
		return [pscustomobject]@{ Version = 'unknown'; Description = 'unknown version' }
	}

	$Build = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
	return [pscustomobject]@{
		Version = "$($Build.MajorVersion).$($Build.MinorVersion)"
		Description = "$($Build.MajorVersion).$($Build.MinorVersion).$($Build.PatchVersion), changelist $($Build.Changelist), $($Build.BranchName)"
	}
}

#endregion

#region Caches

# Every cache the engine would otherwise keep in a per-user or machine-wide place is moved into one
# folder the caller owns. The build machine also builds other projects, whose caches must not be
# touched, and the defaults are shared:
#
#   UnrealBuildAccelerator  C:\ProgramData\Epic\UnrealBuildAccelerator for every engine on the
#                           machine, size capped (40 GB), so other builds' entries get evicted.
#                           Remote executors and UBA cache servers may be set up for other projects.
#   Zen                     One local server on port 8558 with a version-agnostic data folder in
#                           %LOCALAPPDATA%. An editor that wants a different data folder or version
#                           shuts the running server down, under whatever else was using it.
#   Derived data cache      %LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache for Launcher
#                           engines, plus any shared or cloud cache set up by environment variable.

<#
.SYNOPSIS
Create the cache folders for one engine version and describe them.
.OUTPUTS
Root, Ddc, Zen and Uba paths, and ZenPort, a port derived from the root so that two cache folders
on one machine do not collide and none uses the default 8558.
#>
function Get-PluginCache
{
	param([Parameter(Mandatory)][string]$CacheDir)

	$Root = (Get-FullPath $CacheDir).TrimEnd('\')
	$Cache = [pscustomobject]@{
		Root = $Root
		Ddc = Join-Paths $Root 'DerivedDataCache'
		Zen = Join-Paths $Root 'Zen'
		Uba = Join-Paths $Root 'UnrealBuildAccelerator'
		ZenPort = 0
	}
	foreach ($Path in @($Cache.Ddc, $Cache.Zen, $Cache.Uba))
	{
		New-Item -ItemType Directory -Path $Path -Force | Out-Null
	}

	$Sha = [Security.Cryptography.SHA256]::Create()
	try { $Hash = $Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())) } finally { $Sha.Dispose() }
	$Cache.ZenPort = 8600 + ((([int]$Hash[0]) * 256 + [int]$Hash[1]) % 400)
	return $Cache
}

<#
.SYNOPSIS
Point UnrealBuildTool at the given cache for the rest of this process and its children.

.DESCRIPTION
UnrealBuildTool turns UnrealBuildTool_<Section>__<Field> environment variables into its
highest-priority BuildConfiguration.xml, which is the only way to configure the UnrealBuildTool
that BuildPlugin runs.

Since 5.8 the UBA local executor is UnrealBuildTool's local executor and cannot be turned off, so
its root, where it keeps its store, is moved into the cache folder. Everything that would reach
beyond this machine or into another project's setup is off: remote UBA and Horde, UBA cache
servers, XGE, FASTBuild and SNDBS.
#>
function Set-UnrealBuildToolIsolation
{
	param([Parameter(Mandatory)]$Cache)

	$Settings = [ordered]@{
		'UnrealBuildAccelerator__RootDir' = $Cache.Uba
		# The default 40 GB is sized for whole games; plugins stay far below this.
		'UnrealBuildAccelerator__StoreCapacityGb' = '5'
		'UnrealBuildAccelerator__ForceNoCache' = 'true'
		'UnrealBuildAccelerator__bDisableHorde' = 'true'
		'BuildConfiguration__bAllowUBAExecutor' = 'false'
		'BuildConfiguration__bAllowXGE' = 'false'
		'BuildConfiguration__bAllowFASTBuild' = 'false'
		'BuildConfiguration__bAllowSNDBS' = 'false'
	}
	foreach ($Name in $Settings.Keys)
	{
		[Environment]::SetEnvironmentVariable("UnrealBuildTool_$Name", $Settings[$Name], 'Process')
	}
}

<#
.SYNOPSIS
Editor command line arguments that keep its caches in the given folder.

.DESCRIPTION
The derived data cache is limited to one local file store in the folder. Leaving the Zen, shared
and cloud stores out of the graph means no Zen server is started at all, which matters beyond the
data folder: starting one can shut down another, and updates Zen's per-user install. Zen's data
folder and port are still pointed at the folder in case something starts it regardless.
#>
function Get-EditorCacheArguments
{
	param([Parameter(Mandatory)]$Cache)

	return @(
		'-DDC=(Local)'
		"-LocalDataCachePath=`"$($Cache.Ddc)`""
		"-ZenDataPath=`"$($Cache.Zen)`""
		"-ini:Engine:[Zen.AutoLaunch]:DesiredPort=$($Cache.ZenPort)"
	)
}

#endregion

#region Plugin descriptor

function Get-JsonValue($Object, [string]$Name, $Default = $null)
{
	if ($null -eq $Object) { return $Default }
	$Property = $Object.PSObject.Properties[$Name]
	if ($Property) { return $Property.Value }
	return $Default
}

<#
.SYNOPSIS
Read the single .uplugin at the root of a plugin directory.
#>
function Get-PluginDescriptor
{
	param([Parameter(Mandatory)][string]$PluginDir)

	$PluginDir = (Get-FullPath $PluginDir).TrimEnd('\', '/')
	$Files = @(Get-ChildItem -LiteralPath $PluginDir -Filter '*.uplugin' -File)
	if ($Files.Count -ne 1)
	{
		throw "Expected exactly one .uplugin in '$PluginDir', found $($Files.Count)."
	}

	$Raw = [IO.File]::ReadAllText($Files[0].FullName)
	try
	{
		$Json = $Raw | ConvertFrom-Json
	}
	catch
	{
		throw "$($Files[0].Name) is not valid JSON: $($_.Exception.Message)"
	}

	return [pscustomobject]@{
		Name = $Files[0].BaseName
		FileName = $Files[0].Name
		Path = $Files[0].FullName
		Dir = $PluginDir
		Raw = $Raw
		Json = $Json
	}
}

<#
.SYNOPSIS
Set one top-level scalar field in .uplugin text, keeping the author's formatting.

.DESCRIPTION
Round-tripping through ConvertTo-Json would reflow the whole file and, in 5.1, escape every
apostrophe. The edit is checked by parsing the result, so a pattern that hit a nested key of the
same name is caught rather than shipped.
#>
function Set-DescriptorField
{
	param(
		[Parameter(Mandatory)][string]$Text,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)]$Value
	)

	if ($Value -is [string]) { $Literal = '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"' }
	else { $Literal = [string]$Value }

	$Pattern = '(?m)^([ \t]*)"' + [regex]::Escape($Name) + '"([ \t]*):([ \t]*)(?:"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null)'
	$Match = [regex]::Match($Text, $Pattern)
	if ($Match.Success)
	{
		$Replacement = $Match.Groups[1].Value + '"' + $Name + '"' + $Match.Groups[2].Value + ':' + $Match.Groups[3].Value + $Literal
		$Result = $Text.Substring(0, $Match.Index) + $Replacement + $Text.Substring($Match.Index + $Match.Length)
	}
	else
	{
		$Anchor = [regex]::Match($Text, '(?m)^([ \t]*)"FileVersion"[ \t]*:[ \t]*\d+[ \t]*,[ \t]*\r?\n')
		if (-not $Anchor.Success)
		{
			throw "Cannot add $Name to the descriptor: no `"FileVersion`": N, line to insert it after."
		}
		$NewLine = "`n"
		if ($Text.Contains("`r`n")) { $NewLine = "`r`n" }
		$Insert = $Anchor.Groups[1].Value + '"' + $Name + '": ' + $Literal + ',' + $NewLine
		$Result = $Text.Insert($Anchor.Index + $Anchor.Length, $Insert)
	}

	$Check = Get-JsonValue ($Result | ConvertFrom-Json) $Name
	if ([string]$Check -ne [string]$Value)
	{
		throw "Setting $Name in the descriptor did not take (read back '$Check'). Is the key nested somewhere unexpected?"
	}
	return $Result
}

<#
.SYNOPSIS
Remove one top-level scalar field from .uplugin text, keeping the author's formatting.
#>
function Remove-DescriptorField
{
	param(
		[Parameter(Mandatory)][string]$Text,
		[Parameter(Mandatory)][string]$Name
	)

	$Field = '"' + [regex]::Escape($Name) + '"[ \t]*:[ \t]*(?:"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null)'
	$Result = [regex]::Replace($Text, '(?m)^[ \t]*' + $Field + '[ \t]*,[ \t]*\r?\n', '')
	if ($Result -eq $Text)
	{
		# The last member has no comma after it, so the one before it goes instead.
		$Result = [regex]::Replace($Text, ',(?<eol>[ \t]*\r?\n)[ \t]*' + $Field + '[ \t]*(?=\r?\n)', '')
	}

	if ($null -ne (Get-JsonValue ($Result | ConvertFrom-Json) $Name))
	{
		throw "Removing $Name from the descriptor did not take. Is it written across several lines?"
	}
	return $Result
}

<#
.SYNOPSIS
Parse a release version such as 1.2.3 or 1.2.3-rc.1.
.OUTPUTS
VersionName (the full string) and Version, the integer Unreal compares to order releases.
#>
function ConvertFrom-ReleaseVersion
{
	param([Parameter(Mandatory)][string]$Version)

	$Match = [regex]::Match($Version, '^v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$')
	if (-not $Match.Success)
	{
		throw "Release version '$Version' is not MAJOR.MINOR.PATCH (optionally -prerelease)."
	}

	$Major = [int]$Match.Groups[1].Value
	$Minor = [int]$Match.Groups[2].Value
	$Patch = [int]$Match.Groups[3].Value
	if ($Minor -gt 999 -or $Patch -gt 999)
	{
		throw "Release version '$Version': minor and patch must be below 1000 to fit the integer Version."
	}

	return [pscustomobject]@{
		VersionName = $Version.TrimStart('v')
		Version = $Major * 1000000 + $Minor * 1000 + $Patch
	}
}

#endregion

#region Package contents

# What goes in a Fab source zip: what BuildPlugin packages by default (see FilterPluginFiles in
# BuildPluginCommand.Automation.cs), plus Config, which Fab requires in a code plugin submission.
# Config/FilterPlugin.ini then adds to it, exactly as it does for BuildPlugin.
$script:DefaultRules = @(
	'/Source/...'
	'/Content/...'
	'/Resources/...'
	'/Shaders/...'
	'/Config/...'
	'-/Tests/...'
)

# What BuildPlugin itself copies into the plugin it builds, before FilterPlugin.ini adds to it
# (FilterPluginFiles in BuildPluginCommand.Automation.cs). Epic builds the plugin Fab buyers download
# this way, so whatever this leaves out, they do not get: notably Config.
$script:BuildPluginRules = @(
	'/Binaries/ThirdParty/...'
	'/Resources/...'
	'/Content/...'
	'/Intermediate/Build/.../Inc/...'
	'/Shaders/...'
	'/Source/...'
	'-/Tests/...'
)

<# Compile FileFilter rules, '-' marking an exclusion, for Test-FilterRules. #>
function New-FilterRules([string[]]$Patterns)
{
	$Rules = @()
	foreach ($Rule in $Patterns)
	{
		$Exclude = $Rule.StartsWith('-')
		$Pattern = $Rule
		if ($Exclude) { $Pattern = $Rule.Substring(1).Trim() }
		$Rules += [pscustomobject]@{
			Regex = New-Object regex((ConvertTo-FilterRegex $Pattern), 'IgnoreCase, CultureInvariant')
			Exclude = $Exclude
		}
	}
	return ,$Rules
}

<# Whether rules from New-FilterRules include a '/'-separated relative path: the last match decides. #>
function Test-FilterRules($Rules, [string]$Relative)
{
	$Included = $false
	foreach ($Rule in $Rules)
	{
		if ($Rule.Regex.IsMatch($Relative)) { $Included = -not $Rule.Exclude }
	}
	return $Included
}

# Never shipped, wherever they appear and whatever FilterPlugin.ini says. Fab declines code plugins
# that contain build output, so this is not left to the filter.
$script:ExcludedFolders = @('Binaries', 'Intermediate', 'Saved', 'DerivedDataCache', '.vs', '.vscode', '.idea', '.git', '.github', '__pycache__')
$script:ExcludedFiles = @('.gitignore', '.gitattributes', '.gitmodules', '.gitkeep', '.DS_Store', 'Thumbs.db', 'desktop.ini')

<#
.SYNOPSIS
Turn an Unreal FileFilter pattern into a regex over '/'-separated relative paths.

.DESCRIPTION
Mirrors EpicGames.Core FileFilter.AddRule: a leading '/' anchors to the plugin root, a pattern with
no '/' at all matches at any depth, a trailing '/' means everything below, '...' spans any number
of folders, and '*' and '?' stay within one path segment.
#>
function ConvertTo-FilterRegex
{
	param([Parameter(Mandatory)][string]$Pattern)

	$Normalized = $Pattern.Trim().Replace('\', '/')
	if ($Normalized.StartsWith('/'))
	{
		$Normalized = $Normalized.Substring(1)
	}
	elseif (-not $Normalized.Contains('/') -and -not $Normalized.StartsWith('...'))
	{
		$Normalized = '.../' + $Normalized
	}
	if ($Normalized.EndsWith('/'))
	{
		$Normalized += '...'
	}

	# 'Foo...' is 'Foo*/...' and '...Foo' is '.../*Foo', as in FileFilter.
	$Normalized = [regex]::Replace($Normalized, '(?<=[^/])\.\.\.', '*/...')
	$Normalized = [regex]::Replace($Normalized, '\.\.\.(?=[^/])', '.../*')

	$Segments = $Normalized.Split('/')
	$Regex = New-Object System.Text.StringBuilder '^'
	for ($Index = 0; $Index -lt $Segments.Count; ++$Index)
	{
		$Segment = $Segments[$Index]
		$IsLast = ($Index -eq $Segments.Count - 1)

		if ($Segment -eq '...')
		{
			if ($IsLast) { [void]$Regex.Append('.+') }
			else { [void]$Regex.Append('(?:[^/]+/)*') }
			continue
		}

		foreach ($Char in $Segment.ToCharArray())
		{
			if ($Char -eq '*') { [void]$Regex.Append('[^/]*') }
			elseif ($Char -eq '?') { [void]$Regex.Append('[^/]') }
			else { [void]$Regex.Append([regex]::Escape([string]$Char)) }
		}
		if (-not $IsLast) { [void]$Regex.Append('/') }
	}
	[void]$Regex.Append('$')
	return $Regex.ToString()
}

function Get-FilterPluginRules
{
	param([Parameter(Mandatory)][string]$PluginDir)

	$Rules = @()
	$Ini = Join-Paths $PluginDir 'Config' 'FilterPlugin.ini'
	if (-not (Test-Path -LiteralPath $Ini)) { return $Rules }

	$InSection = $false
	foreach ($Line in [IO.File]::ReadAllLines($Ini))
	{
		$Trimmed = $Line.Trim()
		if (-not $Trimmed -or $Trimmed.StartsWith(';')) { continue }
		if ($Trimmed.StartsWith('['))
		{
			$InSection = ($Trimmed -eq '[FilterPlugin]')
			continue
		}
		if ($InSection) { $Rules += $Trimmed }
	}
	return $Rules
}

<#
.SYNOPSIS
List the files of a plugin that belong in its Fab source zip, as sorted '/'-separated paths
relative to the plugin root.

.DESCRIPTION
Rules are applied in order and the last one to match a file decides, as in Unreal's FileFilter.
Excluded folders are pruned while walking, so a local Intermediate full of object files costs
nothing.
#>
function Get-PluginPackageFiles
{
	param([Parameter(Mandatory)]$Descriptor)

	$Rules = New-FilterRules ($script:DefaultRules + (Get-FilterPluginRules $Descriptor.Dir))

	$Files = New-Object System.Collections.Generic.List[string]
	$Files.Add($Descriptor.FileName)

	$Pending = New-Object System.Collections.Generic.Stack[string]
	$Pending.Push($Descriptor.Dir)
	while ($Pending.Count -gt 0)
	{
		$Directory = $Pending.Pop()
		foreach ($Child in [IO.Directory]::GetDirectories($Directory))
		{
			if ($script:ExcludedFolders -notcontains [IO.Path]::GetFileName($Child)) { $Pending.Push($Child) }
		}
		foreach ($File in [IO.Directory]::GetFiles($Directory))
		{
			$Name = [IO.Path]::GetFileName($File)
			if ($script:ExcludedFiles -contains $Name) { continue }

			$Relative = $File.Substring($Descriptor.Dir.Length + 1).Replace('\', '/')
			if ($Relative -eq $Descriptor.FileName) { continue }

			if (Test-FilterRules $Rules $Relative) { $Files.Add($Relative) }
		}
	}

	$Sorted = $Files.ToArray()
	[Array]::Sort($Sorted, [StringComparer]::Ordinal)
	return ,$Sorted
}

<#
.SYNOPSIS
Write a zip with a stable layout: entries sorted, '/' separators, one root folder, fixed timestamps.

.DESCRIPTION
Compress-Archive in 5.1 writes '\' separators, which macOS and Linux unzip treat as part of the
file name. Fixed timestamps mean the same sources give the same bytes, so a checksum identifies a
build.
#>
function New-PluginZip
{
	param(
		[Parameter(Mandatory)][string]$SourceDir,
		[Parameter(Mandatory)][string[]]$Files,
		[Parameter(Mandatory)][string]$RootFolder,
		[Parameter(Mandatory)][string]$ZipPath
	)

	Add-Type -AssemblyName System.IO.Compression
	Add-Type -AssemblyName System.IO.Compression.FileSystem

	if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

	$Timestamp = New-Object DateTimeOffset (New-Object DateTime 2020, 1, 1, 0, 0, 0), ([TimeSpan]::Zero)
	$Stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew)
	try
	{
		$Zip = New-Object System.IO.Compression.ZipArchive $Stream, ([System.IO.Compression.ZipArchiveMode]::Create)
		try
		{
			foreach ($Relative in $Files)
			{
				$Entry = $Zip.CreateEntry("$RootFolder/$Relative", [System.IO.Compression.CompressionLevel]::Optimal)
				$Entry.LastWriteTime = $Timestamp
				$Source = [IO.File]::OpenRead((Join-Paths $SourceDir $Relative))
				try
				{
					$Target = $Entry.Open()
					try { $Source.CopyTo($Target) } finally { $Target.Dispose() }
				}
				finally
				{
					$Source.Dispose()
				}
			}
		}
		finally
		{
			$Zip.Dispose()
		}
	}
	finally
	{
		$Stream.Dispose()
	}
}

function Expand-PluginZip
{
	param(
		[Parameter(Mandatory)][string]$ZipPath,
		[Parameter(Mandatory)][string]$Destination
	)

	Add-Type -AssemblyName System.IO.Compression.FileSystem
	Reset-Directory $Destination
	# .NET Framework 4.6.2+ refuses entries that would land outside the destination.
	[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Get-FileSha256([string]$Path)
{
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

<#
.SYNOPSIS
The engine version a source zip is for, from its name (MyPlugin-1.2.0-UE5.8.zip). Nothing for any
other file, such as the docs zip a release also carries, so that is never taken for a Fab package.
#>
function Get-PackageEngineVersion([string]$Name)
{
	$Match = [regex]::Match($Name, '-UE(\d+\.\d+)\.zip$')
	if ($Match.Success) { return $Match.Groups[1].Value }
	return $null
}

#endregion

#region Content versions

# A custom version GUID as the engine declares it, FGuid(A, B, C, D), and as a package stores it: four
# little-endian uint32s.
function Format-CustomVersionKey([uint32[]]$Parts)
{
	return ($Parts | ForEach-Object { $_.ToString('X8') }) -join '-'
}

<#
.SYNOPSIS
The custom versions a .uasset or .umap was saved with, read from its package file summary.

.DESCRIPTION
Each system that changes how it saves bumps its own custom version, and the package records the
version of each one it used. An engine refuses a package with any version newer than its own.

.OUTPUTS
Key (see Format-CustomVersionKey) and Version for each, or nothing for a file that is not an
uncooked package of a known layout.
#>
function Get-UnrealPackageCustomVersions([string]$Path)
{
	$Stream = [IO.File]::OpenRead($Path)
	try
	{
		$Reader = New-Object IO.BinaryReader($Stream)
		# PACKAGE_FILE_TAG; PowerShell reads the literal as a signed int, so read the tag as one too.
		if ($Stream.Length -lt 32 -or $Reader.ReadInt32() -ne 0x9E2A83C1) { return }

		# The layout of FPackageFileSummary, in PackageFileSummary.cpp.
		$LegacyFileVersion = $Reader.ReadInt32()
		if ($LegacyFileVersion -gt -6) { return } # before the custom version format read here
		if ($LegacyFileVersion -ne -4) { $null = $Reader.ReadInt32() } # LegacyUE3Version
		$FileVersionUE4 = $Reader.ReadInt32()
		$FileVersionUE5 = 0
		if ($LegacyFileVersion -le -8) { $FileVersionUE5 = $Reader.ReadInt32() }
		$null = $Reader.ReadInt32() # FileVersionLicenseeUE
		if ($FileVersionUE4 -eq 0 -and $FileVersionUE5 -eq 0) { return } # unversioned, as cooked
		if ($FileVersionUE5 -ge 1016) { $null = $Reader.ReadBytes(24) } # PACKAGE_SAVED_HASH: SavedHash, TotalHeaderSize

		$Count = $Reader.ReadInt32()
		if ($Count -lt 0 -or $Count -gt 4096) { return }
		for ($Index = 0; $Index -lt $Count; ++$Index)
		{
			$Key = Format-CustomVersionKey @($Reader.ReadUInt32(), $Reader.ReadUInt32(), $Reader.ReadUInt32(), $Reader.ReadUInt32())
			[pscustomobject]@{ Key = $Key; Version = $Reader.ReadInt32() }
		}
	}
	catch [IO.EndOfStreamException] { }
	finally
	{
		$Stream.Dispose()
	}
}

<#
.SYNOPSIS
The newest custom versions an installed engine saves, for the version streams it lists in source.

.DESCRIPTION
The engine's main version streams (FortniteMain, UE5Main, UE5Release and others) list every version
with its number in Engine/Source/Runtime/Core/Public/UObject/*.inl, and DevObjectVersion.cpp gives
each stream's GUID. Launcher installs ship both. Nothing is returned if they cannot be read.

.OUTPUTS
A hashtable from key (see Format-CustomVersionKey) to Name and Latest.
#>
function Get-EngineCustomVersionLimits([string]$EngineRoot)
{
	$Limits = @{}
	$Core = Join-Paths $EngineRoot 'Engine' 'Source' 'Runtime' 'Core'
	$Registry = Join-Paths $Core 'Private' 'UObject' 'DevObjectVersion.cpp'
	$Lists = Join-Paths $Core 'Public' 'UObject'
	if (-not (Test-Path -LiteralPath $Registry) -or -not (Test-Path -LiteralPath $Lists)) { return $Limits }

	$Guids = @{}
	$Pattern = 'const\s+FGuid\s+F(\w+)::GUID\(\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*\)'
	foreach ($Match in [regex]::Matches([IO.File]::ReadAllText($Registry), $Pattern))
	{
		$Parts = @(2..5 | ForEach-Object { [Convert]::ToUInt32($Match.Groups[$_].Value, 16) })
		$Guids[$Match.Groups[1].Value] = Format-CustomVersionKey $Parts
	}

	foreach ($List in Get-ChildItem -LiteralPath $Lists -Filter '*.inl' -File)
	{
		$Numbers = @([regex]::Matches([IO.File]::ReadAllText($List.FullName), '(?m)^[ \t]*[A-Z0-9_]+_VERSION\(\s*\w+\s*,\s*(\d+)\s*\)') | ForEach-Object { [int]$_.Groups[1].Value })
		if ($Numbers.Count -eq 0) { continue }

		# FortniteMainBranchObjectVersions.inl lists FFortniteMainBranchObjectVersion.
		$Name = $List.BaseName
		if (-not $Guids.ContainsKey($Name) -and $Name.EndsWith('s')) { $Name = $Name.Substring(0, $Name.Length - 1) }
		if (-not $Guids.ContainsKey($Name)) { continue }

		$Limits[$Guids[$Name]] = [pscustomobject]@{
			Name = $Name
			Latest = ($Numbers | Measure-Object -Maximum).Maximum
		}
	}
	return $Limits
}

<#
.SYNOPSIS
Report the plugin's assets that an engine cannot load because a newer engine saved them.

.DESCRIPTION
5.8 loads what 5.7 saved, never the reverse, so content has to be saved with the oldest engine a
plugin supports. Each asset is an error annotation naming the versions that are too new.

.OUTPUTS
The number of such assets.
#>
function Test-PluginContentVersions
{
	param(
		[Parameter(Mandatory)][string]$PluginDir,
		[Parameter(Mandatory)][string]$EngineRoot,
		[Parameter(Mandatory)][string]$EngineVersion
	)

	$Content = Join-Paths $PluginDir 'Content'
	if (-not (Test-Path -LiteralPath $Content)) { return 0 }
	$Assets = @(Get-ChildItem -LiteralPath $Content -Recurse -File | Where-Object { $_.Extension -eq '.uasset' -or $_.Extension -eq '.umap' })
	if ($Assets.Count -eq 0) { return 0 }

	$Limits = Get-EngineCustomVersionLimits $EngineRoot
	if ($Limits.Count -eq 0)
	{
		Write-CiAnnotation warning "Could not read which asset versions Unreal Engine $EngineVersion supports from its source, so the content was not checked against it." -Title 'Content not checked'
		return 0
	}

	$Root = (Get-FullPath $PluginDir).TrimEnd('\', '/')
	$TooNew = 0
	foreach ($Asset in $Assets)
	{
		$Newer = @()
		foreach ($Saved in @(Get-UnrealPackageCustomVersions $Asset.FullName))
		{
			$Limit = $Limits[$Saved.Key]
			if ($Limit -and $Saved.Version -gt $Limit.Latest) { $Newer += "$($Limit.Name) $($Saved.Version), newest $($Limit.Latest)" }
		}
		if ($Newer.Count -gt 0)
		{
			$TooNew++
			$Relative = $Asset.FullName.Substring($Root.Length + 1).Replace('\', '/')
			Write-CiAnnotation error "Saved by a newer engine than Unreal Engine $EngineVersion, which cannot load it ($($Newer -join '; ')). Save content with the oldest engine the plugin supports." -File $Relative -Title "Too new for UE $EngineVersion"
		}
	}
	return $TooNew
}

#endregion

#region Build output

<#
.SYNOPSIS
Make a callback that turns compiler output lines into annotations on the plugin's own files.

.DESCRIPTION
BuildPlugin compiles a copy of the plugin under HostProject/Plugins/<Name>/, so everything after
that in a reported path is the path in the plugin's repository. Diagnostics in engine files are
skipped, except that an error raised inside an engine header, typically a template instantiated
with one of the plugin's types, is reported at the first note that points back into the plugin.
#>
function New-CompileDiagnosticReporter
{
	param(
		[Parameter(Mandatory)][string]$PluginName,
		[string]$Label = 'Compile'
	)

	$PluginPath = [regex]('(?i)[\\/]Plugins[\\/]' + [regex]::Escape($PluginName) + '[\\/](?<path>.+)$')
	# The compiler writes 'error', UnrealHeaderTool 'Error'.
	$Pattern = [regex]'^\s*(?<file>[A-Za-z]:[\\/][^(]+?)\((?<line>\d+)(?:,\d+)?\)\s*:\s*(?<level>(?i:fatal error|error|warning|note))(?:\s+(?<code>[A-Z]+\d+))?\s*:\s*(?<message>.+)$'
	$State = @{ Pending = $null; Reported = @{} }

	return {
		param([string]$Line)
		$Match = $Pattern.Match($Line)
		if (-not $Match.Success) { return }

		$Level = $Match.Groups['level'].Value.ToLowerInvariant()
		$PathMatch = $PluginPath.Match($Match.Groups['file'].Value)
		if ($Level -eq 'note')
		{
			if (-not $State.Pending -or -not $PathMatch.Success) { return }
			$Diagnostic = $State.Pending
			$Message = "$($Diagnostic.Groups['message'].Value.Trim()) (raised in $([IO.Path]::GetFileName($Diagnostic.Groups['file'].Value)), from here)"
		}
		elseif (-not $PathMatch.Success)
		{
			if ($Level -ne 'warning') { $State.Pending = $Match }
			return
		}
		else
		{
			$Diagnostic = $Match
			$Message = $Match.Groups['message'].Value.Trim()
		}
		$State.Pending = $null

		$File = $PathMatch.Groups['path'].Value.Replace('\', '/')
		$LineNumber = [int]$Match.Groups['line'].Value
		$Key = "$File|$LineNumber|$Message"
		if ($State.Reported.ContainsKey($Key)) { return }
		$State.Reported[$Key] = $true

		$DiagnosticLevel = $Diagnostic.Groups['level'].Value.ToLowerInvariant()
		$Severity = 'error'
		if ($DiagnosticLevel -eq 'warning') { $Severity = 'warning' }
		$Title = "$Label $DiagnosticLevel"
		if ($Diagnostic.Groups['code'].Success) { $Title += " $($Diagnostic.Groups['code'].Value)" }
		Write-CiAnnotation $Severity $Message -File $File -Line $LineNumber -Title $Title
	}.GetNewClosure()
}

#endregion

#region Validation

<#
.SYNOPSIS
Check a plugin against Fab's code plugin requirements and the problems that get submissions
declined.

.DESCRIPTION
Errors fail the build. Warnings are things a human should look at before submitting. Each rule
names the requirement so a failure explains itself.

.OUTPUTS
A result with Errors and Warnings counts.
#>
function Test-PluginPackage
{
	param(
		[Parameter(Mandatory)]$Descriptor,
		[Parameter(Mandatory)][string[]]$Files,
		[string]$CopyrightHolder
	)

	$State = @{ Errors = 0; Warnings = 0 }
	$Fail = {
		param([string]$Message, [string]$File, [int]$Line = 0)
		$State.Errors++
		Write-CiAnnotation error $Message -File $File -Line $Line -Title 'Fab requirement'
	}
	$Warn = {
		param([string]$Message, [string]$File, [int]$Line = 0)
		$State.Warnings++
		Write-CiAnnotation warning $Message -File $File -Line $Line -Title 'Fab check'
	}

	$Json = $Descriptor.Json
	$DescriptorFile = $Descriptor.FileName

	# Descriptor ------------------------------------------------------------------------------

	if ((Get-JsonValue $Json 'FileVersion') -ne 3)
	{
		& $Fail '"FileVersion" must be 3.' $DescriptorFile
	}
	if (-not (Get-JsonValue $Json 'FriendlyName'))
	{
		& $Fail '"FriendlyName" is empty.' $DescriptorFile
	}
	if (-not (Get-JsonValue $Json 'VersionName'))
	{
		& $Fail '"VersionName" is empty.' $DescriptorFile
	}
	if ((Get-JsonValue $Json 'Installed') -eq $true)
	{
		& $Warn '"Installed" is true. Source descriptors normally leave it false; BuildPlugin sets it on the packaged copy.' $DescriptorFile
	}
	if (Get-JsonValue $Json 'MarketplaceURL')
	{
		& $Warn '"MarketplaceURL" is the old Marketplace field. Fab uses "FabURL".' $DescriptorFile
	}
	if (-not (Get-JsonValue $Json 'FabURL'))
	{
		& $Warn '"FabURL" is not set. Expected until the listing is first approved, since only the live listing has its final URL; add it in the next update.' $DescriptorFile
	}

	$Modules = @(Get-JsonValue $Json 'Modules' @())
	if ($Modules.Count -eq 0)
	{
		& $Fail 'A code plugin needs at least one module in "Modules".' $DescriptorFile
	}
	foreach ($Module in $Modules)
	{
		$ModuleName = Get-JsonValue $Module 'Name'
		$Allow = @(Get-JsonValue $Module 'PlatformAllowList' @())
		$Deny = @(Get-JsonValue $Module 'PlatformDenyList' @())
		if ($Allow.Count -eq 0 -and $Deny.Count -eq 0)
		{
			& $Fail "Module '$ModuleName' needs a PlatformAllowList or PlatformDenyList. Fab requires one on every module." $DescriptorFile
		}

		$BuildFile = $Files | Where-Object { $_.StartsWith('Source/') -and $_.EndsWith("/$ModuleName.Build.cs") } | Select-Object -First 1
		if (-not $BuildFile)
		{
			& $Fail "Module '$ModuleName' has no $ModuleName.Build.cs under Source/." $DescriptorFile
		}
	}

	# Layout ----------------------------------------------------------------------------------

	foreach ($Folder in @('Source', 'Content', 'Config'))
	{
		if (-not ($Files | Where-Object { $_.StartsWith("$Folder/") } | Select-Object -First 1))
		{
			$Hint = ''
			if ($Folder -eq 'Config') { $Hint = ' Add Config/FilterPlugin.ini; it also controls which extra files ship.' }
			& $Fail "Fab requires a $Folder/ folder in a code plugin, and this package has none.$Hint"
		}
	}

	$Shipped = New-FilterRules ($script:BuildPluginRules + (Get-FilterPluginRules $Descriptor.Dir))
	foreach ($File in ($Files | Where-Object { $_.StartsWith('Config/') -and $_ -ne 'Config/FilterPlugin.ini' }))
	{
		if (-not (Test-FilterRules $Shipped $File))
		{
			& $Fail "Fab buyers would not get $($File): BuildPlugin, which Epic builds the plugin with, copies Config files only when Config/FilterPlugin.ini lists them. Add /$File (or /Config/...) under [FilterPlugin]." $File
		}
	}

	$HasAssets = $Files | Where-Object { $_ -match '^Content/.*\.(uasset|umap)$' } | Select-Object -First 1
	if ($HasAssets -and (Get-JsonValue $Json 'CanContainContent') -ne $true)
	{
		& $Fail 'Content/ has assets but "CanContainContent" is not true, so the engine will not mount them.' $DescriptorFile
	}

	if (-not ($Files -contains 'Resources/Icon128.png'))
	{
		& $Warn 'Resources/Icon128.png is missing, so the plugin shows a blank icon in the Plugins window.'
	}

	# Files -----------------------------------------------------------------------------------

	foreach ($File in $Files)
	{
		$Name = [IO.Path]::GetFileName($File)
		$Extension = [IO.Path]::GetExtension($File).ToLowerInvariant()
		$IsThirdParty = $File -match '(^|/)ThirdParty/'

		if (@('.exe', '.msi', '.dmg', '.pkg', '.zip', '.rar', '.7z', '.tar', '.gz') -contains $Extension)
		{
			& $Fail "Executables, installers and nested archives are not accepted in a Fab code plugin." $File
		}
		elseif (@('.bat', '.cmd', '.ps1', '.sh', '.command') -contains $Extension)
		{
			& $Warn "Scripts get extra scrutiny in review. Make sure this one is needed by buyers." $File
		}

		if (-not $IsThirdParty -and $Name -match '^(LICEN[CS]E|EULA|COPYING)(\..*)?$')
		{
			& $Fail "License and EULA files are not allowed outside ThirdParty folders; the license is the one chosen on the Fab listing." $File
		}

		if ($File.Length -gt 170)
		{
			& $Warn "Path is $($File.Length) characters. Installed under Engine/Plugins/Marketplace this risks the Windows 260 character limit." $File
		}
	}

	# Copyright notices -----------------------------------------------------------------------

	if (-not $CopyrightHolder) { $CopyrightHolder = Get-JsonValue $Json 'CreatedBy' }
	$ExampleNotice = "// Copyright $((Get-Date).Year) $CopyrightHolder. All Rights Reserved."

	foreach ($File in $Files)
	{
		if ($File -notmatch '^Source/.*\.(h|hpp|inl|c|cpp|cs)$') { continue }
		if ($File -match '(^|/)ThirdParty/') { continue }

		$FirstLine = ''
		$Reader = New-Object IO.StreamReader (Join-Paths $Descriptor.Dir $File), $true
		try { $FirstLine = $Reader.ReadLine() } finally { $Reader.Dispose() }
		if ($null -eq $FirstLine) { $FirstLine = '' }

		if ($FirstLine -notmatch '^\s*//.*\bCopyright\b')
		{
			& $Fail "The first line must be a copyright notice, e.g. '$ExampleNotice'" $File 1
		}
		elseif ($CopyrightHolder -and $FirstLine.IndexOf($CopyrightHolder, [StringComparison]::OrdinalIgnoreCase) -lt 0)
		{
			& $Fail "The copyright notice should name '$CopyrightHolder' (the descriptor's CreatedBy). Epic's own notice left in from a template is a common reason to be declined." $File 1
		}
		elseif ($FirstLine -notmatch '\b(19|20)\d\d\b')
		{
			# Fab's technical review fails a code file whose notice has no year of publishing.
			& $Fail "The copyright notice needs the year of publishing, e.g. '$ExampleNotice'. Fab declines code files without it." $File 1
		}
	}

	return [pscustomobject]$State
}

#endregion

#region Engine versions and badges

<#
.SYNOPSIS
Engine versions as given to the actions, '5.7,5.8' or a JSON array, as a checked list.
#>
function ConvertFrom-EngineVersions
{
	param([Parameter(Mandatory)][string]$EngineVersions)

	if ($EngineVersions.TrimStart().StartsWith('['))
	{
		# Windows PowerShell hands back a JSON array as one object; foreach unwraps it.
		$Engines = @()
		foreach ($Engine in ($EngineVersions | ConvertFrom-Json)) { $Engines += [string]$Engine }
	}
	else
	{
		$Engines = @($EngineVersions.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	}
	if ($Engines.Count -eq 0) { throw 'No engine versions given.' }
	foreach ($Engine in $Engines)
	{
		if ($Engine -notmatch '^\d+\.\d+$') { throw "Engine version '$Engine' should look like 5.8." }
	}
	return ,[string[]]$Engines
}

<#
.SYNOPSIS
The plugin's own lines of code: non-blank lines of its C++ and C# sources, ThirdParty left out.
#>
function Measure-PluginSource
{
	param([Parameter(Mandatory)]$Descriptor)

	$Count = 0
	foreach ($File in (Get-PluginPackageFiles $Descriptor))
	{
		if ($File -notmatch '^Source/.*\.(h|hpp|inl|c|cpp|cs)$' -or $File -match '(^|/)ThirdParty/') { continue }
		foreach ($Line in [IO.File]::ReadAllLines((Join-Paths $Descriptor.Dir $File)))
		{
			if ($Line.Trim()) { $Count++ }
		}
	}
	return $Count
}

<#
.SYNOPSIS
A shields.io endpoint badge as JSON; see https://shields.io/badges/endpoint-badge.
#>
function New-Badge
{
	param(
		[Parameter(Mandatory)][string]$Label,
		[Parameter(Mandatory)][string]$Message,
		[Parameter(Mandatory)][string]$Color,
		[string]$Logo
	)

	$Badge = [ordered]@{ schemaVersion = 1; label = $Label; message = $Message; color = $Color }
	if ($Logo) { $Badge['namedLogo'] = $Logo }
	return ([pscustomobject]$Badge | ConvertTo-Json -Compress)
}

<#
.SYNOPSIS
The three badges a plugin repository shows: tests, supported engines and lines of code.
.PARAMETER Results
The test-results.json of each engine version that got as far as its tests.
#>
function Get-PluginBadges
{
	param(
		[Parameter(Mandatory)][string[]]$Engines,
		[object[]]$Results = @(),
		[Parameter(Mandatory)][int]$Lines
	)

	$Ran = @{}
	foreach ($Result in $Results)
	{
		if ([int]$Result.total -gt 0) { $Ran[[string]$Result.engine] = $Result }
	}
	$Missing = @($Engines | Where-Object { -not $Ran.ContainsKey($_) })
	$Failing = @($Engines | Where-Object { $Ran.ContainsKey($_) -and [int]$Ran[$_].failed -gt 0 })
	$MostPassed = 0
	foreach ($Result in $Ran.Values) { $MostPassed = [math]::Max($MostPassed, [int]$Result.passed) }

	# The same tests run on every engine, so a count is per engine, not a sum across them.
	if ($Failing.Count -gt 0)
	{
		$Failed = 0
		foreach ($Engine in $Failing) { $Failed = [math]::Max($Failed, [int]$Ran[$Engine].failed) }
		$Tests = New-Badge 'tests' "$Failed failed on UE $($Failing -join ', ')" 'red'
	}
	elseif ($Missing.Count -eq $Engines.Count)
	{
		$Tests = New-Badge 'tests' 'not run' 'lightgrey'
	}
	elseif ($Missing.Count -gt 0)
	{
		$Tests = New-Badge 'tests' "$MostPassed passed, not run on UE $($Missing -join ', ')" 'orange'
	}
	else
	{
		$Tests = New-Badge 'tests' "$MostPassed passed" 'brightgreen'
	}

	$Invariant = [Globalization.CultureInfo]::InvariantCulture
	$LinesText = [string]$Lines
	if ($Lines -ge 1000) { $LinesText = [string]::Format($Invariant, '{0:0.#}k', $Lines / 1000.0) }

	return [ordered]@{
		'tests.json' = $Tests
		'unreal.json' = New-Badge 'Unreal Engine' ($Engines -join ' | ') '313131' 'unrealengine'
		'loc.json' = New-Badge 'lines of code' $LinesText 'blue'
	}
}

#endregion

#region Conventional commits, versions and release notes

# The commit types accepted; see https://www.conventionalcommits.org.
$script:CommitTypes = @('feat', 'fix', 'perf', 'refactor', 'docs', 'test', 'ci', 'build', 'chore', 'style', 'revert')
# Housekeeping that changes nothing for someone using the project: left out of release notes.
$script:QuietCommitTypes = @('ci', 'chore', 'test', 'build', 'style')

<#
.SYNOPSIS
Parse a commit message as a conventional commit: "type(scope)!: description".
.OUTPUTS
Type (lowercase), Scope, Breaking and Description; nothing if the message is not one.
#>
function ConvertFrom-ConventionalCommit
{
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

	$Lines = $Message.Replace("`r", '').Split("`n")
	$Match = [regex]::Match($Lines[0].Trim(), '^(?<type>[A-Za-z]+)(\((?<scope>[^()]+)\))?(?<bang>!)?: (?<text>\S.*)$')
	if (-not $Match.Success) { return $null }

	# The footer token is case sensitive in the specification.
	$Body = ($Lines | Select-Object -Skip 1) -join "`n"
	$Breaking = $Match.Groups['bang'].Success -or [regex]::IsMatch($Body, '(?m)^BREAKING[ -]CHANGE: ')

	return [pscustomobject]@{
		Type = $Match.Groups['type'].Value.ToLowerInvariant()
		Scope = $Match.Groups['scope'].Value
		Breaking = [bool]$Breaking
		Description = $Match.Groups['text'].Value.Trim()
	}
}

<#
.SYNOPSIS
The commits in a range, oldest first and without merge commits, as Hash, Subject and Message.
#>
function Get-Commits
{
	param(
		[Parameter(Mandatory)][string]$RepoDir,
		[Parameter(Mandatory)][string]$Range
	)

	# Unit and record separators keep multi-line messages apart.
	$Result = Invoke-NativeQuiet git @('-C', $RepoDir, 'log', '--no-merges', '--reverse', '--format=%h%x1f%B%x1e', $Range)
	if ($Result.ExitCode -ne 0) { throw "git log $Range failed in $RepoDir." }

	$Commits = @()
	foreach ($Record in ($Result.Output -join "`n").Split([char]0x1e))
	{
		$Record = $Record.Trim()
		if (-not $Record) { continue }
		$Parts = $Record.Split([char]0x1f)
		$Message = ($Parts[1..($Parts.Count - 1)] -join '').Trim()
		$Commits += [pscustomobject]@{
			Hash = $Parts[0].Trim()
			Subject = $Message.Replace("`r", '').Split("`n")[0]
			Message = $Message
		}
	}
	return ,$Commits
}

<#
.SYNOPSIS
The most recent vX.Y.Z tag reachable from a commit, prereleases left out. Nothing if none.
#>
function Get-PreviousReleaseTag
{
	param(
		[Parameter(Mandatory)][string]$RepoDir,
		[Parameter(Mandatory)][string]$Ref
	)

	$Result = Invoke-NativeQuiet git @('-C', $RepoDir, 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*.[0-9]*.[0-9]*', '--exclude', '*-*', $Ref)
	if ($Result.ExitCode -ne 0) { return $null }
	return ($Result.Output | Select-Object -First 1)
}

<#
.SYNOPSIS
The next release version from the conventional commits since the last vX.Y.Z tag.

.DESCRIPTION
feat bumps the minor version; fix, perf and revert the patch; a breaking change (an exclamation
mark before the colon, or a BREAKING CHANGE footer) the major, or the minor while the version is
still 0.x, as semver allows during initial development. Commits of any other type, or not
conventional at all, make no release on their own.

.OUTPUTS
Previous (the last tag, or nothing), Version (without the v; empty when there is nothing to
release), Bump (major, minor, patch or none) and Commits.
#>
function Get-NextVersion
{
	param(
		[Parameter(Mandatory)][string]$RepoDir,
		[string]$Ref = 'HEAD'
	)

	$Previous = Get-PreviousReleaseTag $RepoDir $Ref
	$Range = $Ref
	if ($Previous) { $Range = "$Previous..$Ref" }
	$Commits = Get-Commits $RepoDir $Range

	$Rank = 0
	foreach ($Commit in $Commits)
	{
		$Parsed = ConvertFrom-ConventionalCommit $Commit.Message
		if (-not $Parsed) { continue }
		$Level = 0
		if ($Parsed.Breaking) { $Level = 3 }
		elseif ($Parsed.Type -eq 'feat') { $Level = 2 }
		elseif (@('fix', 'perf', 'revert') -contains $Parsed.Type) { $Level = 1 }
		$Rank = [math]::Max($Rank, $Level)
	}

	$Major = 0; $Minor = 0; $Patch = 0
	if ($Previous)
	{
		$Match = [regex]::Match($Previous, '^v(\d+)\.(\d+)\.(\d+)')
		$Major = [int]$Match.Groups[1].Value; $Minor = [int]$Match.Groups[2].Value; $Patch = [int]$Match.Groups[3].Value
	}
	if ($Rank -eq 3 -and $Major -eq 0) { $Rank = 2 }

	switch ($Rank)
	{
		3 { $Major++; $Minor = 0; $Patch = 0 }
		2 { $Minor++; $Patch = 0 }
		1 { $Patch++ }
	}

	$Version = ''
	if ($Rank -gt 0) { $Version = "$Major.$Minor.$Patch" }
	return [pscustomobject]@{
		Previous = $Previous
		Version = $Version
		Bump = @('none', 'patch', 'minor', 'major')[$Rank]
		Commits = $Commits
	}
}

<#
.SYNOPSIS
Report every commit in a range whose message is not a conventional commit of a known type.
.OUTPUTS
How many were reported.
#>
function Test-ConventionalCommits
{
	param(
		[Parameter(Mandatory)][string]$RepoDir,
		[Parameter(Mandatory)][string]$Range
	)

	$Bad = 0
	foreach ($Commit in (Get-Commits $RepoDir $Range))
	{
		# What git revert writes is accepted as it is.
		if ($Commit.Subject.StartsWith('Revert "')) { continue }

		$Parsed = ConvertFrom-ConventionalCommit $Commit.Message
		if (-not $Parsed)
		{
			$Problem = 'is not in the form "type: description" or "type(scope): description"'
		}
		elseif ($script:CommitTypes -notcontains $Parsed.Type)
		{
			$Problem = "has type '$($Parsed.Type)', which is not one of $($script:CommitTypes -join ', ')"
		}
		else
		{
			Write-Host "  ok  $($Commit.Hash) $($Commit.Subject)"
			continue
		}

		$Bad++
		Write-CiAnnotation error "Commit $($Commit.Hash) '$($Commit.Subject)' $Problem. Versions and release notes are worked out from commit messages; reword it, for example 'fix: crash when saving' or 'feat(ui): outline panel'." -Title 'Commit message'
	}
	return $Bad
}

<#
.SYNOPSIS
Release notes for a commit: the conventional commits since the release tag before it.

.DESCRIPTION
Breaking changes, features and fixes get their own sections. ci, chore, test, build and style
commits are left out, since they change nothing for someone using the project. Anything else,
including messages not in conventional form, is listed under Other changes.
#>
function Get-ReleaseNotes
{
	param(
		[Parameter(Mandatory)][string]$RepoDir,
		# The commit being released, or its tag.
		[Parameter(Mandatory)][Alias('Tag')][string]$Ref
	)

	$Previous = Get-PreviousReleaseTag $RepoDir "$Ref^"
	$Range = $Ref
	if ($Previous) { $Range = "$Previous..$Ref" }

	$Sections = [ordered]@{ 'Breaking changes' = @(); 'Features' = @(); 'Fixes' = @(); 'Other changes' = @() }
	foreach ($Commit in (Get-Commits $RepoDir $Range))
	{
		$Parsed = ConvertFrom-ConventionalCommit $Commit.Message
		if (-not $Parsed)
		{
			$Sections['Other changes'] += "- $($Commit.Subject) ($($Commit.Hash))"
			continue
		}

		$Entry = "- $($Parsed.Description) ($($Commit.Hash))"
		if ($Parsed.Breaking) { $Sections['Breaking changes'] += $Entry }
		elseif ($Parsed.Type -eq 'feat') { $Sections['Features'] += $Entry }
		elseif (@('fix', 'perf') -contains $Parsed.Type) { $Sections['Fixes'] += $Entry }
		elseif ($script:QuietCommitTypes -notcontains $Parsed.Type) { $Sections['Other changes'] += $Entry }
	}

	$Notes = @()
	foreach ($Section in $Sections.Keys)
	{
		if ($Sections[$Section].Count -eq 0) { continue }
		$Notes += "### $Section"
		$Notes += $Sections[$Section]
		$Notes += ''
	}
	if ($Notes.Count -eq 0) { $Notes = @('Maintenance release.', '') }
	return ($Notes -join "`n").Trim()
}

#endregion

#region Docs bundles

# A product's docs on docs.khaos.systems are a bundle: its docs folder plus a docs.json manifest. A
# release attaches the bundle as a zip, then pushes it to KhaosSystems/docs-content at
# <section>/<slug>/<version>/, which the site is built from. That repository's README is the
# contract these functions follow. The site checks the same Markdown rules again when it builds.

# A plugin's docs live in Docs, beside its .uplugin: Khaos Docs shows that folder in the editor's
# documentation window. They used to live in Content/Docs, which is no longer read.
$script:DocsBase = 'Docs'
$script:OldDocsBase = 'Content/Docs'
$script:DocsSections = @('unreal')
# Pages end in .md, in that case: the site's build matches it exactly. Image types are matched in
# any case, as the site does.
$script:DocsImageTypes = @('.png', '.jpg', '.jpeg', '.webp', '.gif', '.svg')
# Text files, written with LF line endings as docs-content stores them.
$script:DocsTextTypes = @('.md', '.svg')
# Decimal megabytes, the stricter reading of the contract's 5 MB and 25 MB.
$script:DocsMaxImageBytes = 5000000
$script:DocsMaxBundleBytes = 25000000
$script:DocsRequiredKeys = @('schema', 'section', 'slug', 'name', 'description', 'landing', 'version', 'preview', 'released', 'repo', 'private', 'ref', 'commit', 'base')
# docs.json values as the site's JavaScript checks them: its \d and \w are ASCII, and its $ is the
# end of the text, which .NET writes \z.
$script:DocsDatePattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}\z'
$script:DocsCommitPattern = '^[0-9a-f]{40}\z'
$script:DocsRepoPattern = '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z'
$script:DocsSlugPattern = '^[a-z0-9]+(-[a-z0-9]+)*\z'
# supportUrl and fabUrl: the site takes an http(s) URL or null.
$script:DocsUrlPattern = '^https?://\S+\z'
# First parts of a page's URL the site keeps for versions: /v1.2.0/, /preview/, /releases/.
$script:DocsReservedSegment = '^(v[0-9].*|preview|releases)\z'

# Raw HTML as CommonMark reads it: tags and the block starts that need no closing tag.
$script:HtmlOpenTag = '<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s"''=<>`]+))?)*\s*/?>'
$script:HtmlClosingTag = '</[A-Za-z][A-Za-z0-9-]*\s*>'
$script:HtmlBlockTags = 'address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul'
# Inline: an element, a comment, an instruction, a declaration or CDATA, each closed.
$script:InlineHtmlPattern = New-Object regex ('\G(?:' + $script:HtmlOpenTag + '|' + $script:HtmlClosingTag + '|<!--(?:-?>|[\s\S]*?-->)|<\?[\s\S]*?\?>|<![A-Za-z][^>]*>|<!\[CDATA\[[\s\S]*?\]\]>)')
$script:AutolinkPattern = New-Object regex '\G<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\x00-\x20]*)>'
# [label]: destination "title", which may run over a line break before the destination and one
# before the title. Nothing may follow on the line; a title that is not alone ends the definition
# at the destination.
$script:DefinitionPattern = New-Object regex '\A\[((?:[^\[\]\\]|\\[\s\S]){1,999})\]:[ \t]*\n?[ \t]*(?:<((?:[^<>\n\\]|\\.)*)>|(?!<)([^\x00-\x20]+))(?:(?:[ \t]+|[ \t]*\n[ \t]*)("(?:[^"\\]|\\[\s\S])*"|''(?:[^''\\]|\\[\s\S])*''|\((?:[^()\\]|\\[\s\S])*\)))?[ \t]*(?=\n|\z)'

<# KhaosFolderIcons -> khaos-folder-icons, UIWidgets -> ui-widgets, as the docs site does it. #>
function ConvertTo-KebabCase([string]$Name)
{
	$Text = [regex]::Replace($Name, '([a-z0-9])([A-Z])', '$1-$2')
	$Text = [regex]::Replace($Text, '([A-Z]+)([A-Z][a-z])', '$1-$2')
	$Text = [regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]+', '-')
	return $Text.Trim('-')
}

<#
.SYNOPSIS
The two letters a docs card shows: from the name's words, without a first word it shares with the
maker. 'Khaos Palette' by Khaos Systems is PA, 'Khaos Folder Icons' FI. Digits are skipped, as the
site takes letters only: 'Khaos 3D Tools' is DT. Nothing when fewer than two letters are left.
#>
function Get-DocsGlyph([string]$Name, [string]$Maker)
{
	$Words = @((ConvertTo-KebabCase $Name).Split('-') | Where-Object { $_ })
	$MakerWord = @((ConvertTo-KebabCase $Maker).Split('-') | Where-Object { $_ })[0]
	if ($Words.Count -gt 1 -and $MakerWord -and $Words[0] -eq $MakerWord) { $Words = @($Words | Select-Object -Skip 1) }
	$Words = @($Words | ForEach-Object { $_ -replace '[0-9]', '' } | Where-Object { $_ })
	if ($Words.Count -gt 1) { $Glyph = $Words[0].Substring(0, 1) + $Words[1].Substring(0, 1) }
	elseif ($Words.Count -eq 1 -and $Words[0].Length -ge 2) { $Glyph = $Words[0].Substring(0, 2) }
	else { return $null }
	return $Glyph.ToUpperInvariant()
}

function ConvertTo-JsonString([string]$Text)
{
	$Builder = New-Object System.Text.StringBuilder
	[void]$Builder.Append('"')
	foreach ($Char in $Text.ToCharArray())
	{
		$Code = [int]$Char
		if ($Code -eq 0x22) { [void]$Builder.Append('\"') }
		elseif ($Code -eq 0x5C) { [void]$Builder.Append('\\') }
		elseif ($Code -eq 0x0A) { [void]$Builder.Append('\n') }
		elseif ($Code -eq 0x0D) { [void]$Builder.Append('\r') }
		elseif ($Code -eq 0x09) { [void]$Builder.Append('\t') }
		elseif ($Code -lt 0x20) { [void]$Builder.Append('\u' + $Code.ToString('x4')) }
		else { [void]$Builder.Append($Char) }
	}
	[void]$Builder.Append('"')
	return $Builder.ToString()
}

<#
.SYNOPSIS
JSON with every object's keys in ordinal order and two-space indents, as JSON.stringify(value,
null, 2) writes it. ConvertTo-Json in 5.1 neither sorts nor indents readably, and escapes
apostrophes.
#>
function ConvertTo-SortedJson
{
	param([AllowNull()]$Value, [string]$Indent = '')

	if ($null -eq $Value) { return 'null' }
	if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
	if ($Value -is [string]) { return ConvertTo-JsonString $Value }
	if ($Value -is [int] -or $Value -is [long]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }

	$Inner = $Indent + '  '
	if ($Value -is [System.Collections.IDictionary])
	{
		$Keys = @($Value.Keys | ForEach-Object { [string]$_ })
		if ($Keys.Count -eq 0) { return '{}' }
		[Array]::Sort($Keys, [StringComparer]::Ordinal)
		$Members = @(foreach ($Key in $Keys) { $Inner + (ConvertTo-JsonString $Key) + ': ' + (ConvertTo-SortedJson $Value[$Key] $Inner) })
		return "{`n" + ($Members -join ",`n") + "`n$Indent}"
	}
	if ($Value -is [System.Collections.IEnumerable])
	{
		$Items = @(foreach ($Item in $Value) { $Inner + (ConvertTo-SortedJson $Item $Inner) })
		if ($Items.Count -eq 0) { return '[]' }
		return "[`n" + ($Items -join ",`n") + "`n$Indent]"
	}
	throw "Cannot write a $($Value.GetType().Name) as JSON."
}

<# Whether bytes start with a UTF-16 byte order mark. #>
function Test-Utf16Bom([byte[]]$Bytes)
{
	return ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF)))
}

<# A page saved as UTF-16, as Windows PowerShell's > and Out-File write it, as UTF-8. Other bytes come back unchanged. #>
function ConvertFrom-Utf16Bytes([byte[]]$Bytes)
{
	if (-not (Test-Utf16Bom $Bytes)) { return ,$Bytes }
	$BigEndian = ($Bytes[0] -eq 0xFE)
	try { $Text = (New-Object System.Text.UnicodeEncoding $BigEndian, $false, $true).GetString($Bytes, 2, $Bytes.Length - 2) }
	catch { return ,$Bytes }
	return ,$script:Utf8NoBom.GetBytes($Text)
}

<#
.SYNOPSIS
Whether two names are the same character for character, as git, Linux and the docs site compare
them. PowerShell's -ceq compares by culture: it skips soft hyphens and takes ss for a German sharp s.
#>
function Test-SameName([string]$A, [string]$B, [switch]$IgnoreCase)
{
	if ($IgnoreCase) { return [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }
	return [string]::Equals($A, $B, [StringComparison]::Ordinal)
}

<# Whether a list holds a name, compared as Test-SameName does. #>
function Test-NameIn([string]$Name, [string[]]$List)
{
	return ([Array]::IndexOf($List, $Name) -ge 0)
}

<#
.SYNOPSIS
A member of a JSON object by its exact name, as JavaScript reads it.
.OUTPUTS
Has, and Value, with an array kept whole. Nothing is read from what is not a JSON object.
#>
function Get-JsonMember($Object, [string]$Name)
{
	$Member = [pscustomobject]@{ Has = $false; Value = $null }
	if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $Member }
	foreach ($Property in $Object.PSObject.Properties)
	{
		if (Test-SameName $Property.Name $Name)
		{
			$Member.Has = $true
			$Member.Value = $Property.Value
			break
		}
	}
	return $Member
}

<# Every file below a folder, as sorted '/'-separated relative paths. #>
function Get-RelativeFiles([string]$Dir)
{
	$Root = (Get-FullPath $Dir).TrimEnd('\', '/')
	$Files = @([IO.Directory]::GetFiles($Root, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Substring($Root.Length + 1).Replace('\', '/') })
	[Array]::Sort($Files, [StringComparer]::Ordinal)
	return ,$Files
}

function Read-DocsManifest([string]$BundleDir)
{
	# .NET reads a relative path from the process's folder, which cd does not change.
	$Path = Join-Paths (Get-FullPath $BundleDir) 'docs.json'
	if (-not (Test-Path -LiteralPath $Path)) { throw "$BundleDir has no docs.json." }
	try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
	catch { throw "docs.json is not valid JSON: $($_.Exception.Message)" }
}

<# A release version as docs.json and the site write it: 1.0.1 or 1.1.0-rc.1, no v. #>
function Test-DocsVersion($Version)
{
	return ($Version -is [string] -and $Version -cmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z')
}

<# Where a bundle goes in docs-content: section/slug/version, section/slug/preview, or section/slug/current for docs with no version. #>
function Get-DocsBundleFolder($Manifest)
{
	$Folder = 'preview'
	if (-not $Manifest.preview)
	{
		$Folder = 'current'
		if ($null -ne $Manifest.version) { $Folder = [string]$Manifest.version }
	}
	return "$($Manifest.section)/$($Manifest.slug)/$Folder"
}

<#
.SYNOPSIS
A page's path below its product on the docs site, worked out as the site does: '' for the landing
page, guides/first-steps/ for Guides/First Steps.md.

.OUTPUTS
Path, and Problem when the site cannot give the page that URL.
#>
function Get-DocsPagePath([string]$File, [string]$Landing)
{
	if (Test-SameName $File $Landing) { return [pscustomobject]@{ Path = ''; Problem = $null } }
	$Segments = @(($File -replace '\.md$', '').Split('/') | ForEach-Object { ConvertTo-KebabCase $_ })
	$Path = ($Segments -join '/') + '/'
	$Problem = $null
	if (@($Segments | Where-Object { -not $_ }).Count -gt 0) { $Problem = 'A part of its path has no letters or digits, so it gives no URL. Rename it.' }
	elseif ($Segments[0] -cmatch $script:DocsReservedSegment) { $Problem = "Its URL would start with /$($Segments[0])/, which the docs site keeps for versions. Rename it." }
	return [pscustomobject]@{ Path = $Path; Problem = $Problem }
}

<#
.SYNOPSIS
Build a plugin's docs bundle: Docs plus docs.json, in <OutDir>/<section>/<slug>/<version>/.

.DESCRIPTION
Pages (.md, in that case) and images keep their paths below Docs. Pages and SVGs get LF line
endings; a page loses any UTF-8 byte order mark, and one saved as UTF-16 becomes UTF-8. An SVG saved
as UTF-16, and anything else, is left out with a warning. The version folder is emptied first, so a
page deleted since the last build disappears, and nothing beside it is touched. docs.json has sorted
keys and no timestamps, so the same input gives the same bytes. An empty Version builds a preview,
in a folder named preview.

name, description, supportUrl and fabUrl come from the .uplugin, the slug from the repository name.
A URL that is not http(s) is left out with a warning, as the site takes no other. So is a
Content/Docs folder beside Docs.

.OUTPUTS
Dir (the version folder), Folder (section/slug/version), Manifest and Files, the bundle's files as
sorted '/'-separated paths.
#>
function New-DocsBundle
{
	param(
		[Parameter(Mandatory)][string]$PluginDir,
		[Parameter(Mandatory)][string]$OutDir,
		# The release version, 1.2.3 or v1.2.3. Empty for a preview.
		[string]$Version,
		# The tag or branch the docs come from.
		[Parameter(Mandatory)][string]$Ref,
		[Parameter(Mandatory)][string]$Commit,
		# The plugin's repository, owner/name.
		[Parameter(Mandatory)][string]$Repo,
		[bool]$Private = $false,
		[string[]]$Engines = @(),
		# YYYY-MM-DD: the day of the release, or of the last docs commit for a preview.
		[Parameter(Mandatory)][string]$Released,
		[string]$Section = 'unreal'
	)

	if ($Repo -cnotmatch $script:DocsRepoPattern) { throw "Repo must be owner/name, not '$Repo'." }
	if ($Commit -cnotmatch $script:DocsCommitPattern) { throw "Commit must be a full 40-character SHA, not '$Commit'." }
	if ($Released -cnotmatch $script:DocsDatePattern) { throw "Released must be YYYY-MM-DD, not '$Released'." }

	$Descriptor = Get-PluginDescriptor $PluginDir
	$Problem = Get-DocsFolderProblem $Descriptor.Dir
	if ($Problem) { throw $Problem }
	$Source = Join-Paths $Descriptor.Dir $script:DocsBase
	if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "$($Descriptor.Name) has no $($script:DocsBase) folder beside its .uplugin." }
	$Old = Find-DocsFolder $Descriptor.Dir $script:OldDocsBase
	if ($Old) { Write-CiAnnotation warning "$Old is no longer read; the docs come from $($script:DocsBase)/. Move anything still needed to $($script:DocsBase)/ and delete $Old." -Title 'Docs' }

	$VersionName = $null
	$Folder = 'preview'
	if ($Version)
	{
		$VersionName = (ConvertFrom-ReleaseVersion $Version).VersionName
		$Folder = $VersionName
	}

	$Json = $Descriptor.Json
	$Name = ([string](Get-JsonValue $Json 'FriendlyName')).Trim()
	if (-not $Name) { $Name = $Descriptor.Name }
	$Slug = ConvertTo-KebabCase $Repo.Split('/')[1]
	$Modules = @(foreach ($Module in @(Get-JsonValue $Json 'Modules' @())) { @{ name = [string](Get-JsonValue $Module 'Name'); type = [string](Get-JsonValue $Module 'Type') } })

	$Manifest = @{
		schema = 1
		section = $Section
		slug = $Slug
		name = $Name
		description = [string](Get-JsonValue $Json 'Description')
		landing = "$($Descriptor.Name).md"
		version = $VersionName
		preview = (-not $VersionName)
		released = $Released
		repo = $Repo
		private = $Private
		ref = $Ref
		commit = $Commit
		base = $script:DocsBase
		unreal = @{ engines = [string[]]@($Engines); modules = $Modules }
		supportUrl = $null
		fabUrl = $null
		glyph = Get-DocsGlyph $Name ([string](Get-JsonValue $Json 'CreatedBy'))
	}
	$Urls = @(
		@{ Key = 'supportUrl'; Field = 'SupportURL' }
		@{ Key = 'fabUrl'; Field = 'FabURL' }
		@{ Key = 'fabUrl'; Field = 'MarketplaceURL' }
	)
	foreach ($Url in $Urls)
	{
		$Value = [string](Get-JsonValue $Json $Url.Field)
		if (-not $Value -or $Manifest[$Url.Key]) { continue }
		if ($Value -cmatch $script:DocsUrlPattern) { $Manifest[$Url.Key] = $Value }
		else { Write-CiAnnotation warning "$($Url.Field) is not an http(s) URL, so the docs site leaves it out: $Value" -File $Descriptor.FileName -Title 'Docs' }
	}

	$Target = Join-Paths (Get-FullPath $OutDir) $Section $Slug $Folder
	Reset-Directory $Target

	# Latin-1 maps each byte to one character and back, so only the line endings change.
	$Latin1 = [Text.Encoding]::GetEncoding(28591)
	$Files = New-Object System.Collections.Generic.List[string]
	foreach ($Relative in (Get-RelativeFiles $Source))
	{
		if ($script:ExcludedFiles -contains [IO.Path]::GetFileName($Relative)) { continue }

		$Extension = [IO.Path]::GetExtension($Relative)
		$IsPage = Test-SameName $Extension '.md'
		$Shown = "$($script:DocsBase)/$Relative"
		if (-not $IsPage -and -not (Test-NameIn $Extension.ToLowerInvariant() $script:DocsImageTypes))
		{
			$Hint = ''
			if (Test-SameName $Extension '.md' -IgnoreCase) { $Hint = ' Rename it to end in .md, in lowercase.' }
			if (Test-SameName $Extension '.txt' -IgnoreCase) { $Hint = ' KhaosDocs shows .txt files in the editor, but the site does not; rename it to .md to publish it.' }
			Write-CiAnnotation warning "Left out of the docs: the docs site takes only .md pages and .png, .jpg, .jpeg, .webp, .gif and .svg images.$Hint" -File $Shown -Title 'Docs'
			continue
		}

		$From = Join-Paths $Source $Relative
		$To = Join-Paths $Target $Relative
		if (Test-NameIn $Extension.ToLowerInvariant() $script:DocsTextTypes)
		{
			$Bytes = [IO.File]::ReadAllBytes($From)
			if ($IsPage) { $Bytes = ConvertFrom-Utf16Bytes $Bytes }
			elseif (Test-Utf16Bom $Bytes)
			{
				# Converting it is not enough: its XML declaration says UTF-16.
				Write-CiAnnotation warning 'Left out of the docs: the SVG is saved as UTF-16, which the docs site cannot read. Save it as UTF-8.' -File $Shown -Title 'Docs'
				continue
			}
			$Text = $Latin1.GetString($Bytes).Replace("`r`n", "`n").Replace("`r", "`n")
			# A page's UTF-8 byte order mark, which Windows editors add, would sit before its H1.
			if ($IsPage -and $Text.StartsWith($Latin1.GetString([byte[]](0xEF, 0xBB, 0xBF)))) { $Text = $Text.Substring(3) }
			New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($To)) -Force | Out-Null
			[IO.File]::WriteAllBytes($To, $Latin1.GetBytes($Text))
		}
		else
		{
			New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($To)) -Force | Out-Null
			[IO.File]::Copy($From, $To, $true)
		}
		$Files.Add($Relative)
	}

	Write-Utf8File (Join-Paths $Target 'docs.json') ((ConvertTo-SortedJson $Manifest) + "`n")
	$Files.Add('docs.json')
	$Sorted = $Files.ToArray()
	[Array]::Sort($Sorted, [StringComparer]::Ordinal)

	return [pscustomobject]@{
		Dir = $Target
		Folder = "$Section/$Slug/$Folder"
		Manifest = $Manifest
		Files = $Sorted
	}
}

<#
.SYNOPSIS
Zip a release's docs bundle as <Repo>-<version>-docs.zip, with a .sha256 beside it.

.DESCRIPTION
Entries sit at <section>/<slug>/<version>/, so unzipping release zips at the root of a docs-content
checkout puts each bundle back where it belongs. Same bundle, same bytes, as for the source zips.

.OUTPUTS
The zip's path.
#>
function New-DocsBundleZip
{
	param(
		[Parameter(Mandatory)][string]$BundleDir,
		[Parameter(Mandatory)][string]$OutDir
	)

	$BundleDir = Get-FullPath $BundleDir
	$Manifest = Read-DocsManifest $BundleDir
	if ($Manifest.preview) { throw 'A preview bundle has no release to attach to.' }

	$ZipName = "$(([string]$Manifest.repo).Split('/')[1])-$($Manifest.version)-docs.zip"
	New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
	$ZipPath = Join-Paths (Get-FullPath $OutDir) $ZipName
	New-PluginZip -SourceDir $BundleDir -Files (Get-RelativeFiles $BundleDir) -RootFolder (Get-DocsBundleFolder $Manifest) -ZipPath $ZipPath
	Write-Utf8File "$ZipPath.sha256" "$(Get-FileSha256 $ZipPath)  $ZipName`n"
	return $ZipPath
}

<# The release notes' section on a docs zip. #>
function Get-DocsReleaseNote([string]$DocsZip)
{
	return "### Docs`n`n``$([IO.Path]::GetFileName($DocsZip))``: this version's docs bundle for docs.khaos.systems, not a Fab package. SHA-256 ``$(Get-FileSha256 $DocsZip)``."
}

<#
.SYNOPSIS
Release notes with their docs section replaced by Note, or Note added at the end if they have none.
#>
function Set-DocsReleaseNote([string]$Body, [string]$Note)
{
	$Body = $Body.Replace("`r`n", "`n")
	$Section = [regex]::Match($Body, '(?m)^### Docs[ \t]*$')
	if (-not $Section.Success) { return "$($Body.TrimEnd())`n`n$Note" }
	$After = $Body.Substring($Section.Index + $Section.Length)
	$Next = [regex]::Match($After, '(?m)^#{1,6} ')
	$Tail = ''
	if ($Next.Success) { $Tail = "`n`n" + $After.Substring($Next.Index) }
	return $Body.Substring(0, $Section.Index) + $Note + $Tail
}

<#
.SYNOPSIS
Resolve a relative path against a folder, both '/'-separated.
.OUTPUTS
Path, normalized, and Up: how many levels it climbs above the folder's root, 0 when it stays inside.
#>
function Resolve-DocsPath([string]$Dir, [string]$Target)
{
	$Parts = New-Object System.Collections.Generic.List[string]
	$Up = 0
	foreach ($Segment in "$Dir/$Target".Split('/'))
	{
		if (-not $Segment -or $Segment -eq '.') { continue }
		if ($Segment -eq '..')
		{
			if ($Parts.Count -gt 0) { $Parts.RemoveAt($Parts.Count - 1) } else { $Up++ }
			continue
		}
		$Parts.Add($Segment)
	}
	return [pscustomobject]@{ Path = ($Parts -join '/'); Up = $Up }
}

<# A '/'-separated path below a folder, spelled as it is on disk, or nothing if there is none. #>
function Find-DocsFile([string]$Root, [string]$Path)
{
	$Dir = $Root
	$Found = @()
	foreach ($Part in $Path.Split('/'))
	{
		if (-not [IO.Directory]::Exists($Dir)) { return $null }
		$Names = @([IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [IO.Path]::GetFileName($_) })
		$Name = @($Names | Where-Object { Test-SameName $_ $Part })[0]
		if (-not $Name) { $Name = @($Names | Where-Object { Test-SameName $_ $Part -IgnoreCase })[0] }
		if (-not $Name) { return $null }
		$Found += $Name
		$Dir = Join-Paths $Dir $Name
	}
	return ($Found -join '/')
}

<# A '/'-separated folder below a plugin, spelled as it is on disk, or nothing if there is no such folder. #>
function Find-DocsFolder([string]$PluginDir, [string]$Path)
{
	$Found = Find-DocsFile $PluginDir $Path
	if ($Found -and [IO.Directory]::Exists((Join-Paths $PluginDir $Found))) { return $Found }
	return $null
}

<#
.SYNOPSIS
What stops a plugin's docs being read, or nothing.

.DESCRIPTION
Docs spelled in another case on disk, such as docs: Windows finds it, GitHub and git log do not. Or
no Docs, but docs left in Content/Docs, which is no longer read.
#>
function Get-DocsFolderProblem([string]$PluginDir)
{
	$Found = Find-DocsFolder $PluginDir $script:DocsBase
	if ($Found)
	{
		if (Test-SameName $Found $script:DocsBase) { return $null }
		return "The docs folder is $Found. Rename it to $($script:DocsBase): Windows does not mind the case, but GitHub and the docs site do."
	}
	$Old = Find-DocsFolder $PluginDir $script:OldDocsBase
	if ($Old) { return "The docs are in $Old, which is no longer read. Move $Old to $($script:DocsBase)/ beside the .uplugin, and add /$($script:DocsBase)/... to Config/FilterPlugin.ini." }
	return $null
}

# Windows ignores case in file names; GitHub, the Linux build of the site and its URLs do not.
function Get-DocsFileProblem([string]$BundleDir, [string]$Path, [string]$Url, [string]$What)
{
	$Actual = Find-DocsFile $BundleDir $Path
	# A folder is no file, whatever its name.
	if (-not $Actual -or -not [IO.File]::Exists((Join-Paths $BundleDir $Actual))) { return "$What $Url is broken: there is no $Path in the docs." }
	if (-not (Test-SameName $Actual $Path)) { return "$What $Url has the wrong case: the file is $Actual. Windows does not mind; GitHub and the docs site do." }
	return $null
}

<#
.SYNOPSIS
What is wrong with one link or image on a page of a docs bundle, or nothing.

.DESCRIPTION
Contract rules 4 to 7: links to pages and all images must resolve in the bundle with exact case,
images must be local, links to other repository files work only for a public repository, and only
http(s), mailto and #anchor links leave the page. Root-relative links are an error.
#>
function Get-DocsLinkProblem
{
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$Url,
		[bool]$Image,
		# The page's folder in the bundle, '/'-separated; empty at its root.
		[AllowEmptyString()][string]$Dir,
		[Parameter(Mandatory)][string]$BundleDir,
		[Parameter(Mandatory)]$Manifest
	)

	$Url = $Url.Trim()
	$HasScheme = $Url -match '^[A-Za-z][A-Za-z0-9+.-]*:'
	if ($Image)
	{
		if (-not $Url) { return 'An image needs the path of a file in the docs folder.' }
		if ($HasScheme) { return "Image $Url is remote, and the docs site loads no remote images. Put the file in the docs folder and give its path relative to this page." }
		if ($Url.StartsWith('/')) { return "Image $Url is root-relative. Write it relative to this page." }
		$Path = ConvertFrom-UrlEscapes ($Url -split '[?#]', 2)[0]
		if ($null -eq $Path) { return "Image $Url is not a valid link: each % must start a UTF-8 escape, such as %20. Write a plain % as %25." }
		$Resolved = Resolve-DocsPath $Dir $Path
		if ($Resolved.Up -gt 0 -or -not $Resolved.Path) { return "Image $Url is outside the docs folder ($($Manifest.base)). Move it in." }
		return Get-DocsFileProblem $BundleDir $Resolved.Path $Url 'Image'
	}

	if (-not $Url) { return 'Link with no target.' }
	if ($Url.StartsWith('#') -or $Url -match '^(https?|mailto):') { return $null }
	if ($HasScheme) { return "Link ${Url}: only http(s), mailto, #anchor and relative links are allowed." }
	if ($Url.StartsWith('/')) { return "Link $Url is root-relative. Write it relative to this page, as in the repository." }

	$Target = ConvertFrom-UrlEscapes ($Url -split '#', 2)[0]
	if ($null -eq $Target) { return "Link $Url is not a valid link: each % must start a UTF-8 escape, such as %20. Write a plain % as %25." }
	$Resolved = Resolve-DocsPath $Dir $Target
	if ($Resolved.Up -eq 0 -and $Resolved.Path -match '\.md\z')
	{
		return Get-DocsFileProblem $BundleDir $Resolved.Path $Url 'Link'
	}

	# Any other file is linked on GitHub, at the release's tag.
	if ($Manifest.private)
	{
		return "Link $Url goes to a file that is not a docs page. $($Manifest.repo) is private, so the docs site cannot link to it on GitHub. Link a page, or drop the link."
	}
	if ((Resolve-DocsPath "$($Manifest.base)/$Dir" $Target).Up -gt 0)
	{
		return "Link $Url points outside the repository."
	}
	return $null
}

<# Columns of indentation before a line's text, a tab reaching the next multiple of four. #>
function Get-MarkdownIndent([string]$Line)
{
	$Column = 0
	foreach ($Char in $Line.ToCharArray())
	{
		if ($Char -eq ' ') { $Column++ }
		elseif ($Char -eq "`t") { $Column += 4 - ($Column % 4) }
		else { break }
	}
	return $Column
}

<# A line with each tab turned into the spaces up to the next multiple of four columns. #>
function Expand-MarkdownTabs([string]$Line)
{
	if ($Line.IndexOf([char]9) -lt 0) { return $Line }
	$Builder = New-Object System.Text.StringBuilder
	foreach ($Char in $Line.ToCharArray())
	{
		if ($Char -eq [char]9) { [void]$Builder.Append(' ', 4 - ($Builder.Length % 4)) }
		else { [void]$Builder.Append($Char) }
	}
	return $Builder.ToString()
}

function Format-ReferenceLabel([string]$Label)
{
	return [regex]::Replace($Label.Trim(), '\s+', ' ').ToLowerInvariant()
}

<# A link destination as CommonMark reads it: backslash escapes removed and entities such as &#46; decoded, in one pass. #>
function ConvertFrom-MarkdownDestination([string]$Text)
{
	$Evaluator = [Text.RegularExpressions.MatchEvaluator]{
		param($Match)
		if ($Match.Groups[1].Success) { return $Match.Groups[1].Value }
		return [System.Net.WebUtility]::HtmlDecode($Match.Value)
	}
	return [regex]::Replace($Text, '\\([!-/:-@\[-`{-~])|&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});', $Evaluator)
}

<#
.SYNOPSIS
A link target with its %-escapes decoded, as the site's decodeURIComponent does it, or nothing when
a % starts no escape or the bytes are not UTF-8.
#>
function ConvertFrom-UrlEscapes([string]$Text)
{
	if ($Text.IndexOf('%') -lt 0) { return $Text }
	if ($Text -match '%(?![0-9A-Fa-f]{2})') { return $null }
	$Strict = New-Object System.Text.UTF8Encoding $false, $true
	$Evaluator = [Text.RegularExpressions.MatchEvaluator]{
		param($Match)
		$Bytes = [byte[]]@($Match.Value.Substring(1).Split('%') | ForEach-Object { [Convert]::ToByte($_, 16) })
		return $Strict.GetString($Bytes)
	}
	try { return [regex]::Replace($Text, '(?:%[0-9A-Fa-f]{2})+', $Evaluator) }
	catch { return $null }
}

<#
.SYNOPSIS
The text a heading shows, roughly as the site reads it: links give their text, images their alt
text. Enough to tell an empty heading, such as "# [](Page.md)", from one with a title.
#>
function Get-MarkdownHeadingText([string]$Text, [hashtable]$Labels = @{})
{
	# Code spans and escaped characters show as text; mark them so brackets in them pair with nothing.
	$Text = [regex]::Replace($Text, '(?<!`)(`+)(?!`)([\s\S]*?[^`])\1(?!`)', { param($Match) if ($Match.Groups[2].Value.Trim()) { 'x' } else { ' ' } })
	$Text = [regex]::Replace($Text, '\\[!-/:-@\[-`{-~]', 'x')
	$Text = [regex]::Replace($Text, '&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});', { param($Match) if ([System.Net.WebUtility]::HtmlDecode($Match.Value).Trim()) { 'x' } else { ' ' } })
	$Inline = '!?\[([^\[\]]*)\]\((?:[^()]|\([^()]*\))*\)'
	$Reference = { param($Match) if ($Labels.ContainsKey((Format-ReferenceLabel $Match.Groups[2].Value))) { $Match.Groups[1].Value } else { $Match.Value } }
	do
	{
		$Before = $Text
		$Text = [regex]::Replace($Text, $Inline, '$1')
		$Text = [regex]::Replace($Text, '!?\[([^\[\]]*)\]\[([^\[\]]+)\]', $Reference)
		$Text = [regex]::Replace($Text, '!?\[([^\[\]]+)\]\[\]', { param($Match) if ($Labels.ContainsKey((Format-ReferenceLabel $Match.Groups[1].Value))) { $Match.Groups[1].Value } else { $Match.Value } })
	} while ($Text -cne $Before)
	return $Text.Trim()
}

<#
.SYNOPSIS
The links, images and raw HTML in a run of Markdown lines, such as a paragraph.

.DESCRIPTION
Read in one pass from left to right, as CommonMark does: whichever starts first of a code span, raw
HTML or an autolink wins, and all three bind tighter than the brackets of a link. A link's
destination is read where its ] is, so text after it cannot take it apart. A reference image,
![alt][label] with label defined, comes back as an imageref with its label.

.PARAMETER Lines
The lines, each with Line (its number in the file) and Text.

.PARAMETER Labels
The page's defined reference labels, normalized. [text][label] is a link only when label is one.

.OUTPUTS
Kind (link, image, imageref or html), Value and Line.
#>
function Get-DocsInlineItems
{
	param(
		[Parameter(Mandatory)][object[]]$Lines,
		[hashtable]$Labels = @{}
	)

	$Starts = @()
	$Text = ''
	foreach ($Entry in $Lines)
	{
		if ($Starts.Count -gt 0) { $Text += "`n" }
		$Starts += $Text.Length
		$Text += [string]$Entry.Text
	}
	$Length = $Text.Length
	# The text read so far, with code spans, escapes and link targets blanked, keeping every offset,
	# so a look back sees only what is still plain text.
	$Masked = $Text.ToCharArray()
	$Items = New-Object System.Collections.Generic.List[object]
	$Punctuation = '!"#$%&''()*+,-./:;<=>?@[\]^_`{|}~'

	$LineAt = {
		param([int]$Offset)
		$Found = 0
		for ($K = 0; $K -lt $Starts.Count; ++$K) { if ($Starts[$K] -le $Offset) { $Found = $K } }
		return $Lines[$Found].Line
	}
	$Blank = {
		param([int]$From, [int]$To)
		for ($K = $From; $K -lt $To; ++$K) { if ($Masked[$K] -ne "`n") { $Masked[$K] = ' ' } }
	}
	$Add = {
		param([string]$Kind, [string]$Value, [int]$Offset)
		$Items.Add([pscustomobject]@{ Kind = $Kind; Value = $Value; Line = (& $LineAt $Offset) })
	}
	# Whether the backslash at an offset escapes the character after it: ASCII punctuation.
	$Escapes = { param([int]$At) return ($At + 1 -lt $Length -and $Punctuation.IndexOf($Text[$At + 1]) -ge 0) }

	# Brackets waiting for their ], innermost last.
	$Openers = New-Object System.Collections.Generic.List[object]
	$Index = 0
	while ($Index -lt $Length)
	{
		$Char = $Text[$Index]

		# An escaped character is plain text.
		if ($Char -eq '\' -and (& $Escapes $Index))
		{
			$Masked[$Index] = [char]1
			$Masked[$Index + 1] = [char]1
			$Index += 2
			continue
		}

		# A code span: a run of backticks up to the next run of the same length.
		if ($Char -eq '`')
		{
			$Run = 0
			while ($Index + $Run -lt $Length -and $Text[$Index + $Run] -eq '`') { $Run++ }
			$Search = $Index + $Run
			$Close = -1
			while ($Search -lt $Length)
			{
				$Next = $Text.IndexOf([char]'`', $Search)
				if ($Next -lt 0) { break }
				$CloseRun = 0
				while ($Next + $CloseRun -lt $Length -and $Text[$Next + $CloseRun] -eq '`') { $CloseRun++ }
				if ($CloseRun -eq $Run) { $Close = $Next; break }
				$Search = $Next + $CloseRun
			}
			if ($Close -lt 0) { $Index += $Run; continue }
			& $Blank $Index ($Close + $Run)
			$Index = $Close + $Run
			continue
		}

		if ($Char -eq '<')
		{
			# Raw HTML before autolinks, as the site's parser reads <!x@example.com>. An email
			# autolink holds nothing the rules look at, so it is left as text.
			$Match = $script:InlineHtmlPattern.Match($Text, $Index)
			if ($Match.Success) { & $Add 'html' $Match.Value $Index }
			else
			{
				$Match = $script:AutolinkPattern.Match($Text, $Index)
				if ($Match.Success) { & $Add 'link' $Match.Groups[1].Value $Index }
			}
			if (-not $Match.Success) { $Index++; continue }
			& $Blank $Index ($Index + $Match.Length)
			$Index += $Match.Length
			continue
		}

		if ($Char -eq '[')
		{
			$Openers.Add([pscustomobject]@{ At = $Index; Image = ($Index -gt 0 -and $Masked[$Index - 1] -eq '!'); Active = $true })
			$Index++
			continue
		}
		if ($Char -ne ']' -or $Openers.Count -eq 0) { $Index++; continue }

		$Opener = $Openers[$Openers.Count - 1]
		$Openers.RemoveAt($Openers.Count - 1)
		if (-not $Opener.Active) { $Index++; continue }
		$Kind = 'link'
		if ($Opener.Image) { $Kind = 'image' }
		$Next = $Index + 1
		$End = -1

		# Inline: [text](destination "title")
		if ($Next -lt $Length -and $Text[$Next] -eq '(')
		{
			$P = $Next + 1
			while ($P -lt $Length -and [char]::IsWhiteSpace($Text[$P])) { $P++ }
			$From = $P
			$To = $P
			$Ok = $true
			if ($P -lt $Length -and $Text[$P] -eq '<')
			{
				# <destination>: on one line, with < and > only escaped.
				$Ok = $false
				$Q = $P + 1
				while ($Q -lt $Length)
				{
					if ($Text[$Q] -eq '\' -and (& $Escapes $Q)) { $Q += 2; continue }
					if ($Text[$Q] -eq "`n" -or $Text[$Q] -eq '<') { break }
					if ($Text[$Q] -eq '>') { $Ok = $true; break }
					$Q++
				}
				if ($Ok) { $From = $P + 1; $To = $Q; $P = $Q + 1 }
			}
			else
			{
				$Parens = 0
				while ($P -lt $Length)
				{
					if ($Text[$P] -eq '\' -and (& $Escapes $P)) { $P += 2; continue }
					$C = $Text[$P]
					if ([char]::IsWhiteSpace($C)) { break }
					if ($C -eq '(') { $Parens++ }
					elseif ($C -eq ')')
					{
						if ($Parens -eq 0) { break }
						$Parens--
					}
					$P++
				}
				$To = $P
			}
			while ($P -lt $Length -and [char]::IsWhiteSpace($Text[$P])) { $P++ }
			if ($Ok -and $P -lt $Length -and ($Text[$P] -eq '"' -or $Text[$P] -eq "'" -or $Text[$P] -eq '('))
			{
				$Closer = $Text[$P]
				if ($Closer -eq '(') { $Closer = [char]')' }
				$Ok = $false
				$Q = $P + 1
				while ($Q -lt $Length)
				{
					if ($Text[$Q] -eq '\' -and (& $Escapes $Q)) { $Q += 2; continue }
					if ($Text[$Q] -eq $Closer) { $Ok = $true; break }
					$Q++
				}
				$P = $Q + 1
				while ($P -lt $Length -and [char]::IsWhiteSpace($Text[$P])) { $P++ }
			}
			if ($Ok -and $P -lt $Length -and $Text[$P] -eq ')')
			{
				$Destination = ConvertFrom-MarkdownDestination $Text.Substring($From, $To - $From)
				& $Add $Kind $Destination $Opener.At
				& $Blank $Next ($P + 1)
				$End = $P + 1
			}
		}

		# References: [text][label], [label][] and [label].
		if ($End -lt 0)
		{
			$Label = $Text.Substring($Opener.At + 1, $Index - $Opener.At - 1)
			$After = $Next
			if ($Next -lt $Length -and $Text[$Next] -eq '[')
			{
				# The label ends at the first ] that is not escaped, and holds no [.
				$LabelEnd = -1
				$Q = $Next + 1
				while ($Q -lt $Length)
				{
					if ($Text[$Q] -eq '\' -and (& $Escapes $Q)) { $Q += 2; continue }
					if ($Text[$Q] -eq ']') { $LabelEnd = $Q; break }
					if ($Text[$Q] -eq '[') { break }
					$Q++
				}
				if ($LabelEnd -gt $Next + 1) { $Label = $Text.Substring($Next + 1, $LabelEnd - $Next - 1) }
				if ($LabelEnd -gt $Next) { $After = $LabelEnd + 1 }
			}
			if ($Labels.ContainsKey((Format-ReferenceLabel $Label)))
			{
				if ($Opener.Image) { & $Add 'imageref' $Label $Opener.At }
				$End = $After
			}
		}

		if ($End -lt 0) { $Index++; continue }
		# A link inside a link is not one, so a link makes each [ before it inactive. A ![ stays
		# active: an image's alt text may hold a link.
		if (-not $Opener.Image)
		{
			foreach ($Earlier in $Openers) { if (-not $Earlier.Image) { $Earlier.Active = $false } }
		}
		$Index = $End
	}

	return ,$Items.ToArray()
}

<#
.SYNOPSIS
Split the link reference definitions off the start of a paragraph, as CommonMark reads them.

.OUTPUTS
Definitions (Label, Url and Line) and Rest, the paragraph's other lines.
#>
function Split-MarkdownDefinitions([object[]]$Lines)
{
	$Definitions = New-Object System.Collections.Generic.List[object]
	$Index = 0
	while ($Index -lt $Lines.Count)
	{
		$Text = @($Lines[$Index..($Lines.Count - 1)] | ForEach-Object { $_.Text }) -join "`n"
		$Match = $script:DefinitionPattern.Match($Text)
		if (-not $Match.Success) { break }
		# [^1]: is a footnote, and a label needs more than spaces.
		$Label = $Match.Groups[1].Value
		if (-not $Label.Trim() -or $Label.StartsWith('^')) { break }
		$Url = ConvertFrom-MarkdownDestination ($Match.Groups[2].Value + $Match.Groups[3].Value)
		$Definitions.Add([pscustomobject]@{ Label = (Format-ReferenceLabel $Label); Url = $Url; Line = $Lines[$Index].Line })
		$Index += $Match.Value.Split("`n").Count
	}
	$Rest = @()
	if ($Index -lt $Lines.Count) { $Rest = @($Lines[$Index..($Lines.Count - 1)]) }
	return [pscustomobject]@{ Definitions = $Definitions.ToArray(); Rest = $Rest }
}

<#
.SYNOPSIS
Whether a line starts an HTML block, as CommonMark reads it, and what ends the block.

.PARAMETER InParagraph
The line would carry on a paragraph. A lone tag cannot cut one short; the other starts can.

.OUTPUTS
$null when the line starts no HTML block. Otherwise the pattern of the line that ends it, or ''
when a blank line does.
#>
function Get-HtmlBlockEnd([string]$Body, [bool]$InParagraph)
{
	if ($Body -match '^<(?:script|pre|style|textarea)(?:[ \t>]|$)') { return '(?i)</(?:script|pre|style|textarea)>' }
	if ($Body.StartsWith('<!--')) { return '-->' }
	if ($Body.StartsWith('<?')) { return '\?>' }
	if ($Body.StartsWith('<![CDATA[')) { return '\]\]>' }
	if ($Body -match '^<![A-Za-z]') { return '>' }
	if ($Body -match "^</?(?:$script:HtmlBlockTags)(?:[ \t]|/?>|$)") { return '' }
	if (-not $InParagraph -and $Body -match "^(?:$script:HtmlOpenTag|$script:HtmlClosingTag)[ \t]*$") { return '' }
	return $null
}

<#
.SYNOPSIS
The cells of a GFM table row. Each | that is not escaped splits it, even inside backticks; one at
the start or end of the row only bounds a cell.
#>
function Split-MarkdownTableRow([string]$Row)
{
	$Text = $Row.Trim()
	$Cells = New-Object System.Collections.Generic.List[string]
	$Start = 0
	for ($K = 0; $K -lt $Text.Length; ++$K)
	{
		if ($Text[$K] -eq '\') { $K++; continue }
		if ($Text[$K] -ne '|') { continue }
		$Cells.Add($Text.Substring($Start, $K - $Start))
		$Start = $K + 1
	}
	$Cells.Add($Text.Substring($Start))
	if ($Text.StartsWith('|')) { $Cells.RemoveAt(0) }
	# Nothing after the last |: the row ends with one.
	if ($Cells.Count -gt 0 -and $Start -eq $Text.Length) { $Cells.RemoveAt($Cells.Count - 1) }
	return ,$Cells.ToArray()
}

<#
.SYNOPSIS
How many columns a GFM delimiter row such as | --- | :-: | gives a table, or 0 when the line is not
one. Dashes with no | or : are a setext underline or a thematic break instead.
#>
function Get-MarkdownTableColumns([string]$Line)
{
	if ($Line.IndexOf('|') -lt 0 -and $Line.IndexOf(':') -lt 0) { return 0 }
	$Cells = Split-MarkdownTableRow $Line
	foreach ($Cell in $Cells) { if ($Cell -notmatch '^[ \t]*:?-+:?[ \t]*\z') { return 0 } }
	return $Cells.Count
}

<#
.SYNOPSIS
Check one page of a docs bundle against the contract's Markdown rules.

.DESCRIPTION
Reads the blocks the way CommonMark does: quotes, list items and footnotes hold other blocks, a
paragraph carries on lazily past the end of its container, and fenced code ends at a closing fence
indented at most three spaces in its container. A GFM table runs from its header row to a blank
line or another block, and a --- or === in it is never an underline. Then the links, images and raw
HTML of each paragraph and table cell, once every reference definition is known. The website parses each page with a full CommonMark
parser when it builds and checks the rules again.

.PARAMETER Path
The page's path in the bundle, '/'-separated.

.OUTPUTS
Line and Message for each problem.
#>
function Test-DocsMarkdown
{
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$Text,
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$BundleDir,
		[Parameter(Mandatory)]$Manifest
	)

	$Problems = New-Object System.Collections.Generic.List[object]
	$Problem = { param([int]$Line, [string]$Message) $Problems.Add([pscustomobject]@{ Line = $Line; Message = $Message; Order = $Problems.Count }) }
	# Level, Line and Nested: inside a quote, list item or footnote.
	$Headings = New-Object System.Collections.Generic.List[object]
	$Definitions = New-Object System.Collections.Generic.List[object]
	# Runs of lines to read for links, images and HTML once every definition is known.
	$Spans = New-Object System.Collections.Generic.List[object]
	$Items = New-Object System.Collections.Generic.List[object]
	# The open containers, outermost first: a quote, or a list item or footnote with the indent its
	# content needs.
	$Open = New-Object System.Collections.Generic.List[object]
	# The open leaf: '' for none, para, table, fence or html. End is what ends an HTML block.
	$Leaf = @{ Kind = ''; Fence = ''; End = '' }
	# The paragraph's lines: Line, Text, the Indent before it, and Lazy when it carries on past its
	# container.
	$Para = New-Object System.Collections.Generic.List[object]

	$CloseLeaf = {
		if ($Leaf.Kind -eq 'para' -and $Para.Count -gt 0)
		{
			$Split = Split-MarkdownDefinitions $Para.ToArray()
			foreach ($Definition in $Split.Definitions) { $Definitions.Add($Definition) }
			if ($Split.Rest.Count -gt 0) { $Spans.Add($Split.Rest) }
		}
		$Para.Clear()
		$Leaf.Kind = ''
	}
	# Each cell of a table row is read on its own, as the site renders it.
	$AddRow = {
		param([int]$Line, [string]$Row)
		foreach ($Cell in (Split-MarkdownTableRow $Row)) { $Spans.Add(@([pscustomobject]@{ Line = $Line; Text = $Cell })) }
	}
	$AtxPattern = '^(#{1,6})(?:[ \t](.*))?$'
	$BreakPattern = '^([-*_])([ \t]*\1){2,}[ \t]*$'
	$FencePattern = '^(?:(`{3,})(?!.*`)|(~{3,}))'
	# What cuts a paragraph short, besides quotes, list items and footnotes.
	$Interrupts = {
		param([string]$Body)
		return ($Body -match '^#{1,6}(?:[ \t]|$)' -or $Body -match $FencePattern -or $Body -match $BreakPattern -or $null -ne (Get-HtmlBlockEnd $Body $true))
	}

	# The first line that is not blank: whatever is on it, the H1 has to be.
	$First = 0
	$Lines = $Text.TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n").Split("`n")
	for ($Index = 0; $Index -lt $Lines.Count; ++$Index)
	{
		$Number = $Index + 1
		$Rest = Expand-MarkdownTabs $Lines[$Index]
		if ($First -eq 0 -and $Rest.Trim()) { $First = $Number }

		# The containers this line carries on, each taking its marker or indent off the front.
		$Matched = 0
		foreach ($Container in $Open)
		{
			if ($Container.Kind -eq 'quote')
			{
				$Marker = [regex]::Match($Rest, '^ {0,3}> ?')
				if (-not $Marker.Success) { break }
				$Rest = $Rest.Substring($Marker.Length)
			}
			elseif (-not $Rest.Trim()) { $Rest = '' }
			elseif ((Get-MarkdownIndent $Rest) -ge $Container.Width) { $Rest = $Rest.Substring($Container.Width) }
			else { break }
			$Matched++
		}
		$AllMatched = ($Matched -eq $Open.Count)

		# Code and HTML blocks hold their lines as they are, until they close or their container does.
		if ($Leaf.Kind -eq 'fence' -or $Leaf.Kind -eq 'html')
		{
			if ($AllMatched)
			{
				if ($Leaf.Kind -eq 'fence')
				{
					$Close = [regex]::Match($Rest, '^ {0,3}(`{3,}|~{3,})[ \t]*$')
					if ($Close.Success -and $Close.Groups[1].Value[0] -eq $Leaf.Fence[0] -and $Close.Groups[1].Value.Length -ge $Leaf.Fence.Length) { $Leaf.Kind = '' }
				}
				elseif ($Leaf.End) { if ([regex]::IsMatch($Rest, $Leaf.End)) { $Leaf.Kind = '' } }
				elseif (-not $Rest.Trim()) { $Leaf.Kind = '' }
				continue
			}
			$Leaf.Kind = ''
		}

		# New containers. A paragraph that would carry on is cut short only by a list item that has
		# text and, if numbered, starts at 1.
		$New = New-Object System.Collections.Generic.List[object]
		$Interrupting = ($AllMatched -and $Leaf.Kind -eq 'para')
		while ($true)
		{
			$Indent = Get-MarkdownIndent $Rest
			if ($Indent -ge 4) { break }
			$Body = $Rest.Substring($Indent)
			if ($Body.StartsWith('>'))
			{
				$Rest = $Body.Substring(1)
				if ($Rest.StartsWith(' ')) { $Rest = $Rest.Substring(1) }
				$New.Add(@{ Kind = 'quote' })
				$Interrupting = $false
				continue
			}
			if ($Body -match $BreakPattern) { break }
			$Note = [regex]::Match($Body, '^\[\^[^\[\]\s]+\]:[ ]*')
			if ($Note.Success)
			{
				$Rest = $Body.Substring($Note.Length)
				$New.Add(@{ Kind = 'item'; Width = 4 })
				$Interrupting = $false
				continue
			}
			# ASCII digits only: .NET's \d also takes other scripts' digits, which [int] cannot read.
			$Item = [regex]::Match($Body, '^([-+*]|([0-9]{1,9})[.)])( *)(.*)$')
			if (-not $Item.Success -or ($Item.Groups[3].Length -eq 0 -and $Item.Groups[4].Length -gt 0)) { break }
			$Empty = -not $Item.Groups[4].Value.Trim()
			if ($Interrupting -and ($Empty -or ($Item.Groups[2].Success -and [int]$Item.Groups[2].Value -ne 1))) { break }
			$Marker = $Item.Groups[1].Length
			$Spaces = $Item.Groups[3].Length
			if ($Empty)
			{
				$Width = $Indent + $Marker + 1
				$Rest = ''
			}
			elseif ($Spaces -gt 4)
			{
				# The item starts with indented code.
				$Width = $Indent + $Marker + 1
				$Rest = (' ' * ($Spaces - 1)) + $Item.Groups[4].Value
			}
			else
			{
				$Width = $Indent + $Marker + $Spaces
				$Rest = $Item.Groups[4].Value
			}
			$New.Add(@{ Kind = 'item'; Width = $Width })
			$Interrupting = $false
		}

		$Blank = -not $Rest.Trim()
		$Indent = Get-MarkdownIndent $Rest
		$Body = $Rest.TrimStart(' ')

		# A lazy line: it carries on the paragraph even though its containers have ended.
		if (-not $AllMatched -and $New.Count -eq 0 -and $Leaf.Kind -eq 'para' -and -not $Blank -and ($Indent -ge 4 -or -not (& $Interrupts $Body)))
		{
			$Para.Add([pscustomobject]@{ Line = $Number; Text = $Body; Indent = $Indent; Lazy = $true })
			continue
		}
		if (-not $AllMatched)
		{
			& $CloseLeaf
			while ($Open.Count -gt $Matched) { $Open.RemoveAt($Open.Count - 1) }
		}
		if ($New.Count -gt 0)
		{
			& $CloseLeaf
			foreach ($Container in $New) { $Open.Add($Container) }
		}
		if ($Blank)
		{
			& $CloseLeaf
			continue
		}
		$Nested = ($Open.Count -gt 0)

		if ($Leaf.Kind -eq 'table')
		{
			if ($Indent -lt 4 -and -not (& $Interrupts $Body))
			{
				& $AddRow $Number $Body
				continue
			}
			& $CloseLeaf
		}

		if ($Leaf.Kind -eq 'para')
		{
			# A delimiter row makes the paragraph's last line a table's header row, when both have
			# as many cells. That line cannot carry on past its container, be indented code or
			# start a reference definition.
			$Header = $Para[$Para.Count - 1]
			$Columns = 0
			if ($Indent -lt 4 -and -not $Header.Lazy -and $Header.Indent -lt 4) { $Columns = Get-MarkdownTableColumns $Body }
			if ($Columns -gt 0 -and (Split-MarkdownTableRow $Header.Text).Count -eq $Columns)
			{
				$Before = @($Para.ToArray() | Select-Object -First ($Para.Count - 1))
				$IsDefinition = ((Split-MarkdownDefinitions $Before).Rest.Count -eq 0 -and (Split-MarkdownDefinitions @($Header)).Definitions.Count -gt 0)
				if (-not $IsDefinition)
				{
					$Para.RemoveAt($Para.Count - 1)
					& $CloseLeaf
					$Leaf.Kind = 'table'
					& $AddRow $Header.Line $Header.Text
					continue
				}
			}

			# Underlined with = or -, the paragraph is an H1 or H2, unless it was all definitions.
			if ($Indent -lt 4 -and $Body -match '^(?:=+|-+)[ \t]*$')
			{
				$Split = Split-MarkdownDefinitions $Para.ToArray()
				foreach ($Definition in $Split.Definitions) { $Definitions.Add($Definition) }
				$Para.Clear()
				$Leaf.Kind = ''
				if ($Split.Rest.Count -gt 0)
				{
					$Level = 2
					if ($Body[0] -eq '=') { $Level = 1 }
					$Headings.Add([pscustomobject]@{ Level = $Level; Line = $Split.Rest[0].Line; Nested = $Nested; Text = (@($Split.Rest | ForEach-Object { $_.Text }) -join "`n") })
					$Spans.Add($Split.Rest)
					continue
				}
			}
			elseif ($Indent -ge 4 -or -not (& $Interrupts $Body))
			{
				$Para.Add([pscustomobject]@{ Line = $Number; Text = $Body; Indent = $Indent; Lazy = $false })
				continue
			}
			else { & $CloseLeaf }
		}

		# Indented code.
		if ($Indent -ge 4) { continue }

		$Fence = [regex]::Match($Body, $FencePattern)
		if ($Fence.Success)
		{
			$Leaf.Kind = 'fence'
			$Leaf.Fence = $Fence.Groups[1].Value + $Fence.Groups[2].Value
			continue
		}

		$Atx = [regex]::Match($Body, $AtxPattern)
		if ($Atx.Success)
		{
			# Without the closing #s, which need a space before them: "# #" is an empty H1.
			$Content = [regex]::Replace($Atx.Groups[2].Value.Trim([char[]]" `t"), '(?:^|[ \t]+)#+$', '').Trim([char[]]" `t")
			$Headings.Add([pscustomobject]@{ Level = $Atx.Groups[1].Value.Length; Line = $Number; Nested = $Nested; Text = $Content })
			$Spans.Add(@([pscustomobject]@{ Line = $Number; Text = $Content }))
			continue
		}

		if ($Body -match $BreakPattern) { continue }

		$End = Get-HtmlBlockEnd $Body $false
		if ($null -ne $End)
		{
			$Shown = $Body.Trim()
			if ($Shown.Length -gt 40) { $Shown = $Shown.Substring(0, 40) + '...' }
			$Items.Add([pscustomobject]@{ Kind = 'html'; Value = $Shown; Line = $Number })
			$Leaf.Kind = 'html'
			$Leaf.End = $End
			# Some end on the line they start.
			if ($End -and [regex]::IsMatch($Body, $End)) { $Leaf.Kind = '' }
			continue
		}

		$Leaf.Kind = 'para'
		$Para.Add([pscustomobject]@{ Line = $Number; Text = $Body; Indent = $Indent; Lazy = $false })
	}
	& $CloseLeaf

	$Labels = @{}
	foreach ($Definition in $Definitions) { $Labels[$Definition.Label] = $true }

	# Rules 1 and 2: one H1, first and on its own, and no skipped levels. Like the site, an H1 does
	# not reset the level, so an H3 straight after it is a skip.
	$H1 = @($Headings | Where-Object { $_.Level -eq 1 })
	if ($H1.Count -eq 0)
	{
		& $Problem 1 'No H1. Start the page with "# Title"; it is the page title.'
	}
	else
	{
		if ($H1[0].Nested) { & $Problem $H1[0].Line 'The H1 is inside a quote, list item or footnote. Start the page with a plain "# Title"; it is the page title.' }
		elseif ($First -ne $H1[0].Line) { & $Problem $First "Content before the H1 on line $($H1[0].Line). The H1 is the page title and must come first." }
		if (-not (Get-MarkdownHeadingText $H1[0].Text $Labels)) { & $Problem $H1[0].Line 'The H1 is empty; it is the page title.' }
		foreach ($Extra in @($H1 | Select-Object -Skip 1)) { & $Problem $Extra.Line 'More than one H1. The first is the page title; use ## for sections.' }
	}
	$Last = 1
	foreach ($Heading in $Headings)
	{
		if ($Heading.Level -eq 1) { continue }
		if ($Heading.Level -gt $Last + 1) { & $Problem $Heading.Line "Heading skips a level, H$Last to H$($Heading.Level). Make it H$($Last + 1)." }
		$Last = $Heading.Level
	}

	# Rules 3 to 7.
	foreach ($Span in $Spans)
	{
		foreach ($Item in (Get-DocsInlineItems -Lines $Span -Labels $Labels)) { $Items.Add($Item) }
	}
	$Dir = ''
	if ($Path.Contains('/')) { $Dir = $Path.Substring(0, $Path.LastIndexOf('/')) }
	foreach ($Item in $Items)
	{
		if ($Item.Kind -eq 'html')
		{
			& $Problem $Item.Line "Raw HTML is not allowed: $($Item.Value). KhaosDocs shows it as text and the docs site rejects it. Use Markdown, or put it in backticks."
			continue
		}
		if ($Item.Kind -eq 'imageref')
		{
			& $Problem $Item.Line "Image ![...][$($Item.Value)] is a reference. Write images as ![alt](path): the docs site checks a reference as a link, not an image."
			continue
		}
		$Message = Get-DocsLinkProblem -Url $Item.Value -Image ($Item.Kind -eq 'image') -Dir $Dir -BundleDir $BundleDir -Manifest $Manifest
		if ($Message) { & $Problem $Item.Line $Message }
	}
	# As links, as the site checks them, even those an image uses.
	foreach ($Definition in $Definitions)
	{
		$Message = Get-DocsLinkProblem -Url $Definition.Url -Dir $Dir -BundleDir $BundleDir -Manifest $Manifest
		if ($Message) { & $Problem $Definition.Line $Message }
	}

	return @($Problems | Sort-Object Line, Order | Select-Object Line, Message)
}

<#
.SYNOPSIS
Whether the docs site can read an SVG's size from its <svg> tag, as Astro's image-size does: a
width and a height, or a viewBox, which can stand in for either.
#>
function Test-SvgSize([string]$Tag)
{
	$Length = '^[0-9.]+(?:e[0-9]+)?(?:in|cm|em|ex|m|mm|pc|pt|px)?\z'
	$Width = [regex]::Match($Tag, '\swidth=([''"])([^%]+?)\1')
	$Height = [regex]::Match($Tag, '\sheight=([''"])([^%]+?)\1')
	$HasWidth = ($Width.Success -and $Width.Groups[2].Value -cmatch $Length)
	$HasHeight = ($Height.Success -and $Height.Groups[2].Value -cmatch $Length)
	if ($HasWidth -and $HasHeight) { return $true }
	$ViewBox = [regex]::Match($Tag, '\sviewBox=([''"])(.+?)\1', [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
	if (-not $ViewBox.Success) { return $false }
	if ($HasWidth -or $HasHeight) { return $true }
	$Bounds = $ViewBox.Groups[2].Value.Split(' ')
	return ($Bounds.Count -ge 4 -and $Bounds[2] -cmatch $Length -and $Bounds[3] -cmatch $Length)
}

<#
.SYNOPSIS
Why the docs site cannot read an image, or nothing. Its build reads the size of each image a page
shows and stops on one it cannot read. A raster image may be any of the four formats, whatever its
extension, as the site does not mind.
#>
function Get-DocsImageProblem([string]$Path)
{
	$Bytes = [IO.File]::ReadAllBytes($Path)
	# Latin-1 maps each byte to one character, so the patterns below match bytes.
	$Head = [Text.Encoding]::GetEncoding(28591).GetString($Bytes, 0, [Math]::Min($Bytes.Length, 64))
	if ($Head.StartsWith('version https://git-lfs.github.com/spec/', [StringComparison]::Ordinal))
	{
		return 'This is a Git LFS pointer, not the image: CI checks out without LFS. Commit the image to git itself.'
	}
	if (-not (Test-SameName ([IO.Path]::GetExtension($Path)) '.svg' -IgnoreCase))
	{
		if ($Head -cmatch '^(?:\x89PNG\r\n\x1A\n[\x00-\xFF]{4}(?:IHDR|CgBI)|\xFF\xD8|GIF8[79]a|RIFF[\x00-\xFF]{4}WEBPVP8)') { return $null }
		return 'The docs site cannot read this image: it is not a PNG, JPEG, GIF or WebP file.'
	}

	if (Test-Utf16Bom $Bytes) { return 'The SVG is saved as UTF-16, which the docs site cannot read. Save it as UTF-8.' }
	# The site looks for the tag in the first 1000 bytes, then reads the first one in the file.
	$Root = '<svg\s(?:[^>"'']|"[^"]*"|''[^'']*'')*>'
	if (-not [regex]::IsMatch($script:Utf8NoBom.GetString($Bytes, 0, [Math]::Min($Bytes.Length, 1000)), $Root))
	{
		return 'The docs site cannot read this SVG: there is no <svg ...> tag in its first 1000 bytes.'
	}
	if (-not (Test-SvgSize ([regex]::Match($script:Utf8NoBom.GetString($Bytes), $Root).Value)))
	{
		return 'The docs site cannot read the size of this SVG. Give its <svg> tag a viewBox, or a width and a height.'
	}
	return $null
}

<#
.SYNOPSIS
Check a docs bundle against every file and Markdown rule of the contract, and its docs.json.

.DESCRIPTION
Also checks what the site's build rejects beyond the contract: pages that are not UTF-8, images it
cannot read, docs.json values of the wrong type, URLs in docs.json that are not http(s), and page
names that give no URL, a URL kept for versions, or the URL of another page. Any of these would stop
the site deploying every product.

Each problem is an annotation on the plugin's own file (Docs/...) and, for Markdown, its
line. With -AsWarnings they are reported as warnings, for runs that do not publish.

.OUTPUTS
Errors, the problems that would stop a publish however they were reported, and Warnings.
#>
function Test-DocsBundle
{
	param(
		[Parameter(Mandatory)][string]$BundleDir,
		[switch]$AsWarnings
	)

	$Root = (Get-FullPath $BundleDir).TrimEnd('\', '/')
	$State = @{ Errors = 0; Warnings = 0 }
	$Level = 'error'
	if ($AsWarnings) { $Level = 'warning' }
	$Fail = {
		param([string]$Message, [string]$File, [int]$Line = 0)
		$State.Errors++
		Write-CiAnnotation $Level $Message -File $File -Line $Line -Title 'Docs'
	}

	try { $Manifest = Read-DocsManifest $Root }
	catch
	{
		& $Fail "Not a docs bundle: $($_.Exception.Message)"
		return [pscustomobject]$State
	}
	# Keys in their exact case and values of their exact type, as the site reads JSON: -eq would
	# take "1" or true for 1, and [string] would turn a number or a list into text.
	$Has = { param([string]$Key) (Get-JsonMember $Manifest $Key).Has }
	$Value = { param([string]$Key) return ,(Get-JsonMember $Manifest $Key).Value }
	$Base = [string](& $Value 'base')
	if (-not $Base) { $Base = $script:DocsBase }

	# docs.json -------------------------------------------------------------------------------

	foreach ($Key in $script:DocsRequiredKeys)
	{
		if (-not (& $Has $Key)) { & $Fail "docs.json has no `"$Key`"." }
	}
	$Schema = & $Value 'schema'
	$IsNumber = ($Schema -is [int] -or $Schema -is [long] -or $Schema -is [decimal] -or $Schema -is [double])
	if (-not ($IsNumber -and $Schema -eq 1)) { & $Fail 'docs.json: "schema" must be 1.' }

	$Section = & $Value 'section'
	if (-not ($Section -is [string] -and (Test-NameIn $Section $script:DocsSections))) { & $Fail "docs.json: section '$Section' is not one the docs site knows: $($script:DocsSections -join ', ')." }
	$Slug = & $Value 'slug'
	if (-not ($Slug -is [string] -and $Slug -cmatch $script:DocsSlugPattern)) { & $Fail "docs.json: slug '$Slug' must be lowercase kebab-case." }

	$Hints = @{ name = ' Set FriendlyName in the .uplugin.'; description = ' Set Description in the .uplugin; the docs site shows it on cards.' }
	foreach ($Key in @('name', 'description', 'landing', 'ref', 'base'))
	{
		if (-not (& $Has $Key)) { continue }
		$Text = & $Value $Key
		if ($Text -isnot [string]) { & $Fail "docs.json: `"$Key`" must be a string." }
		elseif (-not $Text.Trim()) { & $Fail "docs.json: `"$Key`" is empty.$($Hints[$Key])" }
	}

	$Released = & $Value 'released'
	# PowerShell 7 reads a date in JSON as a DateTime.
	if ($Released -is [DateTime]) { $Released = $Released.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
	if (-not ($Released -is [string] -and $Released -cmatch $script:DocsDatePattern)) { & $Fail 'docs.json: "released" must be a date, YYYY-MM-DD.' }
	$Commit = & $Value 'commit'
	if (-not ($Commit -is [string] -and $Commit -cmatch $script:DocsCommitPattern)) { & $Fail 'docs.json: "commit" must be a full 40-character SHA.' }
	$Repo = & $Value 'repo'
	if (-not ($Repo -is [string] -and $Repo -cmatch $script:DocsRepoPattern)) { & $Fail 'docs.json: "repo" must be owner/name.' }
	foreach ($Key in @('preview', 'private'))
	{
		if ((& $Has $Key) -and (& $Value $Key) -isnot [bool]) { & $Fail "docs.json: `"$Key`" must be true or false." }
	}
	foreach ($Key in @('supportUrl', 'fabUrl'))
	{
		$Url = & $Value $Key
		if ($null -ne $Url -and -not ($Url -is [string] -and $Url -cmatch $script:DocsUrlPattern)) { & $Fail "docs.json: `"$Key`" must be an http(s) URL or null." }
	}
	$Glyph = & $Value 'glyph'
	if ($null -ne $Glyph -and -not ($Glyph -is [string] -and $Glyph -cmatch '^[A-Za-z]{1,2}\z')) { & $Fail 'docs.json: "glyph" must be one or two letters.' }
	# The site reads unreal only when it is there, and each of its lists only when that is there.
	$Unreal = & $Value 'unreal'
	$Engines = Get-JsonMember $Unreal 'engines'
	if ($Engines.Has -and -not ($Engines.Value -is [Array] -and @($Engines.Value | Where-Object { $_ -isnot [string] }).Count -eq 0))
	{
		& $Fail 'docs.json: "unreal.engines" must be a list of versions as strings, such as "5.8".'
	}
	$Modules = Get-JsonMember $Unreal 'modules'
	if ($Modules.Has -and -not ($Modules.Value -is [Array] -and @($Modules.Value | Where-Object { -not ((Get-JsonMember $_ 'name').Value -is [string] -and (Get-JsonMember $_ 'type').Value -is [string]) }).Count -eq 0))
	{
		& $Fail 'docs.json: "unreal.modules" must be a list of { "name", "type" }, both strings.'
	}

	$Version = & $Value 'version'
	$Preview = & $Value 'preview'
	$Folder = 'preview'
	if ($Preview -is [bool] -and $Preview)
	{
		if ($null -ne $Version) { & $Fail 'docs.json: a preview has "version": null.' }
	}
	elseif ($null -eq $Version)
	{
		# Docs that are not versioned, as the contract allows.
		$Folder = 'current'
	}
	else
	{
		$Folder = [string]$Version
		if (-not (Test-DocsVersion $Version)) { & $Fail "docs.json: version '$Folder' is not a release version such as 1.0.1." }
	}
	$Expected = "$Section/$Slug/$Folder"
	$Actual = @($Root.Replace('\', '/').Split('/') | Select-Object -Last 3) -join '/'
	if (-not (Test-SameName $Actual $Expected)) { & $Fail "The bundle is in .../$Actual, but its docs.json puts it in $Expected." }

	# Files -----------------------------------------------------------------------------------

	$Files = Get-RelativeFiles $Root
	$Pages = New-Object System.Collections.Generic.List[string]
	$Total = [long]0
	$Invariant = [Globalization.CultureInfo]::InvariantCulture
	foreach ($File in $Files)
	{
		$Full = Join-Paths $Root $File
		$Size = (New-Object IO.FileInfo $Full).Length
		$Total += $Size
		if (Test-SameName $File 'docs.json') { continue }

		$Shown = "$Base/$File"
		$Extension = [IO.Path]::GetExtension($File)
		$IsImage = Test-NameIn $Extension.ToLowerInvariant() $script:DocsImageTypes
		if (Test-SameName $Extension '.md') { $Pages.Add($File) }
		elseif (Test-SameName $Extension '.md' -IgnoreCase)
		{
			& $Fail 'A page must end in .md, in lowercase; the docs site rejects anything else. Rename it.' $Shown
			continue
		}
		elseif (-not $IsImage)
		{
			& $Fail 'Only .md pages and .png, .jpg, .jpeg, .webp, .gif and .svg images belong in a docs bundle.' $Shown
			continue
		}
		if ($IsImage -and $Size -gt $script:DocsMaxImageBytes)
		{
			& $Fail ([string]::Format($Invariant, 'The image is over the 5 MB limit ({0:N0} bytes).', $Size)) $Shown
		}
		if ($IsImage)
		{
			$Problem = Get-DocsImageProblem $Full
			if ($Problem) { & $Fail $Problem $Shown }
		}
		if ((Test-NameIn $Extension.ToLowerInvariant() $script:DocsTextTypes) -and [Array]::IndexOf([IO.File]::ReadAllBytes($Full), [byte]13) -ge 0)
		{
			& $Fail 'CR line endings. A bundle uses LF.' $Shown
		}
	}
	if ($Total -gt $script:DocsMaxBundleBytes)
	{
		& $Fail ([string]::Format($Invariant, 'The docs are over the 25 MB limit ({0:N0} bytes). Shrink or drop images.', $Total))
	}

	$Landing = & $Value 'landing'
	if ($Landing -isnot [string]) { $Landing = '' }
	if ($Landing)
	{
		$Found = Find-DocsFile $Root $Landing
		if (-not $Found -or -not [IO.File]::Exists((Join-Paths $Root $Found))) { & $Fail "The landing page $Base/$Landing is missing. It is the product's front page on the docs site." }
		elseif (-not (Test-SameName $Found $Landing)) { & $Fail "The landing page must be named $Landing, with that case." "$Base/$Found" }
	}

	# Each page gets a URL of its own, outside the ones kept for versions.
	$Urls = @{}
	foreach ($File in $Pages)
	{
		$Url = Get-DocsPagePath $File $Landing
		if ($Url.Problem) { & $Fail $Url.Problem "$Base/$File" }
		elseif ($Urls.ContainsKey($Url.Path)) { & $Fail "It gets the same URL as $Base/$($Urls[$Url.Path]): /$Section/$Slug/$($Url.Path). Rename one of them." "$Base/$File" }
		else { $Urls[$Url.Path] = $File }
	}

	# Markdown --------------------------------------------------------------------------------

	$Utf8 = New-Object System.Text.UTF8Encoding $false, $true
	foreach ($File in $Pages)
	{
		try { $Text = $Utf8.GetString([IO.File]::ReadAllBytes((Join-Paths $Root $File))) }
		catch
		{
			& $Fail 'The page is not UTF-8, which is how the docs site reads it. Save it as UTF-8.' "$Base/$File"
			continue
		}
		# A bug in the checker fails this page, not the step, so runs without publish-docs only warn.
		try { $Problems = @(Test-DocsMarkdown -Text $Text -Path $File -BundleDir $Root -Manifest $Manifest) }
		catch
		{
			& $Fail "The docs check failed on this page: $($_.Exception.Message) Report it to KhaosSystems/unreal-actions." "$Base/$File"
			continue
		}
		foreach ($Problem in $Problems)
		{
			& $Fail $Problem.Message "$Base/$File" $Problem.Line
		}
	}

	return [pscustomobject]$State
}

<#
.SYNOPSIS
A release bundle's docs.json, once the bundle has passed Test-DocsBundle. Anything else stops here,
before a folder in docs-content is replaced: a preview, docs with no version, or a bundle whose
docs.json would name the wrong folder.
#>
function Read-DocsRelease([string]$BundleDir)
{
	$Manifest = Read-DocsManifest $BundleDir
	if ($Manifest.preview) { throw "$BundleDir is a preview, and previews are never published. Build the bundle with a release tag." }
	if (-not (Test-DocsVersion $Manifest.version)) { throw "$BundleDir has no release version, such as 1.0.1, in its docs.json. Only releases are published." }
	$Result = Test-DocsBundle -BundleDir $BundleDir
	if ($Result.Errors -gt 0) { throw "$BundleDir has $($Result.Errors) problem(s); see the errors above. Nothing was published." }
	return $Manifest
}

<#
.SYNOPSIS
Commit a docs bundle into a docs-content checkout and push it.

.DESCRIPTION
Replaces <section>/<slug>/<version>/ with a release's bundle and commits that folder alone, as
"<Name> <version> docs". Nothing else may be staged in the checkout. The bundle must pass
Read-DocsRelease: CI pushes releases only. When the push is rejected because the branch moved on,
it fetches, rebases and tries again, three tries in all, as the contract says; any other failure
stops at once. When the folder already holds the bundle, as on a re-run, nothing is committed.

.OUTPUTS
Folder, Changed, and Commit, the commit the branch is at.
#>
function Publish-DocsBundle
{
	param(
		[Parameter(Mandatory)][string]$BundleDir,
		[Parameter(Mandatory)][string]$ContentDir,
		[string]$Branch = 'main',
		[string]$Remote = 'origin',
		[int]$Tries = 3
	)

	$BundleDir = Get-FullPath $BundleDir
	$ContentDir = Get-FullPath $ContentDir
	$Manifest = Read-DocsRelease $BundleDir
	$Folder = Get-DocsBundleFolder $Manifest
	$Identity = @('-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com')
	$Git = {
		param([string]$What, [string[]]$Arguments)
		$Exit = Invoke-NativeCommand -FilePath 'git' -ArgumentList (@('-C', $ContentDir) + $Identity + $Arguments)
		if ($Exit -ne 0) { throw "$What failed in $ContentDir (git exit code $Exit)." }
	}

	# The commit takes the whole index, so nothing else may be in it.
	if ((Invoke-NativeQuiet git @('-C', $ContentDir, 'diff', '--cached', '--quiet', '--', '.', ":(exclude)$Folder")).ExitCode -eq 1)
	{
		throw "$ContentDir has changes staged outside $Folder. Commit or unstage them first."
	}

	$Target = Join-Paths $ContentDir $Folder
	if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
	foreach ($File in (Get-RelativeFiles $BundleDir))
	{
		$To = Join-Paths $Target $File
		New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($To)) -Force | Out-Null
		[IO.File]::Copy((Join-Paths $BundleDir $File), $To, $true)
	}

	# With core.ignorecase, as in a clone on Windows, git keeps the old case of a renamed file. So
	# the folder is unstaged before it is staged, and the commit is not limited to it: that would
	# stage the old name again.
	& $Git 'Unstaging the old docs' @('rm', '-r', '-q', '--cached', '--ignore-unmatch', '--', $Folder)
	& $Git 'Staging the docs' @('add', '-A', '--', $Folder)
	$Result = [pscustomobject]@{ Folder = $Folder; Changed = $false; Commit = $null }
	if ((Invoke-NativeQuiet git @('-C', $ContentDir, 'diff', '--cached', '--quiet', '--', $Folder)).ExitCode -eq 0)
	{
		$Result.Commit = (Invoke-NativeQuiet git @('-C', $ContentDir, 'rev-parse', 'HEAD')).Output | Select-Object -First 1
		return $Result
	}

	& $Git 'Committing the docs' @('commit', '-q', '-m', "$($Manifest.name) $($Manifest.version) docs")

	for ($Try = 1; $Try -le $Tries; ++$Try)
	{
		# --porcelain marks a ref the remote turned away with ! and says why, untranslated.
		$Output = New-Object System.Collections.Generic.List[string]
		$Exit = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $ContentDir, 'push', '--porcelain', $Remote, "HEAD:refs/heads/$Branch") -OnLine ({ param([string]$Line) $Output.Add($Line) }.GetNewClosure())
		if ($Exit -eq 0) { break }

		# Another push got in first: before this one started, so it is not a fast-forward, or while
		# it ran, so the remote could not update the branch.
		$Behind = @($Output | Where-Object { $_ -match '^!\t.*\[(rejected|remote rejected)\] \((fetch first|non-fast-forward|failed to update ref|cannot lock ref|incorrect old value)' }).Count -gt 0
		if (-not $Behind) { throw "Pushing $Folder to $Branch failed; see the git output above." }
		if ($Try -eq $Tries) { throw "Pushing $Folder to $Branch was turned away $Tries times because $Branch kept moving. Re-run to try again." }

		Write-Host "$Branch moved on; rebasing onto it and pushing again."
		& $Git "Fetching $Branch" @('fetch', '-q', $Remote, $Branch)
		$Rebase = Invoke-NativeCommand -FilePath 'git' -ArgumentList (@('-C', $ContentDir) + $Identity + @('rebase', '-q', 'FETCH_HEAD'))
		if ($Rebase -ne 0)
		{
			$null = Invoke-NativeQuiet git @('-C', $ContentDir, 'rebase', '--abort')
			throw "Rebasing onto $Branch failed: someone else changed $Folder at the same time."
		}
	}

	$Result.Changed = $true
	$Result.Commit = (Invoke-NativeQuiet git @('-C', $ContentDir, 'rev-parse', 'HEAD')).Output | Select-Object -First 1
	return $Result
}

#endregion

Export-ModuleMember -Function *
