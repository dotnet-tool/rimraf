#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Import modules
try { Import-Module SmartLogging } catch { Install-Module SmartLogging -Scope CurrentUser -Force; Import-Module SmartLogging }
try { Import-Module Execution } catch { Install-Module Execution -Scope CurrentUser -Force; Import-Module Execution }

Set-ScriptArgs $MyInvocation.BoundParameters $MyInvocation.UnboundArguments

# Invoke-SelfElevation

function Assert-CleanCurrentBranch() {
    if (Start-NativeExecution git status -s) {
        Log warning 'Branch is not clean. Please first commit your changes.'
        Exit-WithAndWaitOnExplorer 1
    }
}

function Show-ToolsetFilesDiffs([string] $sourceRepoRootPath) {
    $sourceRepoRootPath = Resolve-Path $sourceRepoRootPath

    $knownItems = @(
        'eng/common/templates/reporoot/*'
    )

    $sources = @()
    foreach ($knownItem in $knownItems) {
        $sourcePath = Join-Path $sourceRepoRootPath $knownItem
        $sources += Get-ChildItem -Path $sourcePath
    }

    # Generate destination paths
    $items = @()
    foreach ($source in $sources) {
        $destination = Join-Path $sourceRepoRootPath $source.Name
        $items += [pscustomobject]@{
            source      = $source
            destination = $destination
        }
    }

    $gitDiffToolName = Start-NativeExecution git config --global --get 'diff.tool'
    $gitDiffToolCmd = Start-NativeExecution git config --global --get "difftool.$gitDiffToolName.cmd"
    $gitDiffToolExe = $gitDiffToolCmd -replace '"\$LOCAL"', '' -replace '"\$REMOTE"', '' -replace "'", ''

    # Start Git Diff
    foreach ($item in $items) {
        Start-NativeExecution $gitDiffToolExe $item.source $item.destination
    }
}

try {
    # Code goes here

    if (-not $Force) {
        Assert-CleanCurrentBranch
    }

    Show-ToolsetFilesDiffs -sourceRepoRootPath (Join-Path $PSScriptRoot '../../')

    # Log info 'Successfully'
    Exit-WithAndWaitOnExplorer 0
} catch {
    Log error "Something went wrong: $_"
    Log trace "Exception: $($_.Exception)"
    Log trace "StackTrace: $($_.ScriptStackTrace)"
    Exit-WithAndWaitOnExplorer 1
} finally {
    # Cleanup goes here
}