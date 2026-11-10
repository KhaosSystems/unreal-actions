<#
.SYNOPSIS
Push a docs bundle to KhaosSystems/docs-content, which docs.khaos.systems is built from.

.DESCRIPTION
Replaces a release bundle's own <section>/<slug>/<version>/ folder and nothing else, in one commit
named "<Name> <version> docs". The bundle is checked first, and refused unless it is a release
that passes every rule. A push that loses a race with another product's is rebased and tried
again, three tries in all. When the folder already holds this bundle, as on a re-run, nothing is
pushed. A push to docs-content's main branch starts the site's deploy.

Only the bundle's folder is checked out, and file contents are fetched as needed, so the clone stays
small however many versions the repository holds.

With -CheckToken it pushes nothing: it only checks that the token can read the docs repository, so
a release with an expired token fails before it is made.

Needs DOCS_TOKEN: a token with Contents read and write on the docs repository, the organization
secret KHAOS_DOCS_TOKEN.

.EXAMPLE
./Publish-Docs.ps1 -BundleDir ./docs-dist/unreal/my-plugin/1.2.0
#>
[CmdletBinding()]
param(
	# The bundle's version folder, from New-DocsBundle.ps1.
	[string]$BundleDir,

	[string]$Repository = 'KhaosSystems/docs-content',
	[string]$Branch = 'main',
	[string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'publish-docs'),

	# Where to push instead of GitHub, such as a local repository in tests.
	[string]$RemoteUrl,

	# Only check that the token can read the docs repository.
	[switch]$CheckToken
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/UnrealActions.psm1') -Force

function Invoke-Git
{
	$ExitCode = Invoke-NativeCommand -FilePath 'git' -ArgumentList $args
	if ($ExitCode -ne 0) { throw "git $($args -join ' ') failed with exit code $ExitCode." }
}

if (-not $CheckToken)
{
	if (-not $BundleDir) { throw 'Give the bundle with -BundleDir.' }
	$BundleDir = (Get-FullPath $BundleDir).TrimEnd('\', '/')
	$Manifest = Read-DocsRelease $BundleDir
	$Folder = Get-DocsBundleFolder $Manifest
}
$WorkDir = Get-FullPath $WorkDir
$Where = $Repository
if ($RemoteUrl) { $Where = $RemoteUrl }

# The token reaches git through the environment, so it is put back as it was afterwards.
$GitVariables = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_TERMINAL_PROMPT')
$Saved = @{}
foreach ($Name in $GitVariables) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name) }
try
{
	if (-not $RemoteUrl)
	{
		if (-not $env:DOCS_TOKEN) { throw "DOCS_TOKEN is not set, so the docs cannot be pushed to $Repository. Pass the organization secret KHAOS_DOCS_TOKEN to the workflow as docs-token." }
		# Authenticate git the way actions/checkout does, without writing the token to disk.
		$Basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:DOCS_TOKEN"))
		if (Test-GitHubActions) { Write-Host "::add-mask::$Basic" }
		$env:GIT_CONFIG_COUNT = '1'
		$env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
		$env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $Basic"
		$RemoteUrl = "https://github.com/$Repository.git"
	}
	$env:GIT_TERMINAL_PROMPT = '0'

	if ($CheckToken)
	{
		$Probe = Invoke-NativeQuiet git @('ls-remote', '--heads', $RemoteUrl, $Branch)
		if ($Probe.ExitCode -ne 0 -or $Probe.Output.Count -eq 0)
		{
			$Message = "docs-token cannot read $Branch of $Where. It may have expired: renew the organization secret KHAOS_DOCS_TOKEN."
			Write-CiAnnotation error $Message -Title 'Docs token'
			throw $Message
		}
	}
	else
	{
		Reset-Directory $WorkDir
		$Clone = Join-Paths $WorkDir 'docs-content'
		Invoke-Git clone --filter=blob:none --sparse --no-checkout --quiet --branch $Branch $RemoteUrl $Clone
		Invoke-Git -C $Clone sparse-checkout set '--' $Folder
		Invoke-Git -C $Clone checkout --quiet $Branch

		$Result = Publish-DocsBundle -BundleDir $BundleDir -ContentDir $Clone -Branch $Branch
	}
}
finally
{
	foreach ($Name in $GitVariables) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
}

if ($CheckToken)
{
	Write-Host "docs-token can read $Branch of $Where."
	return
}

$Version = [string]$Manifest.version
if ($Result.Changed)
{
	$Url = "https://docs.khaos.systems/$($Manifest.section)/$($Manifest.slug)/v$Version/"
	$Message = "Pushed the $($Manifest.name) $Version docs to $Where ``$Folder``. The docs site deploys them to $Url"
}
else
{
	$Message = "$Where already has these $($Manifest.name) $Version docs in ``$Folder``."
}
Write-Host $Message
Add-CiSummary $Message
