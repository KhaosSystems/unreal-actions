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
The sample plugin with docs that pass every rule: a landing page with CRLF line endings, a page in
a folder, an image, a text file the bundle leaves out, and junk it skips silently.
#>
function New-DocsFixture([string]$Dir)
{
	New-FixturePlugin $Dir
	$Descriptor = "$Dir\Sample.uplugin"
	$Text = Set-DescriptorField ([IO.File]::ReadAllText($Descriptor)) 'Description' 'A sample plugin.'
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
	New-TestFile "$Dir\Content\Docs\Images\Shot.png" 'png'
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

	$Commit = '0123456789abcdef0123456789abcdef01234567'
	$DocsOut = Join-Paths $Temp 'docs-out'
	$BundleArguments = @{ PluginDir = $Plugin; OutDir = $DocsOut; Version = 'v1.2.3'; Ref = 'v1.2.3'; Commit = $Commit; Repo = 'Example/SampleDocs'; Engines = @('5.7', '5.8'); Released = '2026-11-09' }
	New-DocsFixture $Plugin
	$script:Bundle = $null
	$Annotations = @(Get-Annotations { $script:Bundle = New-DocsBundle @BundleArguments })
	$Bundle = $script:Bundle
	Check 'the bundle goes in section/slug/version, the slug from the repository name' ($Bundle.Folder -eq 'unreal/sample-docs/1.2.3' -and $Bundle.Dir -eq (Join-Paths $DocsOut 'unreal' 'sample-docs' '1.2.3'))
	Check 'pages and images keep their paths' (Same $Bundle.Files @('Guides/Setup.md', 'Images/Shot.png', 'Sample.md', 'docs.json')) ($Bundle.Files -join ', ')
	Check 'a file of another type is left out with a warning' ($Annotations.Count -eq 1 -and $Annotations[0] -like '::warning file=Content/Docs/Notes.txt,title=Docs::*.txt*') ($Annotations -join "`n")
	Check 'Markdown gets LF line endings' ([Array]::IndexOf([IO.File]::ReadAllBytes("$($Bundle.Dir)\Sample.md"), [byte]13) -lt 0)
	Check 'Markdown loses its byte order mark' ([IO.File]::ReadAllBytes("$($Bundle.Dir)\Guides\Setup.md")[0] -eq [byte][char]'#')

	$Golden = @'
{
  "base": "Content/Docs",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "description": "A sample plugin.",
  "fabUrl": "https://www.fab.com/listings/00000000-0000-0000-0000-000000000000",
  "glyph": "SA",
  "landing": "Sample.md",
  "name": "Sample",
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

	Write-Host 'Docs rules'
	$script:Result = $null
	$Annotations = Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $Bundle.Dir }
	Check 'the sample docs pass every rule' ($Annotations.Count -eq 0 -and $script:Result.Errors -eq 0) ($Annotations -join "`n")

	$PrivateArguments = $BundleArguments.Clone()
	$PrivateArguments.OutDir = Join-Paths $Temp 'docs-private'
	$PrivateArguments.Private = $true
	$script:PrivateBundle = $null
	$null = Get-Annotations { $script:PrivateBundle = New-DocsBundle @PrivateArguments }

	$Rules = @(
		@{ Name = 'a page without an H1'; Text = "Intro.`n`n## Part`n"; Line = 1; Expect = 'No H1' }
		@{ Name = 'a second H1'; Text = "# One`n`n# Two`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, underlined'; Text = "# One`n`nTwo`n===`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'a second H1, in a list item'; Text = "# One`n`n- # Two`n"; Line = 3; Expect = 'More than one H1' }
		@{ Name = 'content before the H1'; Text = "![Logo](Images/Shot.png)`n`n# Title`n"; Line = 1; Expect = 'must come first' }
		@{ Name = 'a skipped heading level'; Text = "# Title`n`n### Deep`n"; Line = 3; Expect = 'skips a level, H1 to H3' }
		@{ Name = 'raw HTML'; Text = "# Title`n`nA line<br>break.`n"; Line = 3; Expect = 'Raw HTML is not allowed: <br>' }
		@{ Name = 'an HTML block'; Text = "# Title`n`n<details>`n<summary>More</summary>`n</details>`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'an HTML comment'; Text = "# Title`n`n<!-- note -->`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'a C++ type outside backticks'; Text = "# Title`n`nTakes a TArray<FString>.`n"; Line = 3; Expect = 'Raw HTML' }
		@{ Name = 'a broken link'; Text = "# Title`n`nSee [it](Missing.md).`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a broken link on a later line of a paragraph'; Text = "# Title`n`nOne`ntwo [it](Missing.md#part)`n"; Line = 4; Expect = 'is broken' }
		@{ Name = 'a broken reference link'; Text = "# Title`n`nSee [it][x].`n`n[x]: Missing.md`n"; Line = 5; Expect = 'is broken' }
		@{ Name = 'a link with the wrong case'; Text = "# Title`n`nSee [setup](guides/setup.md).`n"; Line = 3; Expect = 'wrong case: the file is Guides/Setup.md' }
		@{ Name = 'a remote image'; Text = "# Title`n`n![Shot](https://example.com/shot.png)`n"; Line = 3; Expect = 'loads no remote images' }
		@{ Name = 'a remote image by reference'; Text = "# Title`n`n![Shot][s]`n`n[s]: https://example.com/shot.png`n"; Line = 5; Expect = 'loads no remote images' }
		@{ Name = 'a remote image inside a link'; Text = "# Title`n`n[![b](https://example.com/b.svg)](https://example.com)`n"; Line = 3; Expect = 'loads no remote images' }
		@{ Name = 'an image outside the bundle'; Text = "# Title`n`n![Icon](../../Resources/Icon128.png)`n"; Line = 3; Expect = 'outside the docs folder' }
		@{ Name = 'a missing image'; Text = "# Title`n`n![Shot](Images/None.png)`n"; Line = 3; Expect = 'is broken' }
		@{ Name = 'a root-relative link'; Text = "# Title`n`nSee [the docs](/unreal/sample-docs/).`n"; Line = 3; Expect = 'root-relative' }
		@{ Name = 'a link of another scheme'; Text = "# Title`n`nSee [files](ftp://example.com/x).`n"; Line = 3; Expect = 'only http(s), mailto' }
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

	New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](../../Source/SampleEditor/Private/SampleEditor.cpp).`n"
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Bundle.Dir }
	Remove-Item "$($Bundle.Dir)\Bad.md"
	Check 'a public repository may link its other files' ($Annotations.Count -eq 0) ($Annotations -join "`n")

	New-TestFile "$($Bundle.Dir)\Bad.md" "# Title`n`nSee [it](Missing.md).`n"
	$script:Result = $null
	$Annotations = @(Get-Annotations { $script:Result = Test-DocsBundle -BundleDir $Bundle.Dir -AsWarnings })
	Remove-Item "$($Bundle.Dir)\Bad.md"
	Check 'with -AsWarnings problems are warnings, and still counted' ($Annotations.Count -eq 1 -and $Annotations[0] -like '::warning file=Content/Docs/Bad.md,line=3,*' -and $script:Result.Errors -eq 1) ($Annotations -join "`n")

	$FileRules = @(
		@{ Name = 'an image over 5 MB'; Add = { [IO.File]::WriteAllBytes("$($Bundle.Dir)\Images\Big.png", (New-Object byte[] 5000001)) }; Expect = 'file=Content/Docs/Images/Big.png,title=Docs::The image is 5.0 MB; the limit is 5 MB.' }
		@{ Name = 'a bundle over 25 MB'; Add = { foreach ($N in 1..6) { [IO.File]::WriteAllBytes("$($Bundle.Dir)\Images\Part$N.png", (New-Object byte[] 4500000)) } }; Expect = 'title=Docs::The docs come to 27.0 MB; the limit is 25 MB.' }
		@{ Name = 'a file type a bundle cannot hold'; Add = { New-TestFile "$($Bundle.Dir)\notes.txt" 'x' }; Expect = 'file=Content/Docs/notes.txt,title=Docs::Only .md pages' }
		@{ Name = 'CRLF in a bundle'; Add = { New-TestFile "$($Bundle.Dir)\Crlf.md" "# Title`r`n" }; Expect = 'file=Content/Docs/Crlf.md,title=Docs::CR line endings' }
		@{ Name = 'a missing landing page'; Add = { Rename-Item "$($Bundle.Dir)\Sample.md" 'Landing.md' }; Expect = 'The landing page Content/Docs/Sample.md is missing' }
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

	$Moved = Join-Paths $DocsOut 'unreal' 'sample-docs' '9.9.9'
	Copy-Item $Bundle.Dir $Moved -Recurse
	$Annotations = Get-Annotations { $null = Test-DocsBundle -BundleDir $Moved }
	Check 'a bundle in the wrong folder is reported' (@($Annotations | Where-Object { $_.Contains('.../unreal/sample-docs/9.9.9, but its docs.json puts it in unreal/sample-docs/1.2.3') }).Count -eq 1) ($Annotations -join "`n")

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
	$null = Invoke-NativeQuiet git @('-C', $Plugin, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '-m', 'docs')
	$PluginHead = (Invoke-NativeQuiet git @('-C', $Plugin, 'rev-parse', 'HEAD')).Output | Select-Object -First 1
	$DocsScript = Join-Path $Root 'plugin/docs/New-DocsBundle.ps1'
	$ScriptOut = Join-Paths $Temp 'docs-script'
	$Annotations = Get-Annotations { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -EngineVersions '5.8' -Repository 'Example/SampleDocs' -Private:$false -Strict }
	$ScriptJson = [IO.File]::ReadAllText("$ScriptOut\unreal\sample-docs\preview\docs.json") | ConvertFrom-Json
	Check 'the script builds a preview from the checkout' ($ScriptJson.preview -eq $true -and $ScriptJson.commit -eq $PluginHead -and $ScriptJson.ref -and $ScriptJson.released -match '^\d{4}-\d{2}-\d{2}$' -and (Same $ScriptJson.unreal.engines @('5.8'))) ($ScriptJson | ConvertTo-Json -Depth 5)
	Check 'clean docs pass strictly, with the left-out file as a warning' (@($Annotations | Where-Object { $_ -like '::error*' }).Count -eq 0 -and @($Annotations | Where-Object { $_ -like '::warning*Notes.txt*' }).Count -eq 1) ($Annotations -join "`n")

	New-TestFile "$Plugin\Content\Docs\Bad.md" "# Title`n`nSee [it](Missing.md).`n"
	$Annotations = Get-Annotations { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -Repository 'Example/SampleDocs' -Private:$false }
	Check 'without -Strict a problem is a warning' (@($Annotations | Where-Object { $_ -like '::warning file=Content/Docs/Bad.md,line=3,*' }).Count -eq 1)
	$script:Caught = $null
	$null = Get-Annotations { try { & $DocsScript -PluginDir $Plugin -OutDir $ScriptOut -Repository 'Example/SampleDocs' -Private:$false -Strict } catch { $script:Caught = $_.Exception.Message } }
	Check 'with -Strict it fails the script' ($script:Caught -like '*1 problem(s)*') "$script:Caught"
	Remove-Item "$Plugin\Content\Docs\Bad.md"

	New-FixturePlugin $NoDescription
	Remove-Item "$NoDescription\Content\Docs" -Recurse
	$Output = (& $DocsScript -PluginDir $NoDescription -OutDir $ScriptOut -Repository 'Example/Plain' -Private:$false 6>&1 | Out-String)
	Check 'a plugin without docs has nothing to check' ($Output.Contains('nothing to check'))
	$script:Caught = $null
	$null = Get-Annotations { try { & $DocsScript -PluginDir $NoDescription -OutDir $ScriptOut -Repository 'Example/Plain' -Private:$false -Strict } catch { $script:Caught = $_.Exception.Message } }
	Check 'publishing a plugin without docs fails' ($script:Caught -like '*no Content/Docs*') "$script:Caught"

	Write-Host 'Docs publishing'
	$DocsRemote = Join-Paths $Temp 'docs-content.git'
	$null = Invoke-NativeQuiet git @('init', '-q', '--bare', '-b', 'main', $DocsRemote)
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
	$script:Published = $null
	$null = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	$Pushed = Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.2.3')
	Check 'publishing pushes the bundle to its version folder' ($script:Published.Changed -and (Same $Pushed ($Bundle.Files | ForEach-Object { "unreal/sample-docs/1.2.3/$_" }))) ($Pushed -join ', ')
	Check 'the commit is named "<Name> <version> docs"' ((Get-RemoteLine @('log', '-1', '--format=%s', 'main')) -eq 'Sample 1.2.3 docs')
	Check 'the commit touches only that folder' (@(Get-RemoteLine @('diff-tree', '--no-commit-id', '--name-only', '-r', 'main') | Where-Object { -not $_.StartsWith('unreal/sample-docs/1.2.3/') }).Count -eq 0)
	Check 'other versions and products are left alone' (Same (Get-RemoteLine @('rev-parse', 'main:unreal/other', 'main:unreal/sample-docs/1.0.0')) $Untouched)

	$Count = Get-RemoteLine @('rev-list', '--count', 'main')
	$null = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	Check 'publishing the same bundle again changes nothing' (-not $script:Published.Changed -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count)

	# Another product pushes first, so this push is turned away and has to rebase.
	$ContentB = Join-Paths $Temp 'docs-b'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentB)
	New-TestFile "$ContentB\unreal\other\2.0.0\docs.json" "{}`n"
	$null = Invoke-NativeQuiet git @('-C', $ContentB, 'add', '-A')
	$null = Invoke-NativeQuiet git (@('-C', $ContentB) + $Identity + @('commit', '-q', '-m', 'Other 2.0.0 docs'))
	$null = Invoke-NativeQuiet git @('-C', $ContentB, 'push', '-q', 'origin', 'HEAD:refs/heads/main')
	Remove-Item "$Plugin\Content\Docs\Guides" -Recurse
	$null = Get-Annotations { $script:Bundle = New-DocsBundle @BundleArguments }
	$Bundle = $script:Bundle
	$Output = (& { $script:Published = Publish-DocsBundle -BundleDir $Bundle.Dir -ContentDir $ContentA } 6>&1 | Out-String)
	$Log = Get-RemoteLine @('log', '--format=%s', 'main')
	Check 'a push that lost a race is rebased and pushed' ($script:Published.Changed -and $Output.Contains('moved on') -and (Same ($Log | Select-Object -First 2) @('Sample 1.2.3 docs', 'Other 2.0.0 docs'))) ($Log -join ', ')
	Check 'a page deleted since the last push is gone' (@(Get-RemoteLine @('ls-tree', '-r', '--name-only', 'main', 'unreal/sample-docs/1.2.3') | Where-Object { $_ -like '*Guides*' }).Count -eq 0)

	$PublishScript = Join-Path $Root 'plugin/publish-docs/Publish-Docs.ps1'
	$SavedToken = $env:DOCS_TOKEN
	Remove-Item Env:\DOCS_TOKEN -ErrorAction SilentlyContinue
	$script:Caught = $null
	try { & $PublishScript -BundleDir $Bundle.Dir 6>$null } catch { $script:Caught = $_.Exception.Message }
	if ($SavedToken) { $env:DOCS_TOKEN = $SavedToken }
	Check 'publishing without a token fails, naming the secret' ($script:Caught -like '*KHAOS_DOCS_TOKEN*') "$script:Caught"

	$Next = $BundleArguments.Clone()
	$Next.Version = '1.3.0'
	$null = Get-Annotations { $script:Other = New-DocsBundle @Next }
	$Output = (& $PublishScript -BundleDir $script:Other.Dir -RemoteUrl $DocsRemote -WorkDir (Join-Paths $Temp 'docs-work') 6>&1 | Out-String)
	Check 'the script clones just the folder and pushes' ((Get-RemoteLine @('log', '-1', '--format=%s', 'main')) -eq 'Sample 1.3.0 docs' -and $Output.Contains('Pushed the Sample 1.3.0 docs')) $Output

	# A remote that turns pushes away for another reason, such as branch protection.
	$ContentC = Join-Paths $Temp 'docs-c'
	$null = Invoke-NativeQuiet git @('clone', '-q', $DocsRemote, $ContentC)
	New-TestFile "$DocsRemote\hooks\pre-receive" "#!/bin/sh`nexit 1`n"
	$Count = Get-RemoteLine @('rev-list', '--count', 'main')
	$script:Caught = $null
	$Output = (& { try { $null = Publish-DocsBundle -BundleDir $script:PreviewBundle.Dir -ContentDir $ContentC } catch { $script:Caught = $_.Exception.Message } } 6>&1 | Out-String)
	Remove-Item "$DocsRemote\hooks\pre-receive"
	Check 'any other push failure stops without retrying' ($script:Caught -like '*failed; see the git output*' -and -not $Output.Contains('moved on') -and (Get-RemoteLine @('rev-list', '--count', 'main')) -eq $Count) "$script:Caught"

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
	if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}

Write-Host ''
Write-Host "$script:Passes passed, $script:Failures failed."
if ($script:Failures -gt 0) { exit 1 }
