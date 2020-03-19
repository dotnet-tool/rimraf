#!/usr/bin/env pwsh

[CmdletBinding(PositionalBinding = $false)]
param(
    [string] [ValidateSet('dotnet', 'vs')] $msbuildEngine = $null,
    [bool] $warnAsError = $true,
    [bool] $nodeReuse = $true,
    [switch] $noNodeReuse,
    [switch] $noBuildInParallel,
    [string] [Alias('c')] $configuration = 'debug',
    [string] $projects,
    [string] [ValidateSet('quiet', 'minimal', 'normal', 'detailed', 'diagnostics')] [Alias('v')] $verbosity = 'minimal',
    [switch] $clean,
    [switch] [Alias('r')] $restore,
    [switch] [Alias('b')] $build,
    [switch] $rebuild,
    [switch] [Alias('t')] $test,
    [switch] $obfuscate,
    [switch] $pack,
    [switch] $publish,
    [switch] $sign,
    [switch] $publishArtifacts,
    [switch] $ci,
    [switch] $officialBuild,
    [string] $officialBuildId,
    [ValidateSet('', 'prerelease', 'release')] [string] $dotNetFinalVersionKind = '',
    [switch] $attachDebugger,
    [switch] $force,
    [switch] $help,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $properties
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Usage() {
    $dotNetBuildSdkVersion = $GlobalJson.'msbuild-sdks'.'DotNet.Build.Sdk'

    Write-Host '.NET Build Tools Execution Script' -NoNewline -ForegroundColor White
    if ($dotNetBuildSdkVersion) {
        Write-Host " ($dotNetBuildSdkVersion)" -ForegroundColor DarkGray
    } else {
        Write-Host
    }
    Write-Host
    Write-Host 'Usage: build.ps1 [options]'
    Write-Host

    Write-Host 'Common options:'
    Write-Host "  -msbuildEngine <value>    MSBuild engine to use to run build ('dotnet', 'vs', or unspecified)"
    Write-Host '  -configuration <value>    Build configuration: debug, release (defaults to debug)'
    Write-Host '  -verbosity <value>        MSBuild verbosity levels: q[uiet], m[inimal], n[ormal], d[etailed] and diag[nostic] (defaults to m[inimal])'
    Write-Host '  -help                     Print help and exit'
    Write-Host

    Write-Host 'Options:'
    Write-Host '  -clean                    Clean output'
    Write-Host '  -restore                  Restore dependencies'
    Write-Host '  -build                    Build projects'
    Write-Host '  -rebuild                  Rebuild projects'
    Write-Host '  -test                     Run all unit tests in the projects'
    Write-Host '  -obfuscate                Obfuscate build outputs'
    Write-Host '  -pack                     Package build outputs into NuGet packages and components'
    Write-Host '  -publish                  Cross-targeting and cross-platform publishing projects'
    Write-Host '  -sign                     Sign build outputs'
    Write-Host '  -publishArtifacts         Publish artifacts (e.g. symbols, artifactory)'
    Write-Host

    Write-Host 'Versioning/Release options:'
    Write-Host '  -officialBuild            Set when build a official release'
    Write-Host "  -officialBuildId          Set to a specific build ID. Assumed to have format 'yyyyMMdd.rrr'"
    Write-Host '  -dotNetFinalVersionKind   Final version kind: <not present>, prerelease, release (defaults to <not present>)'
    Write-Host "                              '<not present>'  '1.2.3-beta.12345.67'"
    Write-Host "                              'prerelease'     '1.2.3-beta.final'"
    Write-Host "                              'release'        '1.2.3'"

    Write-Host 'Advanced options:'
    Write-Host "  -projects <value>         Semi-colon delimited list of sln/proj's to build. Globbing is supported (*.sln, *.csproj)"
    Write-Host '  -ci                       Set when running on CI server'
    Write-Host '  -force                    Force to bootstrap and build from clean state'
    Write-Host
    Write-Host 'Command line arguments not listed above are passed thru to MSBuild.' -ForegroundColor DarkYellow
    Write-Host 'The above arguments can be shortened as much as to be unambiguous (e.g. -co for configuration, -t for test, etc.).' -ForegroundColor DarkGray
}

function Invoke-Build {
    Install-GlobalTools

    Invoke-CleanAndForce

    $toolsetBuildProj = Initialize-Toolset

    $buildProperties = @()
    $buildProperties += "/property:RepoRoot=$RepoRoot"
    $buildProperties += "/property:Configuration=$configuration"

    if ($projects) {
        # Resolve relative project paths into full paths
        #   Delimited by an escaped ';' and will unescaped in build.proj.
        $projects = $projects.Split(';').ForEach( { Resolve-Path $_ } ) -join '%3B'
        $buildProperties += "/property:`"Projects=$projects`""
    }

    $buildProperties += "/property:Clean=$clean"
    $buildProperties += "/property:Restore=$restore"
    $buildProperties += "/property:Build=$build"
    $buildProperties += "/property:Rebuild=$rebuild"
    $buildProperties += "/property:Test=$test"
    $buildProperties += "/property:Obfuscate=$obfuscate"
    $buildProperties += "/property:Pack=$pack"
    $buildProperties += "/property:Publish=$publish"
    $buildProperties += "/property:Sign=$sign"
    $buildProperties += "/property:PublishArtifacts=$publishArtifacts"

    $buildProperties += "/property:ContinuousIntegrationBuild=$ci"
    $buildProperties += "/property:OfficialBuild=$officialBuild"
    $buildProperties += "/property:OfficialBuildId=$officialBuildId"
    $buildProperties += "/property:DotNetFinalVersionKind=$dotNetFinalVersionKind"

    $buildProperties += "/property:Debug=$debug"
    $buildProperties += "/property:AttachDebugger=$attachDebugger"
    $buildProperties += "/property:NoBuildInParallel=$noBuildInParallel"

    Invoke-MSBuild  `
        @buildProperties `
        /fileloggerparameters:"LogFile=$(Join-Path $LogDir 'build.log');Verbosity=normal;Encoding=UTF-8" `
        /binaryLogger:"LogFile=$(Join-Path $LogDir 'build.binlog')" `
        $toolsetBuildProj `
        @properties
}

try {
    $debug = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('debug') -and $PSCmdlet.MyInvocation.BoundParameters['debug'].IsPresent

    . $PSScriptRoot/tools.ps1
    if ((Test-Path variable:\LastExitCode) -and ($LastExitCode -ne 0)) {
        Write-Host 'eng/common/tools.ps1 returned a non-zero exit code.' -ForegroundColor Red
        Exit-WithExitCode $LastExitCode
    }

    if ($help -or (($null -ne $properties) -and ($properties.Contains('/help') -or $properties.Contains('/?')))) {
        Write-Usage
        Exit-WithExitCode 0
    }

    if ($ci -or $debug) {
        $nodeReuse = $false
    }

    Invoke-Build
} catch {
    Write-Host $_
    Write-Host $_.Exception
    Write-Host $_.ScriptStackTrace
    Exit-WithExitCode 1
}

Exit-WithExitCode 0