<#
.SYNOPSIS
Tests for the CI scripts themselves. No engine needed; runs anywhere Windows PowerShell 5.1 does.

.DESCRIPTION
Plain assertions rather than Pester, so it runs on a stock Windows install and on the GitHub
runner without installing anything. Exits non-zero if any check fails.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $Root 'lib/UnrealActions.psm1') -Force

$script:Failures = 0
$script:Passes = 0

function Check([string]$Name, [bool]$Condition, [string]$Detail = '')
{
	if ($Condition)
	{
		$script:Passes++
		Write-Host "  ok    $Name" -ForegroundColor DarkGray
	}
	else
	{
		$script:Failures++
		Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red
	}
}

function Same($Actual, $Expected)
{
	return ((@($Actual) -join "`n") -ceq (@($Expected) -join "`n"))
}

function New-TestFile([string]$Path, [string]$Text)
{
	New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
	[IO.File]::WriteAllText($Path, $Text)
}

<# A 1x1 PNG the docs site can read, padded with zeros to Size bytes. #>
function New-TestPng([string]$Path, [int]$Size = 0)
{
	$Png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')
	$Bytes = New-Object byte[] ([Math]::Max($Size, $Png.Length))
	[Array]::Copy($Png, $Bytes, $Png.Length)
	New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
	[IO.File]::WriteAllBytes($Path, $Bytes)
}

<# A small plugin that meets every requirement; cases break one thing each. #>
function New-FixturePlugin([string]$Dir)
{
	Reset-Directory $Dir
	New-TestFile "$Dir\Sample.uplugin" @'
{
	"FileVersion": 3,
	"Version": 1,
	"VersionName": "0.1",
	"FriendlyName": "Sample",
	"CreatedBy": "Example Studio",
	"FabURL": "https://www.fab.com/listings/00000000-0000-0000-0000-000000000000",
	"CanContainContent": true,
	"Modules": [
		{
			"Name": "SampleEditor",
			"Type": "Editor",
			"LoadingPhase": "Default",
			"PlatformAllowList": [ "Win64" ]
		}
	]
}
'@
	New-TestFile "$Dir\Source\SampleEditor\SampleEditor.Build.cs" "// Copyright 2026 Example Studio. All Rights Reserved.`n"
	New-TestFile "$Dir\Source\SampleEditor\Private\SampleEditor.cpp" "// Copyright 2026 Example Studio. All Rights Reserved.`n"
	New-TestFile "$Dir\Source\ThirdParty\Lib\lib.h" "/* MIT, someone else */`n"
	New-TestFile "$Dir\Source\ThirdParty\Lib\LICENSE.txt" "MIT`n"
	New-TestFile "$Dir\Content\Docs\Readme.md" "# Sample`n"
	New-TestFile "$Dir\Config\FilterPlugin.ini" "[FilterPlugin]`n; comment`n/Extras/...`n-/Extras/Private/...`n"
	New-TestFile "$Dir\Resources\Icon128.png" "png"
	New-TestFile "$Dir\Extras\Notes.txt" "extra"
	New-TestFile "$Dir\Extras\Private\Secret.txt" "secret"
	New-TestFile "$Dir\README.md" "repo readme"
	New-TestFile "$Dir\.gitignore" "Binaries/"
	New-TestFile "$Dir\Tests\Gauntlet.txt" "not packaged"
	New-TestFile "$Dir\Binaries\Win64\UnrealEditor-SampleEditor.dll" "dll"
	New-TestFile "$Dir\Intermediate\Build\x.obj" "obj"
	New-TestFile "$Dir\Source\SampleEditor\Intermediate\y.obj" "obj"
}

<# Run a check and collect the annotations it printed. #>
function Get-Annotations([scriptblock]$Script)
{
	$env:GITHUB_ACTIONS = 'true'
	try
	{
		return @(& $Script 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^::(error|warning|notice)' })
	}
	finally
	{
		Remove-Item Env:\GITHUB_ACTIONS -ErrorAction SilentlyContinue
	}
}

<#
.SYNOPSIS
Run an action's run: script the way a `shell: powershell` step does: in a new Windows PowerShell,
after $ErrorActionPreference = 'stop', and ending with exit $LASTEXITCODE.

.PARAMETER Inputs
The action's inputs by name. Each env: entry set from an input gets its value.

.OUTPUTS
ExitCode and Output, as from Invoke-NativeQuiet.
#>
function Invoke-ActionStep([string]$ActionDir, [hashtable]$Inputs, [hashtable]$Environment = @{})
{
	$Variables = @{ GITHUB_ACTION_PATH = $ActionDir }
	foreach ($Name in $Environment.Keys) { $Variables[$Name] = $Environment[$Name] }
	$Run = New-Object System.Collections.Generic.List[string]
	$Block = -1
	foreach ($Line in [IO.File]::ReadAllLines((Join-Path $ActionDir 'action.yml')))
	{
		$Indent = $Line.Length - $Line.TrimStart().Length
		if ($Block -ge 0)
		{
			if ($Line.Trim() -and $Indent -le $Block) { break }
			$Run.Add($Line.TrimStart())
			continue
		}
		$Variable = [regex]::Match($Line, '^\s+([A-Z_]+): \$\{\{ inputs\.([a-z-]+) \}\}\s*$')
		if ($Variable.Success) { $Variables[$Variable.Groups[1].Value] = [string]$Inputs[$Variable.Groups[2].Value] }
		if ($Line -match '^\s*run: \|\s*$') { $Block = $Indent }
	}

	$File = Join-Paths $Temp ('step-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
	Write-Utf8File $File ("`$ErrorActionPreference = 'stop'`n" + ($Run -join "`n") + "`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }`n")
	$Saved = @{}
	foreach ($Name in $Variables.Keys)
	{
		$Saved[$Name] = [Environment]::GetEnvironmentVariable($Name)
		[Environment]::SetEnvironmentVariable($Name, $Variables[$Name])
	}
	try { return Invoke-NativeQuiet 'powershell.exe' @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ". '$File'") }
	finally
	{
		foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
	}
}

<#
.SYNOPSIS
The sample plugin with docs that pass every rule: a landing page with CRLF line endings, a page in
a folder, an image, an SVG with CRLF line endings, a text file the bundle leaves out, and junk it
skips silently. Its FriendlyName is not its file name, and starts with its maker's first word.
#>
function New-DocsFixture([string]$Dir)
{
	New-FixturePlugin $Dir
	$Descriptor = "$Dir\Sample.uplugin"
	$Text = Set-DescriptorField ([IO.File]::ReadAllText($Descriptor)) 'Description' 'A sample plugin.'
	$Text = Set-DescriptorField $Text 'FriendlyName' 'Example Sample Kit'
	[IO.File]::WriteAllText($Descriptor, (Set-DescriptorField $Text 'SupportURL' 'https://example.com/support'))

	Remove-Item "$Dir\Content\Docs\Readme.md"
	New-TestFile "$Dir\Content\Docs\Sample.md" (@(
		'# Sample'
		''
		'Start with [setup](Guides/Setup.md#install), [the site](https://example.com) or <https://example.com/a>.'
		''
		'![Screenshot](Images/Shot.png "A shot")'
		''
		'## Usage'
		''
		'Read [the source](../../Source/SampleEditor/Private/SampleEditor.cpp), [mail us](mailto:a@example.com) or [jump](#usage).'
		'Inline `<code>` and `[not](/a/link)` are fine, as are a \<escaped> tag, <a@example.com> and [a badge ![b](Images/Shot.png)](https://example.com).'
		''
		'```ini'
		'<NotHtml attr="x">'
		'[Broken](Nowhere.md)'
		'```'
		''
		'    <indented>code</indented>'
		''
		'- An item'
		'  carried on, with [a reference][guide].'
		''
		'1. Step:'
		''
		'   ```text'
		'   # not a heading'
		'   ```'
		''
		'### Details'
		''
		'An underlined heading'
		'---'
		''
		'[guide]: <Guides/Setup.md>'
	) -join "`r`n")
	New-TestFile "$Dir\Content\Docs\Guides\Setup.md" ''
	# With a byte order mark, as Visual Studio saves it.
	[IO.File]::WriteAllText("$Dir\Content\Docs\Guides\Setup.md", "# Setup`n`n## Install`n`nBack to [Sample](../Sample.md), with its ![shot](../Images/Shot.png).`n", (New-Object System.Text.UTF8Encoding $true))
	New-TestPng "$Dir\Content\Docs\Images\Shot.png"
	New-TestFile "$Dir\Content\Docs\Images\Logo.svg" "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>`r`n</svg>`r`n"
	New-TestFile "$Dir\Content\Docs\Images\Thumbs.db" 'junk'
	New-TestFile "$Dir\Content\Docs\Notes.txt" 'notes'
}

function Test-Fixture([string]$Dir)
{
	$Descriptor = Get-PluginDescriptor $Dir
	$Files = Get-PluginPackageFiles $Descriptor
	$script:LastResult = $null
	$Annotations = Get-Annotations { $script:LastResult = Test-PluginPackage -Descriptor $Descriptor -Files $Files }
	return [pscustomobject]@{ Result = $script:LastResult; Annotations = $Annotations; Errors = @($Annotations | Where-Object { $_ -like '::error*' }) }
}

$Temp = Join-Paths ([IO.Path]::GetTempPath()) ('kpci-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$Plugin = Join-Paths $Temp 'Sample'

# The scripts under test write to these. In the self-test job they are the job's own.
$CiFiles = @{}
foreach ($Name in @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY'))
{
	$CiFiles[$Name] = [Environment]::GetEnvironmentVariable($Name)
	[Environment]::SetEnvironmentVariable($Name, $null)
}

try
{
	Write-Host 'FileFilter patterns'
	$Cases = @(
		,@('/Content/...', 'Content/Docs/a.md', $true)
		,@('/Content/...', 'Source/Content/a.md', $false)
		,@('/Content/...', 'Content', $false)
		,@('*.md', 'README.md', $true)
		,@('*.md', 'Content/Docs/a.md', $true)
		,@('*.md', 'a.mdx', $false)
		,@('/README.md', 'README.md', $true)
		,@('/README.md', 'Docs/README.md', $false)
		,@('Docs/', 'Docs/a/b.txt', $true)
		,@('/Binaries/ThirdParty/*.dll', 'Binaries/ThirdParty/x.dll', $true)
		,@('/Binaries/ThirdParty/*.dll', 'Binaries/ThirdParty/Win64/x.dll', $false)
		,@('/Source/.../Tests/...', 'Source/A/Private/Tests/x.cpp', $true)
		,@('/Source/.../Tests/...', 'Source/Tests/x.cpp', $true)
		,@('/a?c.txt', 'abc.txt', $true)
		,@('/a?c.txt', 'a/c.txt', $false)
		,@('/Extras...', 'Extras2/x.txt', $true)
	)
	foreach ($Case in $Cases)
	{
		$Regex = ConvertTo-FilterRegex $Case[0]
		Check "'$($Case[0])' vs '$($Case[1])' is $($Case[2])" (([regex]::IsMatch($Case[1], $Regex)) -eq $Case[2]) "(regex $Regex)"
	}

	Write-Host 'Package contents'
	New-FixturePlugin $Plugin
	$Files = Get-PluginPackageFiles (Get-PluginDescriptor $Plugin)
	$Expected = @(
		'Config/FilterPlugin.ini'
		'Content/Docs/Readme.md'
		'Extras/Notes.txt'
		'Resources/Icon128.png'
		'Sample.uplugin'
		'Source/SampleEditor/Private/SampleEditor.cpp'
		'Source/SampleEditor/SampleEditor.Build.cs'
		'Source/ThirdParty/Lib/LICENSE.txt'
		'Source/ThirdParty/Lib/lib.h'
	)
	Check 'only the shippable files, sorted' (Same $Files $Expected) "got:`n$($Files -join "`n")"

	Write-Host 'Validation'
	$Clean = Test-Fixture $Plugin
	Check 'a compliant plugin has no errors or warnings' ($Clean.Annotations.Count -eq 0) ($Clean.Annotations -join "`n")
	Check 'counts are returned' ($Clean.Result.Errors -eq 0 -and $Clean.Result.Warnings -eq 0)

	$Breakages = @(
		@{
			Name = 'module without a platform list'
			Break = { $Path = "$Plugin\Sample.uplugin"; [IO.File]::WriteAllText($Path, ([IO.File]::ReadAllText($Path) -replace ',\s*"PlatformAllowList": \[ "Win64" \]', '')) }
			Expect = 'PlatformAllowList'
		}
		@{
			Name = 'source file without a copyright line'
			Break = { New-TestFile "$Plugin\Source\SampleEditor\Private\New.cpp" "#include `"x.h`"`n" }
			Expect = 'file=Source/SampleEditor/Private/New.cpp,line=1'
		}
		@{
			Name = "Epic's notice left in from a template"
			Break = { New-TestFile "$Plugin\Source\SampleEditor\Private\New.h" "// Copyright Epic Games, Inc. All Rights Reserved.`n" }
			Expect = "should name 'Example Studio'"
		}
		@{
			Name = 'copyright notice without a year'
			Break = { New-TestFile "$Plugin\Source\SampleEditor\Private\New.h" "// Copyright Example Studio. All Rights Reserved.`n" }
			Expect = 'needs the year of publishing'
		}
		@{
			Name = 'license file outside ThirdParty'
			Break = { New-TestFile "$Plugin\Content\LICENSE" "x" }
			Expect = 'file=Content/LICENSE'
		}
		@{
			Name = 'nested archive'
			Break = { New-TestFile "$Plugin\Content\Extra.zip" "x" }
			Expect = 'nested archives'
		}
		@{
			Name = 'no Config folder'
			Break = { Remove-Item "$Plugin\Config" -Recurse -Force }
			Expect = 'Config/ folder'
		}
		@{
			Name = 'config file that BuildPlugin leaves out'
			Break = { New-TestFile "$Plugin\Config\DefaultSample.ini" "[/Script/Sample.Settings]`n" }
			Expect = 'file=Config/DefaultSample.ini'
		}
		@{
			Name = 'module with no Build.cs'
			Break = { Remove-Item "$Plugin\Source\SampleEditor\SampleEditor.Build.cs" }
			Expect = 'no SampleEditor.Build.cs'
		}
	)
	foreach ($Breakage in $Breakages)
	{
		New-FixturePlugin $Plugin
		& $Breakage.Break
		$Outcome = Test-Fixture $Plugin
		$Hit = @($Outcome.Errors | Where-Object { $_.Contains($Breakage.Expect) })
		Check "reports $($Breakage.Name)" ($Hit.Count -gt 0 -and $Outcome.Result.Errors -gt 0) ($Outcome.Annotations -join "`n")
	}

	New-FixturePlugin $Plugin
	New-TestFile "$Plugin\Config\DefaultSample.ini" "[/Script/Sample.Settings]`n"
	Add-Content "$Plugin\Config\FilterPlugin.ini" '/Config/DefaultSample.ini'
	$Outcome = Test-Fixture $Plugin
	Check 'a config file listed in FilterPlugin.ini is fine' ($Outcome.Errors.Count -eq 0) ($Outcome.Annotations -join "`n")

	New-FixturePlugin $Plugin
	Remove-Item "$Plugin\Resources\Icon128.png"
	$Outcome = Test-Fixture $Plugin
	Check 'a missing icon only warns' ($Outcome.Result.Errors -eq 0 -and $Outcome.Result.Warnings -eq 1)

	Write-Host 'Descriptor stamping'
	$Text = "{`r`n`t`"FileVersion`": 3,`r`n`t`"Version`": 1,`r`n`t`"VersionName`": `"0.1`",`r`n`t`"Plugins`": [ { `"Name`": `"X`", `"Enabled`": true } ]`r`n}`r`n"
	$Stamped = Set-DescriptorField $Text 'VersionName' '1.2.3'
	$Stamped = Set-DescriptorField $Stamped 'Version' 1002003
	$Stamped = Set-DescriptorField $Stamped 'EngineVersion' '5.8.0'
	$Json = $Stamped | ConvertFrom-Json
	Check 'replaces and inserts fields' ($Json.VersionName -eq '1.2.3' -and $Json.Version -eq 1002003 -and $Json.EngineVersion -eq '5.8.0')
	Check 'keeps tabs and CRLF' ($Stamped.Contains("`r`n`t`"EngineVersion`": `"5.8.0`",`r`n") -and $Stamped.Contains("`t`"VersionName`": `"1.2.3`""))
	Check 'leaves the rest alone' ($Stamped.Contains('"Plugins": [ { "Name": "X", "Enabled": true } ]'))
	$Unstamped = Remove-DescriptorField $Stamped 'EngineVersion'
	Check 'removes a field and nothing else' ($Unstamped -eq (Set-DescriptorField (Set-DescriptorField $Text 'VersionName' '1.2.3') 'Version' 1002003))
	$Last = "{`n`t`"FileVersion`": 3,`n`t`"EngineVersion`": `"5.8.0`"`n}`n"
	Check 'removes a last field with the comma before it' ((Remove-DescriptorField $Last 'EngineVersion') -eq "{`n`t`"FileVersion`": 3`n}`n")
	Check 'leaves a descriptor without the field as it is' ((Remove-DescriptorField $Text 'EngineVersion') -eq $Text)

	Write-Host 'Release versions'
	$Release = ConvertFrom-ReleaseVersion 'v1.2.3'
	Check 'v1.2.3 is 1002003' ($Release.VersionName -eq '1.2.3' -and $Release.Version -eq 1002003)
	Check 'prereleases keep their suffix' ((ConvertFrom-ReleaseVersion 'v2.0.0-rc.1').VersionName -eq '2.0.0-rc.1')
	Check 'later releases sort higher' ((ConvertFrom-ReleaseVersion '1.10.0').Version -gt (ConvertFrom-ReleaseVersion '1.9.99').Version)
	$Threw = $false
	try { ConvertFrom-ReleaseVersion 'v1.2' | Out-Null } catch { $Threw = $true }
	Check 'rejects a two-part version' $Threw

	Write-Host 'Zips'
	New-FixturePlugin $Plugin
	$Files = Get-PluginPackageFiles (Get-PluginDescriptor $Plugin)
	New-PluginZip -SourceDir $Plugin -Files $Files -RootFolder 'Sample' -ZipPath "$Temp\a.zip"
	Start-Sleep -Milliseconds 1100
	(Get-Item "$Plugin\Content\Docs\Readme.md").LastWriteTime = Get-Date
	New-PluginZip -SourceDir $Plugin -Files $Files -RootFolder 'Sample' -ZipPath "$Temp\b.zip"
	Check 'same sources give the same bytes' ((Get-FileSha256 "$Temp\a.zip") -eq (Get-FileSha256 "$Temp\b.zip"))

	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$Zip = [System.IO.Compression.ZipFile]::OpenRead("$Temp\a.zip")
	try { $Entries = @($Zip.Entries | ForEach-Object { $_.FullName }) } finally { $Zip.Dispose() }
	Check 'entries sit under one root folder with / separators' (Same $Entries ($Files | ForEach-Object { "Sample/$_" }))

	Expand-PluginZip -ZipPath "$Temp\a.zip" -Destination "$Temp\x"
	Check 'extracts back to the plugin' (Test-Path "$Temp\x\Sample\Source\SampleEditor\Private\SampleEditor.cpp")

	Write-Host 'Compiler output'
	$Log = @(
		'C:\b\out\Sample\HostProject\Plugins\Sample\Source\SampleEditor\Private\A.cpp(12,5): error C2065: ''Foo'': undeclared identifier'
		'C:\b\out\Sample\HostProject\Plugins\Sample\Source\SampleEditor\Private\A.cpp(12,5): error C2065: ''Foo'': undeclared identifier'
		'C:\b\out\Sample\HostProject\Plugins\Sample\Source\SampleEditor\Private\B.cpp(3): warning C4996: ''Old'': deprecated'
		'C:\Program Files\Epic Games\UE_5.8\Engine\Source\Runtime\Core\Public\X.h(19,3): warning C4100: engine noise'
		'C:\Program Files\Epic Games\UE_5.8\Engine\Source\Runtime\Core\Public\X.h(19,3): error C2027: use of undefined type ''UThing'''
		'C:\b\out\Sample\HostProject\Plugins\Sample\Source\SampleEditor\Private\C.h(16,7): note: see declaration of ''UThing'''
		'C:\b\out\Sample\HostProject\Plugins\Sample\Source\SampleEditor\Public\D.h(67): Error: An explicit Category specifier is required'
		'[3/8] Compile [x64] A.cpp'
	)
	$Report = New-CompileDiagnosticReporter -PluginName 'Sample' -Label 'UE 5.8'
	$Annotations = Get-Annotations { foreach ($Line in $Log) { & $Report $Line } }
	Check 'reports each plugin diagnostic once' ($Annotations.Count -eq 4) ($Annotations -join "`n")
	Check 'reports UnrealHeaderTool errors' (@($Annotations | Where-Object { $_ -like '::error file=Source/SampleEditor/Public/D.h,line=67,title=UE 5.8 error::*Category*' }).Count -eq 1) ($Annotations -join "`n")
	Check 'maps errors to the repository path' (@($Annotations | Where-Object { $_ -like '::error file=Source/SampleEditor/Private/A.cpp,line=12,*' }).Count -eq 1)
	Check 'keeps warnings as warnings' (@($Annotations | Where-Object { $_ -like '::warning file=Source/SampleEditor/Private/B.cpp,line=3,*' }).Count -eq 1)
	Check 'pins engine-header errors on the plugin line that caused them' (@($Annotations | Where-Object { $_ -like '::error file=Source/SampleEditor/Private/C.h,line=16,*undefined type*' }).Count -eq 1)

	Write-Host 'Content versions'
	# A package summary as UE 5.6+ writes it: tag, legacy -9, UE3, UE4, UE5 1018, licensee, saved hash
	# and header size, then the custom versions: FortniteMain 268 and one the engine does not list.
	$Package = New-Object IO.MemoryStream
	$Writer = New-Object IO.BinaryWriter($Package)
	foreach ($Value in @(-1641380927, -9, 864, 522, 1018, 0)) { $Writer.Write([int]$Value) }
	$Writer.Write((New-Object byte[] 20)); $Writer.Write([int]0)
	$Writer.Write([int]2)
	foreach ($Part in @(0x601D1886, 0xAC644F84, 0xAA16D3DE, 0x0DEAC7D6)) { $Writer.Write([int]$Part) } # same bytes as the uint32s
	$Writer.Write([int]268)
	foreach ($Part in @(1, 2, 3, 4)) { $Writer.Write([int]$Part) }
	$Writer.Write([int]5)
	$Writer.Write((New-Object byte[] 64))
	$ContentPlugin = Join-Paths $Temp 'ContentPlugin'
	New-Item -ItemType Directory -Path "$ContentPlugin\Content\Maps" -Force | Out-Null
	[IO.File]::WriteAllBytes("$ContentPlugin\Content\Maps\L_Demo.umap", $Package.ToArray())
	New-TestFile "$ContentPlugin\Content\Docs\Readme.md" "# not a package`n"

	$Saved = @(Get-UnrealPackageCustomVersions "$ContentPlugin\Content\Maps\L_Demo.umap")
	Check 'reads the custom versions a package was saved with' ($Saved.Count -eq 2 -and $Saved[0].Key -eq '601D1886-AC644F84-AA16D3DE-0DEAC7D6' -and $Saved[0].Version -eq 268) ($Saved | Out-String)
	Check 'a file that is not a package has none' (@(Get-UnrealPackageCustomVersions "$ContentPlugin\Content\Docs\Readme.md").Count -eq 0)

	function New-FakeEngineSource([string]$Root, [int]$Latest)
	{
		New-TestFile "$Root\Engine\Source\Runtime\Core\Private\UObject\DevObjectVersion.cpp" "const FGuid FFortniteMainBranchObjectVersion::GUID(0x601D1886, 0xAC644F84, 0xAA16D3DE, 0x0DEAC7D6);`n"
		New-TestFile "$Root\Engine\Source\Runtime\Core\Public\UObject\FortniteMainBranchObjectVersions.inl" "#define FORTNITE_MAIN_VERSION(Version, ID) Version,`nFORTNITE_MAIN_VERSION(BeforeCustomVersionWasAdded, 0)`nFORTNITE_MAIN_VERSION(Latest, $Latest)`n#undef FORTNITE_MAIN_VERSION`n"
	}
	New-FakeEngineSource "$Temp\UE_old" 225
	New-FakeEngineSource "$Temp\UE_new" 268
	$Limits = Get-EngineCustomVersionLimits "$Temp\UE_old"
	Check "reads an engine's newest versions from its source" ($Limits['601D1886-AC644F84-AA16D3DE-0DEAC7D6'].Latest -eq 225)

	$script:TooNew = $null
	$Annotations = Get-Annotations { $script:TooNew = Test-PluginContentVersions -PluginDir $ContentPlugin -EngineRoot "$Temp\UE_old" -EngineVersion '9.7' }
	Check 'an asset saved by a newer engine is an error on that asset' ($script:TooNew -eq 1 -and @($Annotations | Where-Object { $_ -like '::error file=Content/Maps/L_Demo.umap,*9.7*FortniteMainBranchObjectVersion 268, newest 225*' }).Count -eq 1) ($Annotations -join "`n")
	$script:TooNew = $null
	$Annotations = Get-Annotations { $script:TooNew = Test-PluginContentVersions -PluginDir $ContentPlugin -EngineRoot "$Temp\UE_new" -EngineVersion '9.8' }
	Check 'the engine that saved it is fine' ($script:TooNew -eq 0 -and $Annotations.Count -eq 0) ($Annotations -join "`n")
	$script:TooNew = $null
	$Annotations = Get-Annotations { $script:TooNew = Test-PluginContentVersions -PluginDir $ContentPlugin -EngineRoot "$Temp\nowhere" -EngineVersion '9.9' }
	Check 'an engine without its source only warns' ($script:TooNew -eq 0 -and @($Annotations | Where-Object { $_ -like '::warning*not checked*' }).Count -eq 1) ($Annotations -join "`n")

	Write-Host 'Engine lookup'
	$FakeEngine = Join-Paths $Temp 'UE_9.9'
	New-TestFile "$FakeEngine\Engine\Build\BatchFiles\RunUAT.bat" '@echo off'
	New-TestFile "$FakeEngine\Engine\Build\Build.version" '{ "MajorVersion": 9, "MinorVersion": 9, "PatchVersion": 1, "Changelist": 123, "BranchName": "++UE9+Release-9.9" }'
	try
	{
		$env:UE_ROOT_9_9 = $FakeEngine
		Check 'an override that is the right engine is used' ((Find-UnrealEngine '9.9') -eq $FakeEngine)
		Check 'the build is described exactly' ((Get-UnrealEngineBuild $FakeEngine).Description -eq '9.9.1, changelist 123, ++UE9+Release-9.9')

		$env:UE_ROOT_9_9 = Join-Paths $Temp 'nowhere'
		$Annotations = Get-Annotations { try { Find-UnrealEngine '9.9' | Out-Null } catch { $script:Caught = $_.Exception.Message } }
		Check 'an override pointing nowhere is an error, not a fallback' ($script:Caught -like 'UE_ROOT_9_9 is set to*no engine there*' -and @($Annotations | Where-Object { $_ -like '::error*Unreal Engine 9.9 not found*' }).Count -eq 1) "$script:Caught"

		New-TestFile "$FakeEngine\Engine\Build\Build.version" '{ "MajorVersion": 9, "MinorVersion": 8, "PatchVersion": 0, "Changelist": 1, "BranchName": "x" }'
		$env:UE_ROOT_9_9 = $FakeEngine
		$script:Caught = $null
		$null = Get-Annotations { try { Find-UnrealEngine '9.9' | Out-Null } catch { $script:Caught = $_.Exception.Message } }
		Check 'an override pointing at another version is an error' ($script:Caught -like '*that is Unreal Engine 9.8*') "$script:Caught"

		Remove-Item Env:\UE_ROOT_9_9
		$script:Caught = $null
		$Annotations = Get-Annotations { try { Find-UnrealEngine '9.9' | Out-Null } catch { $script:Caught = $_.Exception.Message } }
		Check 'a missing engine is an error that says how to fix it' ($script:Caught -like 'Unreal Engine 9.9 is not installed on*Epic Games Launcher*UE_ROOT_9_9*' -and $Annotations.Count -eq 1) "$script:Caught"
	}
	finally
	{
		Remove-Item Env:\UE_ROOT_9_9 -ErrorAction SilentlyContinue
	}

	Write-Host 'Cache isolation'
	$Cache = Get-PluginCache (Join-Paths $Temp 'cache\UE5.8')
	Check 'cache folders are created under the given root' ((Test-Path $Cache.Ddc) -and (Test-Path $Cache.Zen) -and (Test-Path $Cache.Uba) -and $Cache.Ddc.StartsWith($Cache.Root))
	Check 'the Zen port avoids the shared default' ($Cache.ZenPort -ge 8600 -and $Cache.ZenPort -lt 9000)
	Check 'the Zen port is stable for a folder' ((Get-PluginCache $Cache.Root).ZenPort -eq $Cache.ZenPort)
	$Other = Get-PluginCache (Join-Paths $Temp 'cache\UE5.7')
	Check 'different folders usually get different ports' ($Other.ZenPort -ne $Cache.ZenPort)

	$Saved = @{}
	Get-ChildItem Env: | Where-Object { $_.Name -like 'UnrealBuildTool_*' } | ForEach-Object { $Saved[$_.Name] = $_.Value }
	try
	{
		Set-UnrealBuildToolIsolation $Cache
		Check 'UnrealBuildTool stays on this machine, with no cache server' ($env:UnrealBuildTool_BuildConfiguration__bAllowUBAExecutor -eq 'false' -and $env:UnrealBuildTool_BuildConfiguration__bAllowXGE -eq 'false' -and $env:UnrealBuildTool_UnrealBuildAccelerator__ForceNoCache -eq 'true' -and $env:UnrealBuildTool_UnrealBuildAccelerator__bDisableHorde -eq 'true')
		Check "UBA's root is the cache folder, with a small cap" ($env:UnrealBuildTool_UnrealBuildAccelerator__RootDir -eq $Cache.Uba -and $env:UnrealBuildTool_UnrealBuildAccelerator__StoreCapacityGb -eq '5')
	}
	finally
	{
		Get-ChildItem Env: | Where-Object { $_.Name -like 'UnrealBuildTool_*' } | ForEach-Object { Remove-Item "Env:\$($_.Name)" }
		foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name], 'Process') }
	}

	$EditorArguments = (Get-EditorCacheArguments $Cache) -join ' '
	Check 'the editor cache graph has no Zen, shared or cloud store' ($EditorArguments -match '(^| )-DDC=\(Local\)( |$)')
	Check 'the editor cache and Zen live in the cache folder' ($EditorArguments.Contains("-LocalDataCachePath=`"$($Cache.Ddc)`"") -and $EditorArguments.Contains("-ZenDataPath=`"$($Cache.Zen)`"") -and $EditorArguments.Contains("DesiredPort=$($Cache.ZenPort)"))

	Write-Host 'Badges'
	Check 'engine lists parse from JSON' (Same (ConvertFrom-EngineVersions '["5.7", "5.8"]') @('5.7', '5.8'))
	Check 'engine lists parse from commas' (Same (ConvertFrom-EngineVersions ' 5.8 ') @('5.8'))
	$Threw = $false
	try { ConvertFrom-EngineVersions '5' | Out-Null } catch { $Threw = $true }
	Check 'a bad engine version is rejected' $Threw

	New-FixturePlugin $Plugin
	New-TestFile "$Plugin\Source\SampleEditor\Private\Extra.cpp" "// Copyright 2026 Example Studio. All Rights Reserved.`n`nint A;`n   `nint B;`n"
	New-TestFile "$Plugin\Source\ThirdParty\Lib\big.cpp" "int X;`nint Y;`n"
	Check 'lines of code count non-blank own source only' ((Measure-PluginSource (Get-PluginDescriptor $Plugin)) -eq 5)

	function Badge($Badges, $Name) { return ($Badges[$Name] | ConvertFrom-Json) }
	$Pass = [pscustomobject]@{ engine = '5.8'; passed = 21; failed = 0; total = 21 }
	$Fail = [pscustomobject]@{ engine = '5.7'; passed = 19; failed = 2; total = 21 }
	$NotRun = [pscustomobject]@{ engine = '5.7'; passed = 0; failed = 0; total = 0 }

	$B = Get-PluginBadges -Engines @('5.8') -Results @($Pass) -Lines 3918
	Check 'all passing reads as passed, in green' ((Badge $B 'tests.json').message -eq '21 passed' -and (Badge $B 'tests.json').color -eq 'brightgreen')
	Check 'lines of code are shortened' ((Badge $B 'loc.json').message -eq '3.9k')
	Check 'the engine badge lists versions with the Unreal logo' ((Badge $B 'unreal.json').message -eq '5.8' -and (Badge $B 'unreal.json').namedLogo -eq 'unrealengine')

	$B = Get-PluginBadges -Engines @('5.7', '5.8') -Results @($Pass, $Fail) -Lines 10
	Check 'a failure names the engine, in red' ((Badge $B 'tests.json').message -eq '2 failed on UE 5.7' -and (Badge $B 'tests.json').color -eq 'red')
	Check 'several engines are listed' ((Badge $B 'unreal.json').message -eq '5.7 | 5.8')

	$B = Get-PluginBadges -Engines @('5.7', '5.8') -Results @($Pass, $NotRun) -Lines 10
	Check 'an engine whose tests never ran is called out' ((Badge $B 'tests.json').message -eq '21 passed, not run on UE 5.7' -and (Badge $B 'tests.json').color -eq 'orange')

	$B = Get-PluginBadges -Engines @('5.8') -Results @() -Lines 999
	Check 'no results reads as not run' ((Badge $B 'tests.json').message -eq 'not run' -and (Badge $B 'loc.json').message -eq '999')

	# The whole badges script, pushing to a local repository instead of GitHub.
	$Remote = Join-Paths $Temp 'remote.git'
	$null = Invoke-NativeQuiet git @('init', '-q', '--bare', $Remote)
	$Results = Join-Paths $Temp 'results'
	New-TestFile "$Results\test-results-UE5.8\test-results.json" '{"engine":"5.8","passed":21,"failed":0,"total":21,"note":""}'
	$BadgeScript = Join-Path $Root 'plugin/badges/Update-Badges.ps1'
	$First = (& $BadgeScript -PluginDir $Plugin -EngineVersions '5.8' -ResultsDir $Results -Repository 'test/test' -RemoteUrl $Remote 6>&1 | Out-String)
	$Files = (Invoke-NativeQuiet git @('--git-dir', $Remote, 'ls-tree', '--name-only', 'badges')).Output
	Check 'badges are pushed to their own branch' ((Same ($Files | Sort-Object) @('loc.json', 'tests.json', 'unreal.json')) -and $First.Contains('Updated the badges')) "$First $Files"
	$Tests = (Invoke-NativeQuiet git @('--git-dir', $Remote, 'show', 'badges:tests.json')).Output -join ''
	Check 'the pushed tests badge has the results' (($Tests | ConvertFrom-Json).message -eq '21 passed')
	$Second = (& $BadgeScript -PluginDir $Plugin -EngineVersions '5.8' -ResultsDir $Results -Repository 'test/test' -RemoteUrl $Remote 6>&1 | Out-String)
	$Commits = (Invoke-NativeQuiet git @('--git-dir', $Remote, 'rev-list', '--count', 'badges')).Output
	Check 'unchanged badges make no commit' ($Second.Contains('Badges unchanged') -and $Commits -eq '1') "$Second $Commits"

	Write-Host 'Conventional commits'
	$Cases = @(
		,@('feat: outline panel', 'feat', $false)
		,@('fix(ui): crash on save', 'fix', $false)
		,@('feat!: drop 5.6', 'feat', $true)
		,@('chore(deps)!: bump', 'chore', $true)
		,@('Fix: capitalised type', 'fix', $false)
	)
	foreach ($Case in $Cases)
	{
		$Parsed = ConvertFrom-ConventionalCommit $Case[0]
		Check "'$($Case[0])' is $($Case[1]), breaking $($Case[2])" ($Parsed -and $Parsed.Type -eq $Case[1] -and $Parsed.Breaking -eq $Case[2])
	}
	Check 'a BREAKING CHANGE footer is breaking' ((ConvertFrom-ConventionalCommit "refactor: rename`n`nBREAKING CHANGE: API renamed").Breaking)
	Check 'the footer token is case sensitive' (-not (ConvertFrom-ConventionalCommit "refactor: rename`n`nbreaking change: no").Breaking)
	foreach ($Message in @('fixed stuff', 'feat:no space', 'feat(): empty scope', 'Merge branch main'))
	{
		Check "'$Message' is not a conventional commit" ($null -eq (ConvertFrom-ConventionalCommit $Message))
	}

	function New-TestRepo([string]$Name)
	{
		$Dir = Join-Paths $Temp $Name
		New-Item -ItemType Directory -Path $Dir -Force | Out-Null
		$null = Invoke-NativeQuiet git @('-C', $Dir, 'init', '-q')
		return $Dir
	}
	function Add-TestCommit([string]$Dir, [string]$Message, [string]$Tag)
	{
		$Parts = $Message -split "`n`n", 2
		$Arguments = @('-C', $Dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '--allow-empty', '-m', $Parts[0])
		if ($Parts.Count -gt 1) { $Arguments += @('-m', $Parts[1]) }
		$null = Invoke-NativeQuiet git $Arguments
		if ($Tag) { $null = Invoke-NativeQuiet git @('-C', $Dir, 'tag', $Tag) }
		return ((Invoke-NativeQuiet git @('-C', $Dir, 'rev-parse', 'HEAD')).Output | Select-Object -First 1)
	}

	Write-Host 'Next version'
	$Repo = New-TestRepo 'versions'
	$null = Add-TestCommit $Repo 'feat: first' 'v0.1.0'

	$null = Add-TestCommit $Repo 'fix: small'
	$Next = Get-NextVersion -RepoDir $Repo
	Check 'a fix bumps the patch' ($Next.Version -eq '0.1.1' -and $Next.Bump -eq 'patch' -and $Next.Previous -eq 'v0.1.0') "$($Next.Version) $($Next.Bump) $($Next.Previous)"

	$C3 = Add-TestCommit $Repo 'feat: bigger'
	$Next = Get-NextVersion -RepoDir $Repo
	Check 'a feature bumps the minor' ($Next.Version -eq '0.2.0' -and $Next.Bump -eq 'minor') "$($Next.Version)"
	$null = Invoke-NativeQuiet git @('-C', $Repo, 'tag', 'v0.2.0')
	Check 'a commit already released has nothing to release' ((Get-NextVersion -RepoDir $Repo -Ref $C3).Bump -eq 'none')

	$C4 = Add-TestCommit $Repo 'fix!: breaking while still 0.x'
	$Next = Get-NextVersion -RepoDir $Repo
	Check 'a breaking change bumps the minor while 0.x' ($Next.Version -eq '0.3.0' -and $Next.Bump -eq 'minor') "$($Next.Version)"
	$null = Invoke-NativeQuiet git @('-C', $Repo, 'tag', 'v1.0.0')

	$null = Add-TestCommit $Repo "refactor: new API`n`nBREAKING CHANGE: the old one is gone"
	$Next = Get-NextVersion -RepoDir $Repo
	Check 'a breaking change bumps the major from 1.0' ($Next.Version -eq '2.0.0' -and $Next.Bump -eq 'major') "$($Next.Version)"
	$null = Invoke-NativeQuiet git @('-C', $Repo, 'tag', 'v2.0.0')

	$null = Add-TestCommit $Repo 'ci: pipeline' 'v3.0.0-rc.1'
	$null = Add-TestCommit $Repo 'docs: guide'
	$Next = Get-NextVersion -RepoDir $Repo
	Check 'housekeeping alone makes no release' ($Next.Version -eq '' -and $Next.Bump -eq 'none')
	Check 'prerelease tags are not a base' ($Next.Previous -eq 'v2.0.0') "$($Next.Previous)"
	$Untagged = New-TestRepo 'untagged'
	$null = Add-TestCommit $Untagged 'fix: only'
	Check 'with no tags yet, versions start from 0.0.0' ((Get-NextVersion -RepoDir $Untagged).Version -eq '0.0.1')

	$Notes = Get-ReleaseNotes -RepoDir $Repo -Ref $C4
	Check 'breaking changes get their own section' ($Notes -match '(?m)^### Breaking changes\n- breaking while still 0\.x \(') $Notes

	Write-Host 'Commit check'
	$Messy = New-TestRepo 'messy'
	$Base = Add-TestCommit $Messy 'chore: start'
	foreach ($Message in @('feat: good', 'fixed stuff', 'feature: wrong type', 'Revert "feat: good"', 'fix(ui): also good'))
	{
		$null = Add-TestCommit $Messy $Message
	}
	$script:Bad = 0
	$Annotations = Get-Annotations { $script:Bad = Test-ConventionalCommits -RepoDir $Messy -Range "$Base..HEAD" }
	Check 'only the non-conventional commits are reported' ($script:Bad -eq 2 -and $Annotations.Count -eq 2) ($Annotations -join "`n")
	Check 'a wrong type is named' (@($Annotations | Where-Object { $_ -match "type 'feature'" }).Count -eq 1)

	Write-Host 'Release notes'
	$Repo = Join-Paths $Temp 'repo'
	New-Item -ItemType Directory -Path $Repo -Force | Out-Null
	$Git = { param([string[]]$Arguments) $null = Invoke-NativeQuiet git (@('-C', $Repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.com') + $Arguments) }
	& $Git @('init', '-q')
	& $Git @('commit', '-q', '--allow-empty', '-m', 'feat: first thing')
	& $Git @('tag', 'v0.1.0')
	foreach ($Subject in @('feat(ui): new panel', 'fix: crash on save', 'ci: pipeline tweak', 'Update readme', 'docs: authoring guide'))
	{
		& $Git @('commit', '-q', '--allow-empty', '-m', $Subject)
	}
	& $Git @('tag', 'v0.2.0')

	$First = Get-ReleaseNotes -RepoDir $Repo -Tag 'v0.1.0'
	Check 'the first release lists everything before it' ($First -match '(?m)^### Features\n- first thing \([0-9a-f]+\)$') $First
	$Second = Get-ReleaseNotes -RepoDir $Repo -Tag 'v0.2.0'
	Check 'later releases start at the previous tag' (-not $Second.Contains('first thing')) $Second
	Check 'features and fixes get sections' ($Second -match '### Features\n- new panel \(' -and $Second -match '### Fixes\n- crash on save \(') $Second
	Check 'other commits are kept, conventional or not' ($Second.Contains('- authoring guide (') -and $Second.Contains('- Update readme (')) $Second
	Check 'housekeeping is left out' (-not $Second.Contains('pipeline tweak')) $Second

	Write-Host 'Release assets'
	Check 'a source zip names its engine' ((Get-PackageEngineVersion 'Sample-1.2.3-UE5.8.zip') -eq '5.8')
	Check 'a docs zip is not a source zip' ($null -eq (Get-PackageEngineVersion 'SampleDocs-1.2.3-docs.zip'))
	Check 'a checksum is not a source zip' ($null -eq (Get-PackageEngineVersion 'Sample-1.2.3-UE5.8.zip.sha256'))

	Write-Host 'Docs bundles'
	Check 'slugs are kebab-case' ((ConvertTo-KebabCase 'KhaosFolderIcons') -eq 'khaos-folder-icons' -and (ConvertTo-KebabCase 'UIWidgets') -eq 'ui-widgets' -and (ConvertTo-KebabCase 'Khaos Docs 2') -eq 'khaos-docs-2')
	Check "glyphs leave out the maker's name" ((Get-DocsGlyph 'Khaos Palette' 'Khaos Systems') -eq 'PA' -and (Get-DocsGlyph 'Khaos Folder Icons' 'Khaos Systems') -eq 'FI' -and (Get-DocsGlyph 'Sample' 'Example Studio') -eq 'SA')
	Check 'glyphs are letters only, or none' ((Get-DocsGlyph 'Khaos 3D Tools' 'Khaos Systems') -ceq 'DT' -and $null -eq (Get-DocsGlyph 'Khaos 2048' 'Khaos Systems') -and $null -eq (Get-DocsGlyph 'X' 'Example Studio'))
	Check 'page URLs are kebab-case paths, the landing page at the root' ((Get-DocsPagePath 'Sample.md' 'Sample.md').Path -eq '' -and (Get-DocsPagePath 'Guides/First Steps.md' 'Sample.md').Path -eq 'guides/first-steps/')

	$Commit = '0123456789abcdef0123456789abcdef01234567'
	$DocsOut = Join-Paths $Temp 'docs-out'
	$BundleArguments = @{ PluginDir = $Plugin; OutDir = $DocsOut; Version = 'v1.2.3'; Ref = 'v1.2.3'; Commit = $Commit; Repo = 'Example/SampleDocs'; Engines = @('5.7', '5.8'); Released = '2026-11-09' }
	New-DocsFixture $Plugin
	$script:Bundle = $null
	$Annotations = @(Get-Annotations { $script:Bundle = New-DocsBundle @BundleArguments })
	$Bundle = $script:Bundle
	Check 'the bundle goes in section/slug/version, the slug from the repository name' ($Bundle.Folder -eq 'unreal/sample-docs/1.2.3' -and $Bundle.Dir -eq (Join-Paths $DocsOut 'unreal' 'sample-docs' '1.2.3'))
	Check 'pages and images keep their paths' (Same $Bundle.Files @('Guides/Setup.md', 'Images/Logo.svg', 'Images/Shot.png', 'Sample.md', 'docs.json')) ($Bundle.Files -join ', ')
	Check 'a file of another type is left out with a warning' ($Annotations.Count -eq 1 -and $Annotations[0] -like '::warning file=Content/Docs/Notes.txt,title=Docs::*.txt*') ($Annotations -join "`n")
	Check 'Markdown and SVG get LF line endings' ([Array]::IndexOf([IO.File]::ReadAllBytes("$($Bundle.Dir)\Sample.md"), [byte]13) -lt 0 -and [Array]::IndexOf([IO.File]::ReadAllBytes("$($Bundle.Dir)\Images\Logo.svg"), [byte]13) -lt 0)
	Check 'Markdown loses its byte order mark' ([IO.File]::ReadAllBytes("$($Bundle.Dir)\Guides\Setup.md")[0] -eq [byte][char]'#')

	$Golden = @'
{
  "base": "Content/Docs",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "description": "A sample plugin.",
  "fabUrl": "https://www.fab.com/listings/00000000-0000-0000-0000-000000000000",
  "glyph": "SK",
  "landing": "Sample.md",
  "name": "Example Sample Kit",
  "preview": false,
  "private": false,
  "ref": "v1.2.3",
  "released": "2026-11-09",
  "repo": "Example/SampleDocs",
  "schema": 1,
  "section": "unreal",
  "slug": "sample-docs",
  "supportUrl": "https://example.com/support",
  "unreal": {
    "engines": [
      "5.7",
      "5.8"
    ],
    "modules": [
      {
        "name": "SampleEditor",
        "type": "Editor"
      }
    ]
  },
  "version": "1.2.3"
}

'@.Replace("`r`n", "`n")
	$Written = [IO.File]::ReadAllText("$($Bundle.Dir)\docs.json")
	Check 'docs.json matches the golden copy: sorted keys, LF, fields from the .uplugin' ($Written -ceq $Golden) $Written

	# The name comes from FriendlyName, or the file when that is blank; the glyph drops the maker's first word only.
	$Named = Join-Paths $Temp 'docs-named'
	foreach ($Case in @(@{ Friendly = '  '; Name = 'Sample'; Glyph = 'SA' }, @{ Friendly = 'Sample Kit'; Name = 'Sample Kit'; Glyph = 'SK' }))
	{
		New-DocsFixture $Named
		$Path = "$Named\Sample.uplugin"
		[IO.File]::WriteAllText($Path, (Set-DescriptorField ([IO.File]::ReadAllText($Path)) 'FriendlyName' $Case.Friendly))
		$script:Other = $null
		$null = Get-Annotations { $script:Other = New-DocsBundle -PluginDir $Named -OutDir "$Temp\docs-named-out" -Ref 'main' -Commit $Commit -Repo 'Example/Named' -Released '2026-11-09' }
		Check "FriendlyName '$($Case.Friendly)' gives name '$($Case.Name)' and glyph $($Case.Glyph)" ($script:Other.Manifest.name -ceq $Case.Name -and $script:Other.Manifest.glyph -ceq $Case.Glyph -and $script:Other.Manifest.landing -ceq 'Sample.md') "$($script:Other.Manifest.name) $($script:Other.Manifest.glyph)"
	}

	$Zip = New-DocsBundleZip -BundleDir $Bundle.Dir -OutDir "$Temp\docs-zip"
	Check 'the release zip is <Repo>-<version>-docs.zip' ([IO.Path]::GetFileName($Zip) -eq 'SampleDocs-1.2.3-docs.zip')
	Check 'the zip has a .sha256 like a source zip' ([IO.File]::ReadAllText("$Zip.sha256") -eq "$(Get-FileSha256 $Zip)  SampleDocs-1.2.3-docs.zip`n")
	$Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
	try { $Entries = @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
	Check 'zip entries sit at section/slug/version' (Same $Entries ($Bundle.Files | ForEach-Object { "unreal/sample-docs/1.2.3/$_" })) ($Entries -join ', ')

	$Hashes = @($Bundle.Files | ForEach-Object { Get-FileSha256 (Join-Paths $Bundle.Dir $_) })
	$ZipHash = Get-FileSha256 $Zip
	Start-Sleep -Milliseconds 1100
	(Get-Item "$Plugin\Content\Docs\Sample.md").LastWriteTime = Get-Date
	$null = Get-Annotations { $script:Bundle = New-DocsBundle @BundleArguments }
	$Zip = New-DocsBundleZip -BundleDir $Bundle.Dir -OutDir "$Temp\docs-zip"
	Check 'the same docs give the same bundle, byte for byte' ((Same @($Bundle.Files | ForEach-Object { Get-FileSha256 (Join-Paths $Bundle.Dir $_) }) $Hashes) -and (Get-FileSha256 $Zip) -eq $ZipHash)

	$Note = Get-DocsReleaseNote $Zip
	Check 'the release notes give the docs zip its checksum' ($Note -ceq "### Docs`n`n``SampleDocs-1.2.3-docs.zip``: this version's docs bundle for docs.khaos.systems, not a Fab package. SHA-256 ``$ZipHash``.")
	Check 'notes without a docs section get one at the end' ((Set-DocsReleaseNote "Notes`n`n### Packages`n`n| a |`n" $Note) -ceq "Notes`n`n### Packages`n`n| a |`n`n$Note")
	Check 'a docs section is replaced where it is' ((Set-DocsReleaseNote "Notes`r`n`r`n### Docs`r`n`r`nold`r`n`r`n### Later`r`n`r`nkept" $Note) -ceq "Notes`n`n$Note`n`n### Later`n`nkept")
	Check 'notes with this docs section stay as they are' ((Set-DocsReleaseNote "Notes`n`n$Note" $Note) -ceq "Notes`n`n$Note")

	$Short = $BundleArguments.Clone()
	$Short.Commit = 'abc123'
	$script:Caught = $null
	try { New-DocsBundle @Short | Out-Null } catch { $script:Caught = $_.Exception.Message }
	Check 'a short commit is refused' ($script:Caught -like 'Commit must be a full 40-character SHA*') "$script:Caught"

	$Preview = $BundleArguments.Clone()
	$Preview.Version = ''
	$Preview.Ref = 'main'
	$script:PreviewBundle = $null
	$null = Get-Annotations { $script:PreviewBundle = New-DocsBundle @Preview }
	$PreviewJson = [IO.File]::ReadAllText("$($script:PreviewBundle.Dir)\docs.json") | ConvertFrom-Json
	Check 'a preview goes in a preview folder, with no version' ($script:PreviewBundle.Folder -eq 'unreal/sample-docs/preview' -and $PreviewJson.preview -eq $true -and $null -eq $PreviewJson.version -and $PreviewJson.ref -eq 'main')
	$Threw = $false
	try { New-DocsBundleZip -BundleDir $script:PreviewBundle.Dir -OutDir "$Temp\docs-zip" | Out-Null } catch { $Threw = $true }
	Check 'a preview is never zipped for a release' $Threw

	$Store = Join-Paths $Temp 'docs-store'
	New-DocsFixture $Store
	$Path = "$Store\Sample.uplugin"
	[IO.File]::WriteAllText($Path, (Set-DescriptorField (Remove-DescriptorField ([IO.File]::ReadAllText($Path)) 'FabURL') 'MarketplaceURL' 'https://example.com/market'))
	$script:Other = $null
	$null = Get-Annotations { $script:Other = New-DocsBundle -PluginDir $Store -OutDir "$Temp\docs-store-out" -Ref 'main' -Commit $Commit -Repo 'Example/Store' -Released '2026-11-09' }
	Check 'fabUrl falls back to MarketplaceURL' ($script:Other.Manifest.fabUrl -eq 'https://example.com/market')
	[IO.File]::WriteAllText($Path, (Set-DescriptorField ([IO.File]::ReadAllText($Path)) 'FabURL' 'https://example.com/fab'))
	$null = Get-Annotations { $script:Other = New-DocsBundle -PluginDir $Store -OutDir "$Temp\docs-store-out" -Ref 'main' -Commit $Commit -Repo 'Example/Store' -Released '2026-11-09' }
	Check 'fabUrl takes FabURL over MarketplaceURL' ($script:Other.Manifest.fabUrl -eq 'https://example.com/fab')

	# What a Windows editor or shell may save, a SupportURL that is no URL and a FabURL that ends in a line break.
	$Edge = Join-Paths $Temp 'docs-edge'
	New-DocsFixture $Edge
	$Path = "$Edge\Sample.uplugin"
	$Text = Set-DescriptorField ([IO.File]::ReadAllText($Path)) 'SupportURL' 'support@example.com'
	[IO.File]::WriteAllText($Path, [regex]::Replace($Text, '"FabURL": "[^"]*"', '"FabURL": "https://example.com/fab\n"'))
	[IO.File]::WriteAllText("$Edge\Content\Docs\Images\Wide.svg", "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'></svg>`n", (New-Object System.Text.UnicodeEncoding $false, $true))
	New-TestFile "$Edge\Content\Docs\Upper.MD" "# Upper`n"
	[IO.File]::WriteAllText("$Edge\Content\Docs\Wide.md", "# Wide`r`n`r`nCaf$([char]0xE9).`r`n", (New-Object System.Text.UnicodeEncoding $false, $true))
	New-TestFile "$Edge\Content\Docs\Mac.md" "# Mac`r`rOld line endings.`r"
	$script:Other = $null
	$Annotations = @(Get-Annotations { $script:Other = New-DocsBundle -PluginDir $Edge -OutDir "$Temp\docs-edge-out" -Ref 'main' -Commit $Commit -Repo 'Example/Edge' -Released '2026-11-09' })
	Check 'a SupportURL that is not an http(s) URL is left out, with a warning' ($null -eq $script:Other.Manifest.supportUrl -and @($Annotations | Where-Object { $_ -like '::warning file=Sample.uplugin,title=Docs::SupportURL is not an http(s) URL*' }).Count -eq 1) ($Annotations -join "`n")
	Check 'so is a FabURL that ends in a line break' ($null -eq $script:Other.Manifest.fabUrl -and @($Annotations | Where-Object { $_ -like '::warning file=Sample.uplugin,title=Docs::FabURL is not an http(s) URL*' }).Count -eq 1) ($Annotations -join "`n")
	Check 'a UTF-16 SVG is left out, with a warning' (@($Annotations | Where-Object { $_ -like '::warning file=Content/Docs/Images/Wide.svg,title=Docs::*UTF-16*' }).Count -eq 1) ($Annotations -join "`n")
	Check 'a page ending in .MD is left out, with a warning' ((Same $script:Other.Files @('Guides/Setup.md', 'Images/Logo.svg', 'Images/Shot.png', 'Mac.md', 'Sample.md', 'Wide.md', 'docs.json')) -and @($Annotations | Where-Object { $_ -like '::warning file=Content/Docs/Upper.MD,title=Docs::*in lowercase*' }).Count -eq 1) ($Annotations -join "`n")
	Check 'a UTF-16 page becomes UTF-8' (Same ([IO.File]::ReadAllBytes("$($script:Other.Dir)\Wide.md")) ((New-Object System.Text.UTF8Encoding $false).GetBytes("# Wide`n`nCaf$([char]0xE9).`n")))
	Check 'CR line endings become LF' ([IO.File]::ReadAllText("$($script:Other.Dir)\Mac.md") -ceq "# Mac`n`nOld line endings.`n")
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $script:Other.Dir }
	Check 'and then they pass' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	Write-Host 'Docs rules'
	$script:Result = $null
	$Annotations = Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $Bundle.Dir }
	Check 'the sample docs pass every rule' ($Annotations.Count -eq 0 -and $script:Result.Errors -eq 0) ($Annotations -join "`n")

	# A private repository's docs: the sample without its link to a source file.
	$PrivatePlugin = Join-Paths $Temp 'docs-private-src'
	New-DocsFixture $PrivatePlugin
	$Page = "$PrivatePlugin\Content\Docs\Sample.md"
	[IO.File]::WriteAllText($Page, [IO.File]::ReadAllText($Page).Replace('[the source](../../Source/SampleEditor/Private/SampleEditor.cpp), ', ''))
	$PrivateArguments = $BundleArguments.Clone()
	$PrivateArguments.PluginDir = $PrivatePlugin
	$PrivateArguments.OutDir = Join-Paths $Temp 'docs-private'
	$PrivateArguments.Private = $true
	$script:PrivateBundle = $null
	$null = Get-Annotations { $script:PrivateBundle = New-DocsBundle @PrivateArguments }
	$script:Result = $null
	$Annotations = Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $script:PrivateBundle.Dir }
	Check "a private repository's docs pass, with page links, anchors, images and a reference" ($Annotations.Count -eq 0 -and $script:Result.Errors -eq 0 -and $script:PrivateBundle.Manifest.private) ($Annotations -join "`n")

	$Rules = @(
		@{ Name = 'a page without an H1'; Text = "Intro.`n`n## Part`n"; Line = 1; Expect = 'No H1' }
		@{ Name = 'a second H1'; Text = "# One`n`n# Two`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, underlined'; Text = "# One`n`nTwo`n===`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, in a list item'; Text = "# One`n`n- # Two`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, underlined in a list item'; Text = "# One`n`n- Two`n  ===`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, in a quote'; Text = "# One`n`n> # Two`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'content before the H1'; Text = "![Logo](Images/Shot.png)`n`n# Title`n"; Line = 1; Expect = 'must come first' }
		@{ Name = 'a definition before the H1'; Text = "[home]: Sample.md`n`n# Title`n`nSee [home].`n"; Line = 1; Expect = 'must come first' }
		@{ Name = 'a footnote before the H1'; Text = "[^1]: A note.`n`n# Title`n"; Line = 1; Expect = 'must come first' }
		@{ Name = 'an H1 in a list item'; Text = "- # Title`n`nText.`n"; Line = 1; Expect = 'inside a quote, list item or footnote' }
		@{ Name = 'an H1 in a quote'; Text = "> # Title`n`nText.`n"; Line = 1; Expect = 'inside a quote, list item or footnote' }
		@{ Name = 'an empty H1'; Text = "#`n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'an H1 of closing #s'; Text = "# #`n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'an H1 of spaces'; Text = "#    `n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'an H1 of an image with no alt text'; Text = "# ![](Images/Shot.png)`n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'an H1 of a link with no text'; Text = "# [](Sample.md)`n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'an underlined H1 with no text'; Text = "[](Sample.md)`n===`n`nText.`n"; Line = 1; Expect = 'The H1 is empty' }
		@{ Name = 'a skipped heading level'; Text = "# Title`n`n### Deep`n"; Line = 3; Expect = 'skips a level, H1 to H3' }
		@{ Name = 'a skipped level after going back up'; Text = "# Title`n`n## A`n`n### B`n`n## C`n`n#### D`n"; Line = 9; Expect = 'skips a level, H2 to H4' }
		@{ Name = 'a skipped level after a table and a thematic break'; Text = "# Title`n`nSettings:`n| Name | Default |`n| --- | --- |`n| a | b |`n---`n### Details`n"; Line = 8; Expect = 'skips a level, H1 to H3' }
		@{ Name = 'a skipped level after a table in a quote'; Text = "# Title`n`n> | a | b |`n> | - | - |`n> | 1 | 2 |`n> ---`n> ### D`n"; Line = 7; Expect = 'skips a level, H1 to H3' }
		@{ Name = 'a second H1 under a line that only looks like a table header, as it carries on lazily'; Text = "# Title`n`n> x`na | b`n> --|--`n> ===`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a broken link in a table cell';Text = "# Title`n`n| a | b |`n|---|---|`n| ok | [it](Missing.md) |`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'raw HTML in a table row without pipes'; Text = "# Title`n`n| a |`n|---|`n<b>x</b>`n"; Line = 5; Expect = 'Raw HTML is not allowed: <b>' }
		@{ Name = 'raw HTML with a backtick in an attribute'; Text = ("# Title`n`n" + '<b title="`">x</b> and `y`.' + "`n"); Line = 3; Expect = 'Raw HTML is not allowed: <b title="`">' }
		@{ Name = 'a broken link whose anchor holds a backtick'; Text = ("# Title`n`n" + 'See [it](Missing.md#a`b) and `x`.' + "`n"); Line = 3; Expect = 'is broken' }
		@{ Name = 'raw HTML'; Text = "# Title`n`nA line<br>break.`n"; Line = 3; Expect = 'Raw HTML is not allowed: <br>' }
		@{ Name = 'an HTML block'; Text = "# Title`n`n<details>`n<summary>More</summary>`n</details>`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'an HTML block start with no end'; Text = "# Title`n`n<div`n"; Line = 3; Expect = 'Raw HTML is not allowed: <div' }
		@{ Name = 'an HTML comment'; Text = "# Title`n`n<!-- note -->`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'a C++ type outside backticks'; Text = "# Title`n`nTakes a TArray<FString>.`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'a C++ type in a heading'; Text = "# Title`n`n## Using TArray<FString>`n"; Line = 3; Expect = 'Raw HTML is not allowed: <FString>' }
		@{ Name = 'raw HTML before an autolink'; Text = "# Title`n`nMail <!x@example.com>.`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'raw HTML after a label that is no definition'; Text = "# Title`n`n[Optional]: <b>bold</b>`n"; Line = 3; Expect = 'Raw HTML is not allowed: <b>' }
		@{ Name = 'raw HTML on a lazy line'; Text = "# Title`n`n> A quote`n    <b>bold</b>`n"; Line = 4; Expect = 'Raw HTML' }
		@{ Name = 'a link with no target'; Text = "# Title`n`nSee [x]().`n"; Line = 3; Expect = 'Link with no target.' }
		@{ Name = 'a link to a missing page, spelled with an entity'; Text = "# Title`n`nSee [it](Missing&#46;md).`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a % that starts no escape, in a link'; Text = "# Title`n`nSee [it](../../Source/100%.h).`n"; Line = 3; Expect = 'is not a valid link' }
		@{ Name = 'a % that starts no escape, in an image'; Text = "# Title`n`n![Shot](Images/100%.png)`n"; Line = 3; Expect = 'is not a valid link' }
		@{ Name = 'escapes that are not UTF-8'; Text = "# Title`n`nSee [it](Sample%C3.md).`n"; Line = 3; Expect = 'is not a valid link' }
		@{ Name = 'a broken link'; Text = "# Title`n`nSee [it](Missing.md).`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a broken link with a title'; Text = "# Title`n`nSee [it](Missing.md `"Title`").`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a missing image with a title'; Text = "# Title`n`n![it](Images/None.png 'Title')`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'an image with no path'; Text = "# Title`n`n![x]()`n"; Line = 3; Expect = 'An image needs the path of a file' }
		@{ Name = 'a broken link on a later line of a paragraph'; Text = "# Title`n`nOne`ntwo [it](Missing.md#part)`n"; Line = 4; Expect = 'is broken' }
		@{ Name = 'a broken link in a heading'; Text = "# Title`n`n## See [it](Missing.md)`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a broken link after a label that is no definition'; Text = "# Title`n`n[Required]: The asset, see [it](Missing.md).`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a broken link in a footnote'; Text = "# Title`n`nText[^1].`n`n[^1]: See [it](Missing.md).`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'a broken link in the second paragraph of a footnote'; Text = "# Title`n`nText[^1].`n`n[^1]: A note.`n`n    See [it](Missing.md).`n"; Line = 7; Expect = 'is broken' }
		@{ Name = 'a broken reference link'; Text = "# Title`n`nSee [it][x].`n`n[x]: Missing.md`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'a definition with its destination on the next line'; Text = "# Title`n`nSee [it][x].`n`n[x]:`n  Missing.md`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'a definition in a quote'; Text = "# Title`n`n> See [it][x].`n>`n> [x]: Missing.md`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'a definition in a list item'; Text = "# Title`n`n- [x]: Missing.md`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a link with the wrong case'; Text = "# Title`n`nSee [setup](guides/setup.md).`n"; Line = 3; Expect = 'wrong case: the file is Guides/Setup.md' }
		@{ Name = 'an image with the wrong case'; Text = "# Title`n`n![Shot](images/shot.png)`n"; Line = 3; Expect = 'wrong case: the file is Images/Shot.png' }
		@{ Name = 'a remote image'; Text = "# Title`n`n![Shot](https://example.com/shot.png)`n"; Line = 3; Expect = 'loads no remote images' }
		@{ Name = 'an image by reference'; Text = "# Title`n`n![Shot][s]`n`n[s]: Images/Shot.png`n"; Line = 3; Expect = 'Write images as ![alt](path)' }
		@{ Name = 'a remote image by reference'; Text = "# Title`n`n![Shot][s]`n`n[s]: https://example.com/shot.png`n"; Line = 3; Expect = 'Write images as ![alt](path)' }
		@{ Name = "an image by reference's definition, in a private repository"; Text = "# Title`n`n![Shot][s]`n`n[s]: Images/Shot.png`n"; Line = 5; Expect = 'is private'; Private = $true }
		@{ Name = 'a remote image inside a link'; Text = "# Title`n`n[![b](https://example.com/b.svg)](https://example.com)`n"; Line = 3; Expect = 'loads no remote images' }
		@{ Name = 'a remote image whose alt text holds a link'; Text = "# Title`n`n![a [b](Sample.md) c](https://example.com/x.png)`n"; Line = 3; Expect = 'loads no remote images' }
		@{ Name = 'a missing image whose alt text holds a link'; Text = "# Title`n`n![a [b](Sample.md) c](Images/missing.png)`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'an image that is a folder'; Text = "# Title`n`n![a](Images)`n"; Line = 3; Expect = 'Image Images is broken' }
		@{ Name = 'an image that is a folder, with a slash'; Text = "# Title`n`n![a](Images/)`n"; Line = 3; Expect = 'Image Images/ is broken' }
		@{ Name = 'a root-relative image'; Text = "# Title`n`n![Shot](/Images/Shot.png)`n"; Line = 3; Expect = 'is root-relative. Write it relative to this page.' }
		@{ Name = 'an image outside the bundle'; Text = "# Title`n`n![Icon](../../Resources/Icon128.png)`n"; Line = 3; Expect = 'outside the docs folder' }
		@{ Name = 'an image one folder above the bundle'; Text = "# Title`n`n![Icon](../Icon.png)`n"; Line = 3; Expect = 'outside the docs folder' }
		@{ Name = 'a missing image'; Text = "# Title`n`n![Shot](Images/None.png)`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a root-relative link'; Text = "# Title`n`nSee [the docs](/unreal/sample-docs/).`n"; Line = 3; Expect = 'root-relative' }
		@{ Name = 'a link of another scheme'; Text = "# Title`n`nSee [files](ftp://example.com/x).`n"; Line = 3; Expect = 'only http(s), mailto, #anchor and relative links' }
		@{ Name = 'an autolink of another scheme'; Text = "# Title`n`nSee <ftp://example.com/x>.`n"; Line = 3; Expect = 'only http(s), mailto' }
		@{ Name = 'a link out of the repository'; Text = "# Title`n`nSee [x](../../../../x.txt).`n"; Line = 3; Expect = 'outside the repository' }
		@{ Name = 'a link from a private repository to a source file'; Text = "# Title`n`nSee [it](../../Source/SampleEditor/Private/SampleEditor.cpp).`n"; Line = 3; Expect = 'is private'; Private = $true }
		@{ Name = 'a link from a private repository to an image file'; Text = "# Title`n`nSee [it](Images/Shot.png).`n"; Line = 3; Expect = 'is private'; Private = $true }
	)
	foreach ($Rule in $Rules)
	{
		$Dir = $Bundle.Dir
		if ($Rule.Private) { $Dir = $script:PrivateBundle.Dir }
		New-TestFile "$Dir\Bad.md" $Rule.Text
		$script:Result = $null
		$Annotations = Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $Dir }
		Remove-Item "$Dir\Bad.md"
		$Hit = @($Annotations | Where-Object { $_.StartsWith("::error file=Content/Docs/Bad.md,line=$($Rule.Line),title=Docs::") -and $_.Contains($Rule.Expect) })
		Check "reports $($Rule.Name)" ($Hit.Count -gt 0 -and $script:Result.Errors -gt 0) ($Annotations -join "`n")
	}

	# Markdown the site renders, which a line-by-line reading could get wrong.
	$Fence = '```'
	$Valid = @(
		@{ Name = 'a fence that only a fence indented at most three spaces closes'; Text = (@('# Title', '', $Fence, "        $Fence", '<div>', $Fence, '') -join "`n") }
		@{ Name = 'a fence in a quote'; Text = (@('# Title', '', "> ${Fence}ini", '> # comment', '> <div>', "> $Fence", '') -join "`n") }
		@{ Name = 'a fence opened on the first line of a list item'; Text = (@('# Title', '', "- $Fence", '  # comment', '  <div>', "  $Fence", '') -join "`n") }
		@{ Name = 'indented code in a list item'; Text = "# Title`n`n-     <div>`n" }
		@{ Name = 'a < that opens no HTML'; Text = "# Title`n`nUse a <? b, or a <!-- c, to compare.`n" }
		@{ Name = 'a title on the line after a definition'; Text = "# Title`n`nSee [it][x].`n`n[x]: Sample.md`n  `"A <b> title`"`n" }
		@{ Name = 'a label that is no definition'; Text = "# Title`n`n[Note]: Missing.md for now.`n" }
		@{ Name = 'an H1 of an image with alt text'; Text = "# ![Logo](Images/Shot.png)`n`nText.`n" }
		@{ Name = 'an H1 with closing #s'; Text = "# Title ##`n" }
		@{ Name = 'a page and an image with spaces in their names, linked with %20'; Text = "# Title`n`nSee [it](First%20Steps.md) and ![it](Images/My%20Shot.png).`n"; Files = @('First Steps.md', 'Images/My Shot.png') }
		@{ Name = 'a page link spelled with an entity, in a private repository'; Text = "# Title`n`nSee [it](Guides/Setup&#46;md).`n"; Private = $true }
		@{ Name = 'a list number in another script'; Text = "# Title`n`nSteps:`n$([char]0xFF11). Enable the plugin.`n" }
		@{ Name = 'brackets after a ! that are no image'; Text = "# Title`n`nWow![not a reference] here.`n" }
		@{ Name = 'a footnote, in a private repository'; Text = "# Title`n`nText[^1].`n`n[^1]: A note.`n"; Private = $true }
		@{ Name = 'a thematic break under a table, then an H4 under an H3'; Text = "# Title`n`n## A`n`n### B`n`n| x | y |`n|---|---|`n| 1 | 2 |`n---`n#### C`n" }
		@{ Name = '=== under a table, as a row'; Text = "# Title`n`n| Name | Default |`n| --- | --- |`n| a | b |`n===`n" }
		@{ Name = 'a link split across table cells'; Text = "# Title`n`n| a | b |`n|---|---|`n| [x | y](Missing.md) |`n" }
		@{ Name = 'a table of one column, with a colon'; Text = "# Title`n`nName`n:---`n" }
		@{ Name = 'a pointed link target that looks like a tag'; Text = "# Title`n`nSee [it](<First Steps.md>).`n"; Files = @('First Steps.md') }
	)
	foreach ($Case in $Valid)
	{
		$Dir = $Bundle.Dir
		if ($Case.Private) { $Dir = $script:PrivateBundle.Dir }
		New-TestFile "$Dir\Good.md" $Case.Text
		$Extras = @($Case.Files | Where-Object { $_ } | ForEach-Object { Join-Paths $Dir $_ })
		foreach ($Extra in $Extras)
		{
			if ($Extra.EndsWith('.png')) { New-TestPng $Extra } else { New-TestFile $Extra "# Extra`n" }
		}
		$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Dir }
		Remove-Item "$Dir\Good.md"
		foreach ($Extra in $Extras) { Remove-Item -LiteralPath $Extra }
		Check "passes $($Case.Name)" ($Annotations.Count -eq 0) ($Annotations -join "`n")
	}

	New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](../../Source/SampleEditor/Private/SampleEditor.cpp).`n"
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
	Remove-Item "$($Bundle.Dir)\Bad.md"
	Check 'a public repository may link its other files' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](Missing.md).`n"
	$script:Result = $null
	$Annotations = @(Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $Bundle.Dir -AsWarnings })
	Remove-Item "$($Bundle.Dir)\Bad.md"
	Check 'with -AsWarnings problems are warnings, and still counted' ($Annotations.Count -eq 1 -and $Annotations[0] -like '::warning file=Content/Docs/Bad.md,line=3,*' -and $script:Result.Errors -eq 1) ($Annotations -join "`n")

	$Json = [IO.File]::ReadAllText("$($Bundle.Dir)\docs.json")
	$JsonRules = @(
		@{ Find = '"schema": 1'; Replace = '"schema": 2'; Expect = '"schema" must be 1.' }
		@{ Find = '"section": "unreal"'; Replace = '"section": "web"'; Expect = "section 'web' is not one the docs site knows" }
		@{ Find = '"slug": "sample-docs"'; Replace = '"slug": "Bad_Slug"'; Expect = "slug 'Bad_Slug' must be lowercase kebab-case." }
		@{ Find = '"released": "2026-11-09"'; Replace = '"released": "11/09/2026"'; Expect = '"released" must be a date' }
		@{ Find = '"commit": "[0-9a-f]+"'; Replace = '"commit": "abc123"'; Expect = '"commit" must be a full 40-character SHA.' }
		@{ Find = '"repo": "Example/SampleDocs"'; Replace = '"repo": "x"'; Expect = '"repo" must be owner/name.' }
		@{ Find = '"version": "1.2.3"'; Replace = '"version": "v1.2.3"'; Expect = "version 'v1.2.3' is not a release version" }
		@{ Find = '"preview": false'; Replace = '"preview": true'; Expect = 'a preview has "version": null.' }
		@{ Find = '"private": false'; Replace = '"private": "no"'; Expect = '"private" must be true or false.' }
		@{ Find = '"supportUrl": "[^"]*"'; Replace = '"supportUrl": "support@example.com"'; Expect = '"supportUrl" must be an http(s) URL or null.' }
		@{ Find = '"fabUrl": "[^"]*"'; Replace = '"fabUrl": "www.fab.com"'; Expect = '"fabUrl" must be an http(s) URL or null.' }
		@{ Find = '"glyph": "SK"'; Replace = '"glyph": "SAM"'; Expect = '"glyph" must be one or two letters.' }
		@{ Find = '"glyph": "SK"'; Replace = '"glyph": "3D"'; Expect = '"glyph" must be one or two letters.' }
		@{ Find = '"description": "A sample plugin."'; Replace = '"description": " "'; Expect = '"description" is empty.' }
		@{ Find = '"released": "2026-11-09"'; Replace = ('"released": "2026-11-0' + [char]0x0669 + '"'); Expect = '"released" must be a date' }
		@{ Find = '"released": "2026-11-09"'; Replace = '"released": "2026-11-09\n"'; Expect = '"released" must be a date' }
		@{ Find = '"schema": 1'; Replace = '"schema": "1"'; Expect = '"schema" must be 1.' }
		@{ Find = '"schema": 1'; Replace = '"schema": true'; Expect = '"schema" must be 1.' }
		@{ Find = '"name": "Example Sample Kit"'; Replace = '"name": 5'; Expect = '"name" must be a string.' }
		@{ Find = '"name": "Example Sample Kit"'; Replace = '"name": ["Example Sample Kit"]'; Expect = '"name" must be a string.' }
		@{ Find = '"version": "1.2.3"'; Replace = '"version": ["1.2.3"]'; Expect = "version '1.2.3' is not a release version" }
		@{ Find = '"preview": false'; Replace = '"preview": "no"'; Expect = '"preview" must be true or false.' }
		@{ Find = '"5\.8"'; Replace = '5.8'; Expect = '"unreal.engines" must be a list of versions' }
		@{ Find = '"type": "Editor"'; Replace = '"kind": "Editor"'; Expect = '"unreal.modules" must be a list' }
	)
	foreach ($Rule in $JsonRules)
	{
		$Edited = [regex]::Replace($Json, $Rule.Find, $Rule.Replace)
		Write-Utf8File "$($Bundle.Dir)\docs.json" $Edited
		$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
		Check "reports docs.json: $($Rule.Expect)" ($Edited -cne $Json -and @($Annotations | Where-Object { $_.StartsWith('::error title=Docs::') -and $_.Contains($Rule.Expect) }).Count -eq 1) ($Annotations -join "`n")
	}
	$Required = @('schema', 'section', 'slug', 'name', 'description', 'landing', 'version', 'preview', 'released', 'repo', 'private', 'ref', 'commit', 'base')
	foreach ($Key in $Required)
	{
		Write-Utf8File "$($Bundle.Dir)\docs.json" $Json.Replace("`"$Key`":", "`"x$Key`":")
		$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
		Check "reports docs.json without `"$Key`"" (@($Annotations | Where-Object { $_.StartsWith('::error title=Docs::') -and $_.Contains("docs.json has no `"$Key`".") }).Count -eq 1) ($Annotations -join "`n")
	}
	# The site reads keys in their exact case.
	Write-Utf8File "$($Bundle.Dir)\docs.json" $Json.Replace('"schema":', '"Schema":').Replace('"landing":', '"Landing":').Replace('"version":', '"Version":')
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
	Check 'reports docs.json keys in the wrong case as missing' (@($Annotations | Where-Object { $_ -match 'docs.json has no "(schema|landing|version)"\.' }).Count -eq 3) ($Annotations -join "`n")
	Write-Utf8File "$($Bundle.Dir)\docs.json" $Json

	$FileRules = @(
		@{ Name = 'an image over 5 MB'; Add = { New-TestPng "$($Bundle.Dir)\Images\Big.png" 5000001 }; Expect = 'file=Content/Docs/Images/Big.png,title=Docs::The image is over the 5 MB limit (5,000,001 bytes).' }
		@{ Name = 'a bundle over 25 MB'; Add = { foreach ($N in 1..6) { New-TestPng "$($Bundle.Dir)\Images\Part$N.png" 4500000 } }; Expect = 'title=Docs::The docs are over the 25 MB limit (27,0' }
		@{ Name = 'an image that is not one'; Add = { New-TestFile "$($Bundle.Dir)\Images\Text.png" 'png' }; Expect = 'file=Content/Docs/Images/Text.png,title=Docs::The docs site cannot read this image: it is not a PNG, JPEG, GIF or WebP file.' }
		@{ Name = 'a Git LFS pointer'; Add = { New-TestFile "$($Bundle.Dir)\Images\Lfs.png" "version https://git-lfs.github.com/spec/v1`noid sha256:0123`nsize 12`n" }; Expect = 'file=Content/Docs/Images/Lfs.png,title=Docs::This is a Git LFS pointer' }
		@{ Name = 'an SVG with no size'; Add = { New-TestFile "$($Bundle.Dir)\Images\NoSize.svg" "<svg xmlns='http://www.w3.org/2000/svg'>`n</svg>`n" }; Expect = 'file=Content/Docs/Images/NoSize.svg,title=Docs::The docs site cannot read the size of this SVG' }
		@{ Name = 'an SVG whose tag starts after 1000 bytes'; Add = { New-TestFile "$($Bundle.Dir)\Images\Late.svg" ("<!-- " + ('x' * 1000) + " -->`n<svg viewBox='0 0 1 1'></svg>`n") }; Expect = 'file=Content/Docs/Images/Late.svg,title=Docs::The docs site cannot read this SVG' }
		@{ Name = 'a UTF-16 SVG in a bundle'; Add = { [IO.File]::WriteAllText("$($Bundle.Dir)\Images\Wide.svg", "<svg viewBox='0 0 1 1'></svg>`n", (New-Object System.Text.UnicodeEncoding $false, $true)) }; Expect = 'file=Content/Docs/Images/Wide.svg,title=Docs::The SVG is saved as UTF-16' }
		@{ Name = 'a link to a folder named like a page'; Add = { New-TestFile "$($Bundle.Dir)\Dir.md\Page.md" "# Page`n"; New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](Dir.md).`n" }; Expect = 'file=Content/Docs/Bad.md,line=3,title=Docs::Link Dir.md is broken' }
		@{ Name = 'a landing page that is a folder'; Add = { Remove-Item "$($Bundle.Dir)\Sample.md"; New-TestFile "$($Bundle.Dir)\Sample.md\Page.md" "# Page`n" }; Expect = 'The landing page Content/Docs/Sample.md is missing' }
		# PowerShell's -ceq takes each of these pairs for the same name; git and the site do not.
		@{ Name = 'a link to a sharp s, beside a file spelled ss'; Add = { New-TestFile "$($Bundle.Dir)\Strasse.md" "# Strasse`n"; New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](Stra$([char]0xDF)e.md).`n" }; Expect = "line=3,title=Docs::Link Stra$([char]0xDF)e.md is broken" }
		@{ Name = 'a link to a composed accent, beside a file with a combining one'; Add = { New-TestFile "$($Bundle.Dir)\Cafe$([char]0x301).md" "# Cafe`n"; New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](Caf$([char]0xE9).md).`n" }; Expect = "line=3,title=Docs::Link Caf$([char]0xE9).md is broken" }
		@{ Name = 'an image with a soft hyphen in its name'; Add = { New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`n![it](Images/Sh$([char]0xAD)ot.png)`n" }; Expect = "line=3,title=Docs::Image Images/Sh$([char]0xAD)ot.png is broken" }
		@{ Name = 'a file type a bundle cannot hold'; Add = { New-TestFile "$($Bundle.Dir)\notes.txt" 'x' }; Expect = 'file=Content/Docs/notes.txt,title=Docs::Only .md pages' }
		@{ Name = 'a page ending in .MD'; Add = { New-TestFile "$($Bundle.Dir)\Upper.MD" "# Upper`n" }; Expect = 'file=Content/Docs/Upper.MD,title=Docs::A page must end in .md, in lowercase' }
		@{ Name = 'CRLF in a bundle'; Add = { New-TestFile "$($Bundle.Dir)\Crlf.md" "# Title`r`n" }; Expect = 'file=Content/Docs/Crlf.md,title=Docs::CR line endings' }
		@{ Name = 'a page that is not UTF-8'; Add = { [IO.File]::WriteAllBytes("$($Bundle.Dir)\Ansi.md", [byte[]](0x23, 0x20, 0x41, 0x0A, 0x0A, 0x93, 0x41, 0x94, 0x0A)) }; Expect = 'file=Content/Docs/Ansi.md,title=Docs::The page is not UTF-8' }
		@{ Name = 'a UTF-16 page in a bundle'; Add = { [IO.File]::WriteAllText("$($Bundle.Dir)\Wide.md", "# Wide`n", (New-Object System.Text.UnicodeEncoding $false, $true)) }; Expect = 'file=Content/Docs/Wide.md,title=Docs::The page is not UTF-8' }
		@{ Name = 'a missing landing page'; Add = { Rename-Item "$($Bundle.Dir)\Sample.md" 'Landing.md' }; Expect = 'The landing page Content/Docs/Sample.md is missing' }
		@{ Name = 'a landing page with the wrong case'; Add = { Rename-Item "$($Bundle.Dir)\Sample.md" 'sample.md' }; Expect = 'file=Content/Docs/sample.md,title=Docs::The landing page must be named Sample.md' }
		@{ Name = 'a page whose URL the site keeps for versions'; Add = { New-TestFile "$($Bundle.Dir)\Releases.md" "# Releases`n" }; Expect = 'file=Content/Docs/Releases.md,title=Docs::Its URL would start with /releases/' }
		@{ Name = 'a page whose URL the site keeps for previews'; Add = { New-TestFile "$($Bundle.Dir)\Preview.md" "# Preview`n" }; Expect = 'file=Content/Docs/Preview.md,title=Docs::Its URL would start with /preview/' }
		@{ Name = 'a folder named like a version'; Add = { New-TestFile "$($Bundle.Dir)\V2\Migration.md" "# Migration`n" }; Expect = 'file=Content/Docs/V2/Migration.md,title=Docs::Its URL would start with /v2/' }
		@{ Name = 'a page name with no letters or digits'; Add = { New-TestFile "$($Bundle.Dir)\__.md" "# Underscores`n" }; Expect = 'file=Content/Docs/__.md,title=Docs::A part of its path has no letters or digits' }
		@{ Name = 'two pages with one URL'; Add = { New-TestFile "$($Bundle.Dir)\Getting Started.md" "# A`n"; New-TestFile "$($Bundle.Dir)\getting-started.md" "# B`n" }; Expect = 'file=Content/Docs/getting-started.md,title=Docs::It gets the same URL as Content/Docs/Getting Started.md: /unreal/sample-docs/getting-started/.' }
	)
	foreach ($Rule in $FileRules)
	{
		$Clean = Join-Paths $Temp 'docs-clean'
		Reset-Directory $Clean
		Copy-Item "$($Bundle.Dir)\*" $Clean -Recurse
		& $Rule.Add
		$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
		Reset-Directory $Bundle.Dir
		Copy-Item "$Clean\*" $Bundle.Dir -Recurse
		Check "reports $($Rule.Name)" (@($Annotations | Where-Object { $_.StartsWith('::error ') -and $_.Contains($Rule.Expect) }).Count -eq 1) ($Annotations -join "`n")
	}

	New-TestPng "$($Bundle.Dir)\Images\Exact.png" 5000000
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
	Remove-Item "$($Bundle.Dir)\Images\Exact.png"
	Check 'an image of exactly 5 MB passes' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	# Images the site reads, whatever their extension: by the bytes they start with, and SVGs by their size.
	$Readable = @{
		'Jpeg.jpg' = [byte[]](0xFF, 0xD8, 0xFF, 0xE0)
		'Gif.gif' = [Text.Encoding]::ASCII.GetBytes('GIF89a0000')
		'Webp.webp' = [Text.Encoding]::ASCII.GetBytes('RIFF0000WEBPVP8 0000')
		'PngAsJpeg.jpeg' = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ')
		'Sized.svg' = [Text.Encoding]::ASCII.GetBytes("<?xml version='1.0'?>`n<svg width='10px' height='2em'></svg>`n")
		'Wide.svg' = [Text.Encoding]::ASCII.GetBytes("<svg xmlns='http://www.w3.org/2000/svg' width='10' viewBox='0 0 10 5'></svg>`n")
	}
	foreach ($Name in $Readable.Keys) { [IO.File]::WriteAllBytes("$($Bundle.Dir)\Images\$Name", $Readable[$Name]) }
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
	foreach ($Name in $Readable.Keys) { Remove-Item "$($Bundle.Dir)\Images\$Name" }
	Check 'JPEG, GIF and WebP images pass, a PNG named .jpeg, and SVGs with a size' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	$Moved = Join-Paths $DocsOut 'unreal' 'sample-docs' '9.9.9'
	Copy-Item $Bundle.Dir $Moved -Recurse
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Moved }
	Check 'a bundle in the wrong folder is reported' (@($Annotations | Where-Object { $_.Contains('.../unreal/sample-docs/9.9.9, but its docs.json puts it in unreal/sample-docs/1.2.3') }).Count -eq 1) ($Annotations -join "`n")

	# Docs with no version, as the contract allows.
	$Current = Join-Paths $Temp 'docs-current' 'unreal' 'sample-docs' 'current'
	New-Item -ItemType Directory -Path (Split-Path $Current) -Force | Out-Null
	Copy-Item $Bundle.Dir $Current -Recurse
	Write-Utf8File "$Current\docs.json" $Json.Replace('"version": "1.2.3"', '"version": null')
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Current }
	Check 'docs with no version pass in a folder named current' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	$NoDescription = Join-Paths $Temp 'docs-plain'
	New-DocsFixture $NoDescription
	$Path = "$NoDescription\Sample.uplugin"
	[IO.File]::WriteAllText($Path, (Remove-DescriptorField ([IO.File]::ReadAllText($Path)) 'Description'))
	$script:Other = $null
	$null = Get-Annotations { $script:Other = New-DocsBundle -PluginDir $NoDescription -OutDir "$Temp\docs-plain-out" -Ref 'main' -Commit $Commit -Repo 'Example/Plain' -Released '2026-11-09' }
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $script:Other.Dir }
	Check 'an empty description says where to set it' (@($Annotations | Where-Object { $_.Contains('"description" is empty. Set Description in the .uplugin') }).Count -eq 1) ($Annotations -join "`n")

	Write-Host 'Docs script'
	$null = Invoke-NativeQuiet git @('-C', $Plugin, 'init', '-q')
	$null = Invoke-NativeQuiet git @('-C', $Plugin, 'add', '-A')
	# Backdated, so the preview's date is the docs commit's and not today's.
	$env:GIT_COMMITTER_DATE = '2026-01-02T03:04:05Z'
	try { $null = Invoke-NativeQuiet git @('-C', $Plugin, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '-m', 'docs') }
	finally { Remove-Item Env:\GIT_COMMITTER_DATE }
	$PluginHead = (Invoke-NativeQuiet git @('-C', $Plugin, 'rev-parse', 'HEAD')).Output | Select-Object -First 1
	$DocsScript = Join-Path $Root 'plugin/docs/New-DocsBundle.ps1'
	$ScriptOut = Join-Paths $Temp 'docs-script'
	$Annotations = Get-Annotations { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -EngineVersions '5.8' -Repository 'Example/SampleDocs' -Private:$false -Strict }
	$ScriptJson = [IO.File]::ReadAllText("$ScriptOut\unreal\sample-docs\preview\docs.json") | ConvertFrom-Json
	Check 'the script builds a preview from the checkout, dated by its last docs commit' ($ScriptJson.preview -eq $true -and $ScriptJson.commit -eq $PluginHead -and $ScriptJson.ref -and $ScriptJson.released -eq '2026-01-02' -and (Same $ScriptJson.unreal.engines @('5.8'))) ($ScriptJson | ConvertTo-Json -Depth 5)
	Check 'clean docs pass strictly, with the left-out file as a warning' (@($Annotations | Where-Object { $_ -like '::error*' }).Count -eq 0 -and @($Annotations | Where-Object { $_ -like '::warning*Notes.txt*' }).Count -eq 1) ($Annotations -join "`n")

	# cd changes PowerShell's location but not the process's, which .NET resolves against.
	Push-Location $Temp
	try { $null = Get-Annotations { try { & $DocsScript -PluginDir 'Sample' -OutDir 'docs-relative' -Repository 'Example/SampleDocs' -Private:$false } catch { } } }
	finally { Pop-Location }
	Check 'relative paths are taken from the current location' (Test-Path -LiteralPath "$Temp\docs-relative\unreal\sample-docs\preview\docs.json")

	New-TestFile "$Plugin\Content\Docs\Bad.md" "# Title`n`nSee [it](Missing.md).`n"
	$Annotations = Get-Annotations { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -Repository 'Example/SampleDocs' -Private:$false }
	Check 'without -Strict a problem is a warning' (@($Annotations | Where-Object { $_ -like '::warning file=Content/Docs/Bad.md,line=3,*' }).Count -eq 1)
	$script:Caught = $null
	$null = Get-Annotations { try { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -Repository 'Example/SampleDocs' -Private:$false -Strict } catch { $script:Caught = $_.Exception.Message } }
	Check 'with -Strict it fails the script' ($script:Caught -like '*1 problem(s)*') "$script:Caught"
	Remove-Item "$Plugin\Content\Docs\Bad.md"

	# The action as the release job runs it. gh knows a release for v1.4.0, and none yet for v1.5.0.
	$Stub = Join-Paths $Temp 'gh-stub'
	New-TestFile "$Stub\gh.cmd" ((@(
		'@echo off'
		'if "%1 %2 %3"=="release view v1.4.0" ('
		'  echo 2026-10-01T09:30:00Z'
		'  exit /b 0'
		')'
		'exit /b 1'
	) -join "`r`n") + "`r`n")
	$StepOut = Join-Paths $Temp 'docs-step'
	$OutputFile = Join-Paths $Temp 'docs-step-output.txt'
	$Inputs = @{ 'plugin-dir' = $Plugin; 'engine-versions' = '5.8'; tag = 'v1.5.0'; strict = 'true'; private = 'false'; repository = 'Example/SampleDocs'; 'out-dir' = $StepOut; token = '' }
	$Environment = @{ PATH = "$Stub;$env:PATH"; GITHUB_OUTPUT = $OutputFile }
	$Today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
	$Step = Invoke-ActionStep (Join-Path $Root 'plugin/docs') $Inputs $Environment
	$Dates = @($Today, [DateTime]::UtcNow.ToString('yyyy-MM-dd'))
	Check "the docs step passes for a first release, which gh cannot find yet" ($Step.ExitCode -eq 0) ($Step.Output -join "`n")
	$StepDir = Join-Paths $StepOut 'unreal' 'sample-docs' '1.5.0'
	$StepJson = [IO.File]::ReadAllText("$StepDir\docs.json") | ConvertFrom-Json
	Check "a release's bundle is in its version folder, with the tag as its ref and today's date" ($StepJson.version -eq '1.5.0' -and $StepJson.ref -eq 'v1.5.0' -and $StepJson.preview -eq $false -and $Dates -contains $StepJson.released) ($StepJson | ConvertTo-Json -Depth 5)
	$StepZip = Join-Paths $StepOut 'SampleDocs-1.5.0-docs.zip'
	$Outputs = @([IO.File]::ReadAllLines($OutputFile))
	Check 'the step outputs the bundle, its folder and its zip, with a .sha256 beside it' ((Same $Outputs @("bundle-dir=$StepDir", 'folder=unreal/sample-docs/1.5.0', "zip=$StepZip")) -and [IO.File]::ReadAllText("$StepZip.sha256") -eq "$(Get-FileSha256 $StepZip)  SampleDocs-1.5.0-docs.zip`n") ($Outputs -join "`n")

	Remove-Item $OutputFile
	$Inputs.tag = 'v1.4.0'
	$Step = Invoke-ActionStep (Join-Path $Root 'plugin/docs') $Inputs $Environment
	$StepJson = [IO.File]::ReadAllText("$(Join-Paths $StepOut 'unreal' 'sample-docs' '1.4.0')\docs.json") | ConvertFrom-Json
	Check 'a re-run keeps the date of the release it completes' ($Step.ExitCode -eq 0 -and $StepJson.released -eq '2026-10-01') ($Step.Output -join "`n")

	New-FixturePlugin $NoDescription
	Remove-Item "$NoDescription\Content\Docs" -Recurse
	$Output = (& $DocsScript -PluginDir $NoDescription -OutDir $ScriptOut -Repository 'Example/Plain' -Private:$false 6>&1 | Out-String)
	Check 'a plugin without docs has nothing to check' ($Output.Contains('nothing to check'))
	$script:Caught = $null
	$null = Get-Annotations { try { & $DocsScript -PluginDir $NoDescription -OutDir $ScriptOut -Repository 'Example/Plain' -Private:$false -Strict } catch { $script:Caught = $_.Exception.Message } }
	Check 'publishing a plugin without docs fails' ($script:Caught -like '*no Content/Docs*') "$script:Caught"

	# Windows finds Content/docs as Content/Docs; GitHub and git log do not.
	$Lower = Join-Paths $Temp 'docs-lower'
	New-DocsFixture $Lower
	[IO.Directory]::Move("$Lower\Content\Docs", "$Lower\Content\Docs-renamed")
	[IO.Directory]::Move("$Lower\Content\Docs-renamed", "$Lower\Content\docs")
	$LowerOut = Join-Paths $Temp 'docs-lower-out'
	$script:Caught = $null
	$null = Get-Annotations { try { & $DocsScript -PluginDir $Lower -OutDir $LowerOut -Repository 'Example/Lower' -Private:$false -Strict } catch { $script:Caught = $_.Exception.Message } }
	Check 'publishing docs in Content/docs fails, saying to rename it' ($script:Caught -like 'The docs folder is Content/docs. Rename it to Content/Docs*') "$script:Caught"
	$Annotations = Get-Annotations { try { & $DocsScript -PluginDir $Lower -OutDir $LowerOut -Repository 'Example/Lower' -Private:$false } catch { Write-Host $_.Exception.Message } }
	Check 'without publish-docs it is a warning, and nothing is built' (@($Annotations | Where-Object { $_ -like '::warning title=Docs::The docs folder is Content/docs*' }).Count -eq 1 -and -not (Test-Path -LiteralPath $LowerOut)) ($Annotations -join "`n")

	Write-Host 'Docs publishing'
	$DocsRemote = Join-Paths $Temp 'docs-content.git'
	$null = Invoke-NativeQuiet git @('init', '-q', '--bare', '-b', 'main', $DocsRemote)
	# As GitHub does, so a clone can leave file contents on the server.
	$null = Invoke-NativeQuiet git @('--git-dir', $DocsRemote, 'config', 'uploadpack.allowFilter', 'true')
	$Identity = @('-c', 'user.name=Test', '-c', 'user.email=test@example.com')
	$Seed = Join-Paths $Temp 'docs-seed'
	New-TestFile "$Seed\README.md" "contract`n"
	New-TestFile "$Seed\unreal\other\1.0.0\docs.json" "{}`n"
	New-TestFile "$Seed\unreal\sample-docs\1.0.0\Sample.md" "# Sample`n"
	$null = Invoke-NativeQuiet git @('-C', $Seed, 'init', '-q', '-b', 'main')
	$null = Invoke-NativeQuiet git @('-C', $Seed, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $Seed) + $Identity + @('commit', '-q', '-m', 'Seed'))
	$null = Invoke-NativeQuiet git @('-C', $Seed, 'push', '-q', $DocsRemote, 'HEAD:refs/heads/main')
	function Get-RemoteLine([string[]]$Arguments) { return ((Invoke-NativeQuiet git (@('--git-dir', $DocsRemote) + $Arguments)).Output) }
	$Untouched = Get-RemoteLine @('rev-parse', 'main:unreal/other', 'main:unreal/sample-docs/1.0.0')

	$ContentA = Join-Paths $Temp 'docs-a'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentA)
	# A change outside the bundle's folder, which the commit must leave out.
	[IO.File]::AppendAllText("$ContentA\README.md", "local edit`n")
	$script:Published = $null
	$null = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	$Pushed = Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.2.3')
	Check 'publishing pushes the bundle to its version folder' ($script:Published.Changed -and (Same $Pushed ($Bundle.Files | ForEach-Object { "unreal/sample-docs/1.2.3/$_" }))) ($Pushed -join ', ')
	Check 'the commit is named "<Name> <version> docs"' ((Get-RemoteLine @('log', '-1', '--format=%s', 'main')) -eq 'Example Sample Kit 1.2.3 docs')
	Check 'the commit touches only that folder' (@(Get-RemoteLine @('diff-tree', '--no-commit-id', '--name-only', '-r', 'main') | Where-Object { -not $_.StartsWith('unreal/sample-docs/1.2.3/') }).Count -eq 0 -and (Same (Get-RemoteLine @('show', 'main:README.md')) @('contract')) -and (Invoke-NativeQuiet git @('-C', $ContentA, 'diff', '--cached', '--quiet')).ExitCode -eq 0)
	Check 'other versions and products are left alone' (Same (Get-RemoteLine @('rev-parse', 'main:unreal/other', 'main:unreal/sample-docs/1.0.0')) $Untouched)
	$null = Invoke-NativeQuiet git @('-C', $ContentA, 'checkout', 'HEAD', '--', 'README.md')

	# The commit takes the whole index, so other staged changes stop it.
	[IO.File]::AppendAllText("$ContentA\README.md", "staged edit`n")
	$null = Invoke-NativeQuiet git @('-C', $ContentA, 'add', 'README.md')
	$script:Caught = $null
	try { $null = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } catch { $script:Caught = $_.Exception.Message }
	$null = Invoke-NativeQuiet git @('-C', $ContentA, 'reset', '-q', 'HEAD', '--', 'README.md')
	$null = Invoke-NativeQuiet git @('-C', $ContentA, 'checkout', 'HEAD', '--', 'README.md')
	Check 'a checkout with other changes staged is refused' ($script:Caught -like '*has changes staged outside unreal/sample-docs/1.2.3.*') "$script:Caught"

	$Count = Get-RemoteLine @('rev-list', '--count', 'main')
	$null = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	Check 'publishing the same bundle again changes nothing' (-not $script:Published.Changed -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count)

	$script:Caught = $null
	try { $null = Publish-DocsBundle -BundleDir $script:PreviewBundle.Dir -ContentDir $ContentA } catch { $script:Caught = $_.Exception.Message }
	Check 'a preview is never published' ($script:Caught -like '*never published*' -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count) "$script:Caught"

	# Its folder would be unreal/sample-docs/current, beside the product's versions.
	$script:Caught = $null
	try { $null = Publish-DocsBundle -BundleDir $Current -ContentDir $ContentA } catch { $script:Caught = $_.Exception.Message }
	Check 'docs with no version are never published' ($script:Caught -like '*no release version*' -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count -and (Test-Path -LiteralPath "$ContentA\unreal\sample-docs\1.0.0\Sample.md")) "$script:Caught"

	# A docs.json that names another product's folder: publishing would replace it.
	$Stray = Join-Paths $Temp 'docs-stray' 'unreal' 'sample-docs' '1.2.3'
	New-Item -ItemType Directory -Path (Split-Path $Stray) -Force | Out-Null
	Copy-Item $Bundle.Dir $Stray -Recurse
	Write-Utf8File "$Stray\docs.json" $Json.Replace('"slug": "sample-docs"', '"slug": "other"').Replace('"version": "1.2.3"', '"version": "1.0.0"')
	$script:Caught = $null
	$null = Get-Annotations { try { $null = Publish-DocsBundle -BundleDir $Stray -ContentDir $ContentA } catch { $script:Caught = $_.Exception.Message } }
	Check 'a bundle that breaks a rule is never published' ($script:Caught -like '*problem(s)*Nothing was published.' -and (Same (Get-RemoteLine @('rev-parse', 'main:unreal/other', 'main:unreal/sample-docs/1.0.0')) $Untouched) -and (Test-Path -LiteralPath "$ContentA\unreal\other\1.0.0\docs.json")) "$script:Caught"

	# The same version again, with an image renamed in case only. A clone on Windows ignores case,
	# so git add alone would keep the old name.
	$Renamed = Join-Paths $Temp 'docs-renamed' 'unreal' 'sample-docs' '1.2.3'
	New-Item -ItemType Directory -Path (Split-Path $Renamed) -Force | Out-Null
	Copy-Item $Bundle.Dir $Renamed -Recurse
	[IO.File]::Move("$Renamed\Images\Shot.png", "$Renamed\Images\Shot-renamed.png")
	[IO.File]::Move("$Renamed\Images\Shot-renamed.png", "$Renamed\Images\SHOT.png")
	foreach ($Page in @("$Renamed\Sample.md", "$Renamed\Guides\Setup.md")) { [IO.File]::WriteAllText($Page, [IO.File]::ReadAllText($Page).Replace('Images/Shot.png', 'Images/SHOT.png')) }
	$null = (& { $script:Published = Publish-DocsBundle -BundleDir $Renamed -ContentDir $ContentA } 6>&1 | Out-String)
	$Images = @(Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.2.3/Images'))
	Check 'a file renamed in case only takes its new name' ($script:Published.Changed -and (Same $Images @('unreal/sample-docs/1.2.3/Images/Logo.svg', 'unreal/sample-docs/1.2.3/Images/SHOT.png'))) ($Images -join ', ')

	# A prerelease, zipped and published with paths relative to PowerShell's location.
	$Rc = $BundleArguments.Clone()
	$Rc.Version = 'v1.3.0-rc.1'
	$Rc.OutDir = Join-Paths $Temp 'docs-rc'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Rc }
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $script:Other.Dir }
	Check 'a prerelease bundle goes in its version folder, and passes' ($script:Other.Folder -eq 'unreal/sample-docs/1.3.0-rc.1' -and $Annotations.Count -eq 0) ($Annotations -join "`n")
	$script:Caught = $null
	$script:Published = $null
	$RcVersion = $null
	Push-Location $Temp
	try
	{
		$RcVersion = (Read-DocsManifest 'docs-rc\unreal\sample-docs\1.3.0-rc.1').version
		$null = New-DocsBundleZip -BundleDir 'docs-rc\unreal\sample-docs\1.3.0-rc.1' -OutDir 'docs-rc-zip'
		$null = (& { $script:Published = Publish-DocsBundle -BundleDir 'docs-rc\unreal\sample-docs\1.3.0-rc.1' -ContentDir 'docs-a' } 6>&1 | Out-String)
	}
	catch { $script:Caught = $_.Exception.Message }
	finally { Pop-Location }
	$Pushed = @(Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.3.0-rc.1'))
	Check 'it is read, zipped and published from relative paths' ($RcVersion -eq '1.3.0-rc.1' -and (Test-Path -LiteralPath "$Temp\docs-rc-zip\SampleDocs-1.3.0-rc.1-docs.zip") -and $script:Published.Changed -and $Pushed.Count -eq $script:Other.Files.Count -and (Get-RemoteLine @('log', '-1', '--format=%s', 'main')) -eq 'Example Sample Kit 1.3.0-rc.1 docs') "$script:Caught $($Pushed -join ', ')"

	# Another product pushes first, so this push is turned away and has to rebase.
	$ContentB = Join-Paths $Temp 'docs-b'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentB)
	New-TestFile "$ContentB\unreal\other\2.0.0\docs.json" "{}`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentB, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentB) + $Identity + @('commit', '-q', '-m', 'Other 2.0.0 docs'))
	$null = Invoke-NativeQuiet git @('-C', $ContentB, 'push', '-q', 'origin', 'HEAD:refs/heads/main')
	Remove-Item "$Plugin\Content\Docs\Images\Logo.svg"
	$null = Get-Annotations { $script:Bundle = New-DocsBundle @BundleArguments }
	$Bundle = $script:Bundle
	$Output = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	$Log = Get-RemoteLine @('log', '--format=%s', 'main')
	Check 'a push that lost a race is rebased and pushed' ($script:Published.Changed -and $Output.Contains('moved on') -and (Same ($Log | Select-Object -First 2) @('Example Sample Kit 1.2.3 docs', 'Other 2.0.0 docs'))) ($Log -join ', ')
	$Images = @(Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.2.3/Images'))
	Check 'a file deleted since the last push is gone, and a case rename is undone' (Same $Images @('unreal/sample-docs/1.2.3/Images/Shot.png')) ($Images -join ', ')

	# A clone left behind by another product's push, with one try: it gives up and pushes nothing.
	$Late = $BundleArguments.Clone()
	$Late.Version = '1.2.4'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Late }
	$ContentE = Join-Paths $Temp 'docs-e'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentE)
	$ContentF = Join-Paths $Temp 'docs-f'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentF)
	New-TestFile "$ContentF\unreal\other\4.0.0\docs.json" "{}`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentF, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentF) + $Identity + @('commit', '-q', '-m', 'Other 4.0.0 docs'))
	$null = Invoke-NativeQuiet git @('-C', $ContentF, 'push', '-q', 'origin', 'HEAD:refs/heads/main')
	$Head = Get-RemoteLine @('rev-parse', 'main')
	$script:Caught = $null
	$null = (& { try { $null = Publish-DocsBundle -BundleDir $script:Other.Dir -ContentDir $ContentE -Tries 1 } catch { $script:Caught = $_.Exception.Message } } 6>&1 | Out-String)
	Check 'a push turned away on its last try fails, and the branch stays where it was' ($script:Caught -like '*turned away 1 times*' -and (Get-RemoteLine @('rev-parse', 'main')) -eq $Head) "$script:Caught"

	# Another push wrote the same version's folder, so the rebase cannot apply.
	$ContentG = Join-Paths $Temp 'docs-g'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentG)
	New-TestFile "$ContentF\unreal\sample-docs\1.2.4\Sample.md" "# Someone else`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentF, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentF) + $Identity + @('commit', '-q', '-m', 'Sample 1.2.4 docs, elsewhere'))
	$null = Invoke-NativeQuiet git @('-C', $ContentF, 'push', '-q', 'origin', 'HEAD:refs/heads/main')
	$Head = Get-RemoteLine @('rev-parse', 'main')
	$script:Caught = $null
	$null = (& { try { $null = Publish-DocsBundle -BundleDir $script:Other.Dir -ContentDir $ContentG } catch { $script:Caught = $_.Exception.Message } } 6>&1 | Out-String)
	Check 'a rebase that conflicts fails, and is undone' ($script:Caught -like 'Rebasing onto main failed*' -and (Get-RemoteLine @('rev-parse', 'main')) -eq $Head -and -not (Test-Path -LiteralPath "$ContentG\.git\rebase-merge") -and -not (Test-Path -LiteralPath "$ContentG\.git\rebase-apply")) "$script:Caught"

	$PublishScript = Join-Path $Root 'plugin/publish-docs/Publish-Docs.ps1'
	$RemoteUrl = 'file:///' + $DocsRemote.Replace('\', '/')
	$Saved = @{ DOCS_TOKEN = $env:DOCS_TOKEN; GCM_INTERACTIVE = $env:GCM_INTERACTIVE }
	Remove-Item Env:\DOCS_TOKEN -ErrorAction SilentlyContinue
	# Should the token check break, a repository that does not exist and no sign-in prompt.
	$env:GCM_INTERACTIVE = 'never'
	$script:Caught = $null
	try { & $PublishScript -BundleDir $Bundle.Dir -Repository 'Example/does-not-exist' 6>$null } catch { $script:Caught = $_.Exception.Message }
	foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
	Check 'publishing without a token fails, naming the secret' ($script:Caught -like '*KHAOS_DOCS_TOKEN*') "$script:Caught"

	$script:Caught = $null
	try { & $PublishScript -BundleDir $script:PreviewBundle.Dir -RemoteUrl $RemoteUrl 6>$null } catch { $script:Caught = $_.Exception.Message }
	Check 'the script refuses a preview' ($script:Caught -like '*is a preview*') "$script:Caught"
	$script:Caught = $null
	try { & $PublishScript -BundleDir $Current -RemoteUrl $RemoteUrl 6>$null } catch { $script:Caught = $_.Exception.Message }
	Check 'the script refuses docs with no version' ($script:Caught -like '*no release version*') "$script:Caught"

	$Next = $BundleArguments.Clone()
	$Next.Version = '1.3.0'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Next }
	# Other products push between the script's clone and its push, twice, from a pre-push hook.
	# The default three tries are enough.
	$ContentD = Join-Paths $Temp 'docs-d'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentD)
	New-TestFile "$ContentD\unreal\other\3.0.0\docs.json" "{}`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentD, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentD) + $Identity + @('commit', '-q', '-m', 'Other 3.0.0 docs'))
	$FirstRace = (Invoke-NativeQuiet git @('-C', $ContentD, 'rev-parse', 'HEAD')).Output | Select-Object -First 1
	New-TestFile "$ContentD\unreal\other\3.0.1\docs.json" "{}`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentD, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentD) + $Identity + @('commit', '-q', '-m', 'Other 3.0.1 docs'))
	$Markers = @(@('race-1', 'race-2') | ForEach-Object { (Join-Paths $Temp $_).Replace('\', '/') })
	foreach ($Marker in $Markers) { New-TestFile $Marker 'race' }
	$Hooks = Join-Paths $Temp 'race-hooks'
	$RaceClone = $ContentD.Replace('\', '/')
	New-TestFile "$Hooks\pre-push" "#!/bin/sh`nif [ -f '$($Markers[0])' ]; then`n  rm '$($Markers[0])'`n  git -C '$RaceClone' push -q --no-verify origin $($FirstRace):refs/heads/main`nelif [ -f '$($Markers[1])' ]; then`n  rm '$($Markers[1])'`n  git -C '$RaceClone' push -q --no-verify origin HEAD:refs/heads/main`nfi`n"
	$GitVariables = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_TERMINAL_PROMPT')
	$Saved = @{}
	foreach ($Name in $GitVariables) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name) }
	$env:GIT_CONFIG_COUNT = '1'
	$env:GIT_CONFIG_KEY_0 = 'core.hooksPath'
	$env:GIT_CONFIG_VALUE_0 = $Hooks.Replace('\', '/')
	$env:GIT_TERMINAL_PROMPT = 'kept'
	$WorkDir = Join-Paths $Temp 'docs-work'
	try { $Output = (& { try { & $PublishScript -BundleDir $script:Other.Dir -RemoteUrl $RemoteUrl -WorkDir $WorkDir } catch { Write-Host $_.Exception.Message } } 6>&1 | Out-String -Width 4096) }
	finally
	{
		$Kept = ($env:GIT_TERMINAL_PROMPT -eq 'kept' -and $env:GIT_CONFIG_KEY_0 -eq 'core.hooksPath')
		foreach ($Name in $GitVariables) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
	}
	$Clone = Join-Paths $WorkDir 'docs-content'
	$Partial = (Invoke-NativeQuiet git @('-C', $Clone, 'config', '--get', 'remote.origin.promisor')).Output -contains 'true'
	Check "the script clones without file contents, and checks out only the bundle's folder" ($Partial -and -not $Output.Contains('filter is ignored') -and (Test-Path -LiteralPath "$Clone\unreal\sample-docs\1.3.0\docs.json") -and -not (Test-Path -LiteralPath "$Clone\unreal\other")) $Output
	$Log = Get-RemoteLine @('log', '--format=%s', 'main')
	Check 'the script rebases a push that lost two races, and says where it pushed' ([regex]::Matches($Output, 'moved on').Count -eq 2 -and $Output.Contains("Pushed the Example Sample Kit 1.3.0 docs to $RemoteUrl") -and (Same ($Log | Select-Object -First 3) @('Example Sample Kit 1.3.0 docs', 'Other 3.0.1 docs', 'Other 3.0.0 docs'))) $Output
	Check 'the script puts back the git settings it changes' $Kept

	# A remote that turns pushes away for another reason, such as branch protection.
	$ContentC = Join-Paths $Temp 'docs-c'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentC)
	$Patch = $BundleArguments.Clone()
	$Patch.Version = '1.3.1'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Patch }
	New-TestFile "$DocsRemote\hooks\pre-receive" "#!/bin/sh`nexit 1`n"
	$Count = Get-RemoteLine @('rev-list', '--count', 'main')
	$script:Caught = $null
	$Output = (& { try { $null = Publish-DocsBundle -BundleDir $script:Other.Dir -ContentDir $ContentC } catch { $script:Caught = $_.Exception.Message } } 6>&1 | Out-String)
	Remove-Item "$DocsRemote\hooks\pre-receive"
	Check 'any other push failure stops without retrying' ($script:Caught -like '*failed; see the git output*' -and -not $Output.Contains('moved on') -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count) "$script:Caught"

	# With a token, as on GitHub: a global git config sends GitHub's URL to the local repository.
	# A pre-push hook records the header git would send to github.com.
	$GlobalConfig = Join-Paths $Temp 'gitconfig'
	$AuthHooks = Join-Paths $Temp 'auth-hooks'
	$HeaderFile = (Join-Paths $Temp 'auth-header.txt').Replace('\', '/')
	New-TestFile "$AuthHooks\pre-push" "#!/bin/sh`ngit config --get http.https://github.com/.extraheader > '$HeaderFile'`n"
	Write-Utf8File $GlobalConfig "[url `"$RemoteUrl`"]`n`tinsteadOf = https://github.com/Example/docs.git`n[core]`n`thooksPath = $($AuthHooks.Replace('\', '/'))`n"
	$Names = @('DOCS_TOKEN', 'GIT_CONFIG_GLOBAL', 'GCM_INTERACTIVE') + $GitVariables
	$Saved = @{}
	foreach ($Name in $Names) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name) }
	$env:DOCS_TOKEN = 'not-a-real-token'
	$env:GIT_CONFIG_GLOBAL = $GlobalConfig
	$env:GCM_INTERACTIVE = 'never'
	$env:GIT_CONFIG_COUNT = '1'
	$env:GIT_CONFIG_KEY_0 = 'user.name'
	$env:GIT_CONFIG_VALUE_0 = 'Kept'
	$env:GIT_TERMINAL_PROMPT = 'kept'
	$Token = $BundleArguments.Clone()
	$Token.Version = '1.3.2'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Token }
	try
	{
		$CheckOutput = (& { try { & $PublishScript -CheckToken -Repository 'Example/docs' } catch { Write-Host $_.Exception.Message } } 6>&1 | Out-String)
		$script:Caught = $null
		$null = Get-Annotations { try { & $PublishScript -CheckToken -RemoteUrl 'file:///C:/no/such/docs.git' } catch { $script:Caught = $_.Exception.Message } }
		$Output = (& { try { & $PublishScript -BundleDir $script:Other.Dir -Repository 'Example/docs' -WorkDir (Join-Paths $Temp 'docs-token') } catch { Write-Host $_.Exception.Message } } 6>&1 | Out-String)
	}
	finally
	{
		$Kept = ($env:GIT_CONFIG_COUNT -eq '1' -and $env:GIT_CONFIG_KEY_0 -eq 'user.name' -and $env:GIT_CONFIG_VALUE_0 -eq 'Kept' -and $env:GIT_TERMINAL_PROMPT -eq 'kept')
		foreach ($Name in $Names) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
	}
	Check 'the token check passes when the token can read the docs' ($CheckOutput.Contains('docs-token can read main of Example/docs.')) $CheckOutput
	Check 'and fails when it cannot, saying it may have expired' ($script:Caught -like '*may have expired*KHAOS_DOCS_TOKEN*') "$script:Caught"
	Check 'with a token, the push lands' ($Output.Contains('Pushed the Example Sample Kit 1.3.2 docs to Example/docs') -and (Get-RemoteLine @('log', '-1', '--format=%s', 'main')) -eq 'Example Sample Kit 1.3.2 docs') $Output
	$Header = ''
	if (Test-Path -LiteralPath $HeaderFile) { $Header = [IO.File]::ReadAllText($HeaderFile).Trim() }
	$Basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('x-access-token:not-a-real-token'))
	Check 'git sends github.com the token as basic auth, as actions/checkout does' ($Header -ceq "AUTHORIZATION: basic $Basic") $Header
	Check 'the script puts back the git settings that carried the token' $Kept
	$Inputs = @{ 'bundle-dir' = ''; token = 'not-a-real-token'; repository = 'Example/docs'; branch = 'main'; 'check-token' = 'true' }
	$Step = Invoke-ActionStep (Join-Path $Root 'plugin/publish-docs') $Inputs @{ GIT_CONFIG_GLOBAL = $GlobalConfig; GCM_INTERACTIVE = 'never' }
	Check 'the action checks the token as the package job runs it' ($Step.ExitCode -eq 0 -and ($Step.Output -join "`n").Contains('docs-token can read main of Example/docs.')) ($Step.Output -join "`n")

	Write-Host 'Release script'
	# gh as the release sees it: no tag or release yet, then the release it made.
	$GhRelease = Join-Paths $Temp 'gh-release'
	New-TestFile "$GhRelease\gh.cmd" ((@(
		'@echo off'
		'echo %*>>"%GH_STUB%\log.txt"'
		'if "%1 %2"=="release view" goto view'
		'if "%1 %2"=="release create" goto notes'
		'if "%1 %2"=="release edit" goto notes'
		'if "%1 %2"=="release upload" exit /b 0'
		'if "%1"=="api" goto api'
		'exit /b 1'
		':view'
		'if not exist "%GH_STUB%\body.md" exit /b 1'
		'if "%6"=="--json" type "%GH_STUB%\body.md"'
		'exit /b 0'
		':notes'
		'if "%~1"=="" exit /b 0'
		'if "%~1"=="--notes-file" copy /y "%~2" "%GH_STUB%\body.md" >nul & exit /b 0'
		'shift'
		'goto notes'
		':api'
		'echo %2| findstr /c:"/git/ref/tags/" >nul && exit /b 1'
		'echo %2| findstr /c:"/compare/" >nul && echo identical&& exit /b 0'
		'echo %2| findstr /c:"/commits/" /c:"/git/ref/heads/" >nul && echo 0123456789abcdef0123456789abcdef01234567&& exit /b 0'
		'echo false'
		'exit /b 0'
	) -join "`r`n") + "`r`n")
	# The docs zip sits with the source zips, so the script has to tell them apart.
	$Packages = Join-Paths $Temp 'release-dist'
	foreach ($Engine in @('5.7', '5.8'))
	{
		New-TestFile "$Packages\Sample-1.2.3-UE$Engine.zip" "zip $Engine"
		New-TestFile "$Packages\Sample-1.2.3-UE$Engine.zip.sha256" "sum $Engine"
	}
	Copy-Item $Zip $Packages
	Copy-Item "$Zip.sha256" $Packages
	$ReleaseDocs = Join-Paths $Packages 'SampleDocs-1.2.3-docs.zip'
	$ReleaseScript = Join-Path $Root 'plugin/release/Publish-Release.ps1'
	$GhLog = Join-Paths $GhRelease 'log.txt'
	$Summary = Join-Paths $Temp 'release-summary.md'
	$Saved = @{}
	foreach ($Name in @('PATH', 'GH_STUB', 'GITHUB_STEP_SUMMARY')) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name) }
	$env:PATH = "$GhRelease;$env:PATH"
	$env:GH_STUB = $GhRelease
	$env:GITHUB_STEP_SUMMARY = $Summary
	try
	{
		$null = (& $ReleaseScript -PluginDir $Plugin -PackageDir $Packages -Tag 'v1.2.3' -Repository 'Example/SampleDocs' -Target $PluginHead -DocsZip $ReleaseDocs 6>&1 | Out-String)
		$Created = @(Get-Content -LiteralPath $GhLog | Where-Object { $_ -like 'release create *' })
		$Body = [IO.File]::ReadAllText((Join-Paths $GhRelease 'body.md'))
		$SummaryText = [IO.File]::ReadAllText($Summary)

		# A re-run with the same docs zip, then with one rebuilt to other bytes.
		Remove-Item -LiteralPath $GhLog
		$null = (& $ReleaseScript -PluginDir $Plugin -PackageDir $Packages -Tag 'v1.2.3' -Repository 'Example/SampleDocs' -Target $PluginHead -DocsZip $ReleaseDocs 6>&1 | Out-String)
		$Same = @(Get-Content -LiteralPath $GhLog)
		Remove-Item -LiteralPath $GhLog
		$Rebuilt = Join-Paths $Temp 'release-docs' 'SampleDocs-1.2.3-docs.zip'
		New-TestFile $Rebuilt 'other bytes'
		New-TestFile "$Rebuilt.sha256" 'sum'
		$null = (& $ReleaseScript -PluginDir $Plugin -PackageDir $Packages -Tag 'v1.2.3' -Repository 'Example/SampleDocs' -Target $PluginHead -DocsZip $Rebuilt 6>&1 | Out-String)
		$Changed = @(Get-Content -LiteralPath $GhLog)
		$RebuiltBody = [IO.File]::ReadAllText((Join-Paths $GhRelease 'body.md'))

		$NoSum = Join-Paths $Temp 'release-nosum' 'SampleDocs-1.2.3-docs.zip'
		New-TestFile $NoSum 'zip'
		$script:Caught = $null
		try { $null = (& $ReleaseScript -PluginDir $Plugin -PackageDir $Packages -Tag 'v1.2.3' -Repository 'Example/SampleDocs' -Target $PluginHead -DocsZip $NoSum 6>&1 | Out-String) } catch { $script:Caught = $_.Exception.Message }
	}
	finally
	{
		foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
	}
	# release create <tag> <assets> --repo ...
	$Assets = @()
	if ($Created.Count -eq 1)
	{
		$Tokens = $Created[0].Split(' ')
		$Assets = @($Tokens[3..([Array]::IndexOf($Tokens, '--repo') - 1)] | ForEach-Object { [IO.Path]::GetFileName($_) })
	}
	Check 'a release gets the source zips, the docs zip and their checksums, and nothing else' (Same $Assets @('Sample-1.2.3-UE5.7.zip', 'Sample-1.2.3-UE5.8.zip', 'Sample-1.2.3-UE5.7.zip.sha256', 'Sample-1.2.3-UE5.8.zip.sha256', 'SampleDocs-1.2.3-docs.zip', 'SampleDocs-1.2.3-docs.zip.sha256')) ($Created -join "`n")
	$Packaged = $Body.IndexOf('### Packages')
	Check 'the notes put the docs after the packages, which list only the source zips' ($Packaged -ge 0 -and $Body.IndexOf('### Docs') -gt $Packaged -and @([regex]::Matches($Body, '(?m)^### Docs$')).Count -eq 1 -and $Body.Contains((Get-DocsReleaseNote $ReleaseDocs)) -and @([regex]::Matches($Body, '(?m)^\| `[^`]+` \| `[0-9a-f]{64}` \|$')).Count -eq 2 -and -not $Body.Contains('| `SampleDocs')) $Body
	Check 'the Fab checklist lists only the source zips' (@([regex]::Matches($SummaryText, '(?m)^\| 5\.[78] \| https://github\.com/Example/SampleDocs/releases/download/v1\.2\.3/Sample-1\.2\.3-UE5\.[78]\.zip \|$')).Count -eq 2 -and -not $SummaryText.Contains('docs.zip')) $SummaryText
	Check 'a re-run with the same docs zip uploads again and leaves the notes' (@($Same | Where-Object { $_ -like 'release upload v1.2.3 *--clobber' }).Count -eq 1 -and @($Same | Where-Object { $_ -like 'release edit *' }).Count -eq 0) ($Same -join "`n")
	Check 'a docs zip without its .sha256 stops the release' ($script:Caught -like '*.sha256 is missing*') "$script:Caught"
	Check "a re-run with a rebuilt docs zip puts its checksum in the notes" (@($Changed | Where-Object { $_ -like 'release edit v1.2.3 *' }).Count -eq 1 -and $RebuiltBody.Contains("SHA-256 ``$(Get-FileSha256 $Rebuilt)``") -and -not $RebuiltBody.Contains((Get-FileSha256 $ReleaseDocs))) ($Changed -join "`n")

	Write-Host 'Scripts'
	foreach ($Script in Get-ChildItem $Root -Include '*.ps1', '*.psm1' -Recurse | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
	{
		$Bytes = [IO.File]::ReadAllBytes($Script.FullName)
		$NonAscii = @($Bytes | Where-Object { $_ -gt 127 }).Count
		# Windows PowerShell reads a BOM-less script as the ANSI code page, so anything beyond ASCII changes meaning.
		Check "$($Script.Name) is ASCII" ($NonAscii -eq 0)

		$Errors = $null
		[void][System.Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$null, [ref]$Errors)
		Check "$($Script.Name) parses" ($Errors.Count -eq 0) (($Errors | ForEach-Object { $_.Message }) -join '; ')
	}
}
finally
{
	foreach ($Name in $CiFiles.Keys) { [Environment]::SetEnvironmentVariable($Name, $CiFiles[$Name]) }
	if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}

Write-Host ''
Write-Host "$script:Passes passed, $script:Failures failed."
if ($script:Failures -gt 0) { exit 1 }
exit 0
