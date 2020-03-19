#!/usr/bin/env pwsh

# Initialize variables if they aren't already defined.
# These may be defined as parameters of the importing script, or set after importing this script.

# Specifies which msbuild engine to use for build: 'dotnet', 'vs' or unspecified (determined based on presence of tools.vs in global.json).
[string] $msbuildEngine = if (Test-Path variable:\msbuildEngine) { $msbuildEngine } else { $null }

# Configures warning treatment in msbuild.
[bool] $warnAsError = if (Test-Path variable:\warnAsError) { $warnAsError } else { $true }

# CI mode - set to true on CI server for PR validation build or official build.
[bool] $ci = if (Test-Path variable:\ci) { $ci } else { $false }

# Set to true to reuse msbuild nodes. Recommended to not reuse on CI.
[bool] $nodeReuse = if (Test-Path variable:\nodeReuse) { $nodeReuse } else { -not $ci }
# NoNodeReuse switch parameter override NodeReuse bool parameter.
[bool] $nodeReuse = if ((Test-Path variable:\noNodeReuse) -and ((Get-Variable noNodeReuse).Value.IsPresent)) { $false } else { $nodeReuse }

# Build configuration. Common values include 'debug' and 'release', but the repository may use other names.
[string] $configuration = if (Test-Path variable:\configuration) { $configuration } else { 'debug' }

# Adjusts msbuild verbosity level.
[string] $verbosity = if (Test-Path variable:\verbosity) { $verbosity } else { 'minimal' }

# True to restore toolsets and dependencies.
[bool] $restore = if (Test-Path variable:\restore) { $restore } else { $true }

# True to attempt using .NET Core already that meets requirements specified in global.json
# installed on the machine instead of downloading one.
[bool] $useInstalledDotNetCli = if (Test-Path variable:\useInstalledDotNetCli) { $useInstalledDotNetCli } else { $true }

# Enable repos to use a particular version of the on-line dotnet-install scripts.
#    Default URL: https://dot.net/v1/dotnet-install.ps1
[string] $dotnetInstallScriptVersion = if (Test-Path variable:\dotnetInstallScriptVersion) { $dotnetInstallScriptVersion } else { 'v1' }

# True to use global NuGet cache instead of restoring packages to repository-local directory.
[bool] $useGlobalNuGetCache = if (Test-Path variable:\useGlobalNuGetCache) { $useGlobalNuGetCache } else { -not $ci }

[bool] $disableConfigureToolsetImport = if (Test-Path variable:\disableConfigureToolsetImport) { $disableConfigureToolsetImport } else { $false }

[bool] $debug = if (Test-Path variable:\debug) { $debug } else { $false }

[bool] $attachDebugger = if (Test-Path variable:\attachDebugger) { $attachDebugger } else { $false }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Resolve-RootDirectory([string] $rootFileName) {
    $di = Get-Item $PSScriptRoot

    while ($null -ne $di.Parent) {
        $rootFilePath = Join-Path $di.FullName $rootFileName
        if (Test-Path $rootFilePath) {
            return $di.FullName
        }

        $di = $di.Parent
    }

    return $null
}

function Exit-WithExitCode([int] $exitCode) {
    if ($ci -or $debug) {
        Stop-Processes $BuildToolsDir
    }

    exit $exitCode
}

function Stop-Processes([string] $workspaceDir) {
    if (-not (Test-Path $workspaceDir)) {
        return
    }

    Write-Host 'Killing running build processes...'

    $getProcesses = { Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, Path | Where-Object { $_.Path -and $_.Path.StartsWith((Resolve-Path "$workspaceDir/")) } }

    $retries = 255
    $milliseconds = 75
    do {
        try {
            $processes = & $getProcesses
            foreach ($process in $processes) {
                Write-Host "Try to stop process: $($process.ProcessName) -> '$($process.Path)'"
                Stop-Process -Id $process.Id
            }
        } catch { }

        Start-Sleep -Milliseconds $milliseconds
        --$retries

        $processes = & $getProcesses
    } while ($processes -and ($retries -gt 0))
}

function New-Directory([string[]] $path) {
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force > $null
    }
}

function Expand-ZipFile([string] $path, [string] $destinationPath, [switch] $force) {
    if ($force -and (Test-Path -Path $destinationPath -PathType Container)) {
        & rimraf $destinationPath --quiet > $null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($path, $destinationPath)
}

function Invoke-Process([string] $command, [string] $commandArgs) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command
    $startInfo.Arguments = $commandArgs
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = Get-Location

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() > $null

    $finished = $false
    try {
        while (-not $process.WaitForExit(100)) {
            # Non-blocking loop done to allow ctr-c interrupts
        }

        $finished = $true
        return $global:LASTEXITCODE = $process.ExitCode
    } finally {
        # If we didn't finish then an error occurred or the user hit ctrl-c.
        # Either way kill the process
        if (-not $finished) {
            $process.Kill()
        }
    }
}

function Get-Config([string] $file) {
    if ($null -eq $file) {
        throw "Unable to find Config.props file in repository root directort. Please create a new one from the template in eng/common/templates/ConfigTemplate.props'."
    }

    $xml = [xml](Get-Content $file -Raw)
    $config = $xml.Project.PropertyGroup
    if ($null -eq $config) {
        throw 'Unable to load Config.props file.'
    }

    # Hardcode RepoRoot, because we can not parse MSBuild logic inside the RepoRoot property
    $config | Add-Member -Name 'RepoRoot' -MemberType NoteProperty -Value $RepoRoot

    # Set default values when missing
    Set-DefaultValuesWhenMissing $config

    # Replace MSBuild tokens when any
    Merge-Tokens 'SourceDir' $config
    Merge-Tokens 'BaseOutputDir' $config
    Merge-Tokens 'BinDir' $config
    Merge-Tokens 'ObjDir' $config
    Merge-Tokens 'PackagesOutDir' $config
    Merge-Tokens 'PackagesDir' $config
    Merge-Tokens 'BuildToolsDir' $config
    Merge-Tokens 'ToolsetDir' $config
    Merge-Tokens 'TempDir' $config
    Merge-Tokens 'DotNetBuildUserExtensionsPath' $config

    return $config
}

function Set-DefaultValuesWhenMissing([pscustomobject] $object) {
    Set-DefaultValueIfNotExists $object 'SourceDir' '$(RepoRoot)/src'
    Set-DefaultValueIfNotExists $object 'BaseOutputDir' '$(RepoRoot)/_build'
    Set-DefaultValueIfNotExists $object 'BinDir' '$(BaseOutputDir)/bin'
    Set-DefaultValueIfNotExists $object 'ObjDir' '$(BinDir)/obj'
    Set-DefaultValueIfNotExists $object 'PackagesOutDir' '$(BinDir)/packages'
    Set-DefaultValueIfNotExists $object 'PackagesDir' '$(RepoRoot)/packages'
    Set-DefaultValueIfNotExists $object 'BuildToolsDir' '$(RepoRoot)/_buildtools'
    Set-DefaultValueIfNotExists $object 'ToolsetDir' '$(BuildToolsDir)/toolset'
    Set-DefaultValueIfNotExists $object 'TempDir' '$(BaseOutputDir)/tmp'
    Set-DefaultValueIfNotExists $object 'DotNetBuildUserExtensionsPath' '$(RepoRoot)/eng'
}

function Set-DefaultValueIfNotExists([pscustomobject] $object, [string] $name, [string] $defaultValue) {
    if (-not (Get-Member -InputObject $object -Name $name)) {
        $object | Add-Member -Name $name -MemberType NoteProperty -Value $defaultValue
    }
}

function Merge-Tokens([string] $propertyName, [pscustomobject] $object) {
    $value = $object | Select-Object -ExpandProperty $propertyName -ErrorAction SilentlyContinue
    if (-not $value) { return }

    $replacedValue = [regex]::Replace($value, '\$\((?<token>\w+)\)', { param($match) $object."$($match.Groups['token'].Value)" })
    if (-not $replacedValue) { return }

    $object."$propertyName" = $replacedValue
}

function Get-IsGlobalToolInstalled([string] $dotNetTool, [string] $toolName) {
    $tools = & $dotNetTool tool list --global

    return ($tools | Where-Object { $_.ToLowerInvariant().StartsWith($toolName.ToLowerInvariant()) } | Measure-Object | Select-Object -ExpandProperty Count) -eq 1
}

function Install-GlobalTools() {
    $dotNetTool = 'dotnet.exe'
    if (-not (Get-Command $dotNetTool -ErrorAction SilentlyContinue)) {
        Write-Host "Unable to find the 'dotnet' command. One global shared .NET Core SDK or Runtime is required." -ForegroundColor Red
        Exit-WithExitCode 1
    }

    if (-not (Get-IsGlobalToolInstalled $dotNetTool 'dotnet-rimraf')) {
        $nuGetConfigFile = Join-Path $RepoRoot 'eng/common/templates/NuGet.Config'
        & $dotNetTool tool install --global --configfile $nuGetConfigFile --no-cache dotnet-rimraf > $null
    }
}

function Remove-ToolsetVariables() {
    Remove-Variable _ToolsetBuildProj -Scope 'global' -Force -ErrorAction SilentlyContinue
    Remove-Variable _BuildTool -Scope 'global' -Force -ErrorAction SilentlyContinue
    Remove-Variable _MSBuildExe -Scope 'global' -Force -ErrorAction SilentlyContinue
    Remove-Variable _DotNetInstallDir -Scope 'global' -Force -ErrorAction SilentlyContinue
}

function Invoke-CleanAndForce() {
    if ($clean -and $force) {
        Stop-Processes $BuildToolsDir

        & rimraf $BaseOutputDir --quiet > $null
        & rimraf $BuildToolsDir --quiet > $null
        & rimraf $PackagesDir --quiet > $null
        & rimraf $SourceDir --include  **/bin/**/** --include **/obj/**/** --include  **/debug/**/** --include **/release/**/** --exclude **/node_modules/** --quiet > $null

        Remove-ToolsetVariables

        Exit-WithExitCode 0
    }
}

# createSdkLocationFile parameter enables a file being generated under the toolset directory
# which writes the SDK's location into. This is only necessary for cmd -> PowerShell invocations
# as dot sourcing isn't possible.
function Initialize-DotNetCli([bool] $install, [bool] $createSdkLocationFile) {
    if (Test-Path variable:\global:_DotNetInstallDir) {
        return $global:_DotNetInstallDir
    }

    # Don't resolve runtime, shared framework, or SDK from other locations to ensure build determinism
    $env:DOTNET_MULTILEVEL_LOOKUP = 0

    # Disable first run since we do not need all ASP.NET packages restored.
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1

    # Disable telemetry on CI.
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = 1

    # Source Build uses DotNetCoreSdkDir variable
    if ($null -ne $env:DotNetCoreSdkDir) {
        $env:DOTNET_INSTALL_DIR = $env:DotNetCoreSdkDir
    }

    # Find the first path on %Path% that contains the dotnet.exe
    if ($useInstalledDotNetCli -and ($null -eq $env:DOTNET_INSTALL_DIR)) {
        $dotnetCmd = Get-Command 'dotnet.exe' -ErrorAction SilentlyContinue
        if ($null -ne $dotnetCmd) {
            $env:DOTNET_INSTALL_DIR = Split-Path $dotnetCmd.Path -Parent
        }
    }

    $dotnetSdkVersion = $GlobalJson.tools.dotnet

    # Use dotnet installation specified in DOTNET_INSTALL_DIR if it contains the required SDK version,
    # otherwise install the dotnet CLI and SDK to repo local .dotnet directory to avoid potential permission issues.
    if ($useInstalledDotNetCli -and ($null -ne $env:DOTNET_INSTALL_DIR) -and (Test-Path(Join-Path $env:DOTNET_INSTALL_DIR "sdk/$dotnetSdkVersion"))) {
        $dotnetRoot = $env:DOTNET_INSTALL_DIR
    } else {
        $dotnetRoot = Join-Path $BuildToolsDir 'dotnet'

        if (-not (Test-Path(Join-Path $dotnetRoot "sdk/$dotnetSdkVersion"))) {
            if ($install) {
                Install-DotNetSdk $dotnetRoot $dotnetSdkVersion
            } else {
                Write-Host "Unable to find dotnet with SDK version '$dotnetSdkVersion'" -ForegroundColor Red
                Exit-WithExitCode 1
            }
        }

        $env:DOTNET_INSTALL_DIR = $dotnetRoot
    }

    # Creates a temporary file under the toolset dir.
    # The following code block is protecting against concurrent access so that this function can
    # be called in parallel.
    if ($createSdkLocationFile) {
        do {
            $sdkCacheFileTemp = Join-Path $ToolsetDir $([System.IO.Path]::GetRandomFileName())
        }
        until (-not (Test-Path $sdkCacheFileTemp))

        Set-Content -Path $sdkCacheFileTemp -Value $dotnetRoot

        try {
            Rename-Item -Path $sdkCacheFileTemp 'sdk.txt' -Force
        } catch {
            # Somebody beat us
            Remove-Item -Path $sdkCacheFileTemp
        }
    }

    # Add dotnet to Path. This prevents any bare invocation of dotnet in custom
    # build steps from using anything other than what we've downloaded.
    # It also ensures that VS MSBuild will use the downloaded sdk targets.
    $env:Path = "$dotnetRoot;$env:Path"

    return $global:_DotNetInstallDir = $dotnetRoot
}

function Install-DotNetSdk([string] $dotnetRoot, [string] $version) {
    $installScript = Get-DotNetInstallScript $dotnetRoot
    & $installScript -Version $version -InstallDir $dotnetRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to install dotnet cli (exit code '$LASTEXITCODE')." -ForegroundColor Red
        Exit-WithExitCode $LASTEXITCODE
    }
}

function Get-DotNetInstallScript([string] $dotnetRoot) {
    $installScript = "$dotnetRoot/dotnet-install.ps1"
    if (-not (Test-Path $installScript)) {
        New-Directory $dotnetRoot
        $ProgressPreference = 'SilentlyContinue' # Don't display the console progress UI - it's a huge perf hit

        $maxRetries = 5
        $retries = 1

        $uri = "https://dot.net/$dotnetInstallScriptVersion/dotnet-install.ps1"

        while ($true) {
            try {
                Write-Host "GET $uri"
                Invoke-WebRequest $uri -OutFile $installScript
                break
            } catch {
                Write-Host "Failed to download '$uri'"
                Write-Host $_.Exception.Message $_ -ForegroundColor Red
            }

            if (++$retries -le $maxRetries) {
                $delayInSeconds = [math]::Pow(2, $retries) - 1 # Exponential backoff
                Write-Host "Retrying. Waiting for $delayInSeconds seconds before next attempt ($retries of $maxRetries)."
                Start-Sleep -Seconds $delayInSeconds
            } else {
                throw "Unable to download file in $maxRetries attempts."
            }
        }
    }

    return $installScript
}

#
# Locates Visual Studio MSBuild installation.
# The preference order for MSBuild to use is as follows:
#
#   1. MSBuild from an active VS command prompt
#   2. MSBuild from a compatible VS installation
#   3. MSBuild from the xcopy tool package
#
# Returns full path to msbuild.exe.
# Throws on failure.
#
function Initialize-VisualStudioMSBuild([bool] $install) {
    if (Test-Path variable:\global:_MSBuildExe) {
        return $global:_MSBuildExe
    }

    $vsMinVersionStr = if (-not $GlobalJson.tools.vs.version) { $GlobalJson.tools.vs.version } else { '15.9' }
    $vsMinVersion = [Version]::new($vsMinVersionStr)

    # Try msbuild command available in the environment.
    if ($null -ne $env:VSINSTALLDIR) {
        $msbuildCmd = Get-Command 'msbuild.exe' -ErrorAction SilentlyContinue
        if ($null -ne $msbuildCmd) {
            # Workaround for https://github.com/dotnet/roslyn/issues/35793
            # Due to this issue $msbuildCmd.Version returns 0.0.0.0 for msbuild.exe 16.2+
            $msbuildVersion = [Version]::new((Get-Item $msbuildCmd.Path).VersionInfo.ProductVersion.Split([char[]]@('-', '+'))[0])

            if ($msbuildVersion -ge $vsMinVersion) {
                return $global:_MSBuildExe = $msbuildCmd.Path
            }

            # Report error - the developer environment is initialized with incompatible VS version.
            throw "Developer Command Prompt for VS $($env:VisualStudioVersion) is not recent enough. Please upgrade to $vsMinVersionStr or build from a plain CMD window"
        }
    }

    # Locate Visual Studio installation or download x-copy msbuild.
    $vsInfo = Get-VisualStudioLocation
    if ($null -ne $vsInfo) {
        $vsInstallDir = $vsInfo.installationPath
        $vsMajorVersion = $vsInfo.installationVersion.Split('.')[0]

        Initialize-VisualStudioEnvironmentVariables $vsInstallDir $vsMajorVersion
    } else {
        if (Get-Member -InputObject $GlobalJson.tools -Name 'xcopy-msbuild') {
            $xcopyMSBuildVersion = $GlobalJson.tools.'xcopy-msbuild'
            $vsMajorVersion = $xcopyMSBuildVersion.Split('.')[0]
        } else {
            $vsMajorVersion = $vsMinVersion.Major
            $xcopyMSBuildVersion = "$vsMajorVersion.$($vsMinVersion.Minor).0-alpha"
        }

        $vsInstallDir = $null
        if ($xcopyMSBuildVersion.Trim() -ne 'none') {
            $vsInstallDir = Initialize-XCopyMSBuild $xcopyMSBuildVersion $install
        }

        if ($null -eq $vsInstallDir) {
            throw 'Unable to find Visual Studio that has required version and components installed'
        }
    }

    $msbuildVersionDir = if ([int]$vsMajorVersion -lt 16) { "$vsMajorVersion.0" } else { 'Current' }
    return $global:_MSBuildExe = Join-Path $vsInstallDir "MSBuild/$msbuildVersionDir/Bin/msbuild.exe"
}

#
# Locates Visual Studio instance that meets the minimal requirements specified by tools.vs object in global.json.
#
# The following properties of tools.vs are recognized:
#   "version": "{major}.{minor}"
#       Two part minimal VS version, e.g. "15.9", "16.0", etc.
#   "components": ["componentId1", "componentId2", ...]
#       Array of ids of workload components that must be available in the VS instance.
#       See e.g. https://docs.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-enterprise?view=vs-2017
#
# Returns JSON describing the located VS instance (same format as returned by vswhere),
# or $null if no instance meeting the requirements is found on the machine.
#
function Get-VisualStudioLocation() {
    if (Get-Member -InputObject $GlobalJson.tools -Name 'vswhere') {
        $vswhereVersion = $GlobalJson.tools.vswhere
    } else {
        $vswhereVersion = '2.8.4'
    }

    $vsWhereDir = Join-Path $BuildToolsDir "vswhere/$vswhereVersion"
    $vsWhereExe = Join-Path $vsWhereDir 'vswhere.exe'

    if (-not (Test-Path $vsWhereExe)) {
        New-Directory $vsWhereDir
        Write-Host 'Downloading vswhere'
        Invoke-WebRequest "https://github.com/Microsoft/vswhere/releases/download/$vswhereVersion/vswhere.exe" -OutFile $vswhereExe
    }

    $vs = $GlobalJson.tools.vs

    $args = @('-prerelease', '-requires', 'Microsoft.Component.MSBuild', '-latest', '-format', 'json', '-nologo')

    $productIds = @('Community', 'Professional', 'Enterprise', 'BuildTools') | ForEach-Object { 'Microsoft.VisualStudio.Product.' + $_ }
    $args += '-products'
    $args += $productIds

    if (Get-Member -InputObject $vs -Name 'version') {
        $args += '-version'
        $args += $vs.version
    }

    if (Get-Member -InputObject $vs -Name 'components') {
        foreach ($component in $vs.components) {
            $args += '-requires'
            $args += $component
        }
    }

    $vsInfo = & $vsWhereExe $args | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    # Use first matching instance
    return $vsInfo[0]
}

function Initialize-VisualStudioEnvironmentVariables([string] $vsInstallDir, [string] $vsMajorVersion) {
    $env:VSINSTALLDIR = $vsInstallDir
    Set-Item "env:VS$($vsMajorVersion)0COMNTOOLS" (Join-Path $vsInstallDir 'Common7/Tools/')

    $vsSdkInstallDir = Join-Path $vsInstallDir 'VSSDK/'
    if (Test-Path $vsSdkInstallDir) {
        Set-Item "env:VSSDK$($vsMajorVersion)0Install" $vsSdkInstallDir
        $env:VSSDKInstall = $vsSdkInstallDir
    }
}

function Initialize-XCopyMSBuild([string] $packageVersion, [bool] $install) {
    $packageName = 'RoslynTools.MSBuild'
    $packageDir = Join-Path $BuildToolsDir "msbuild/$packageVersion"
    $packagePath = Join-Path $packageDir "$packageName.$packageVersion.nupkg"

    if (-not (Test-Path $packageDir)) {
        if (-not $install) {
            return $null
        }

        New-Directory $packageDir
        Write-Host "Downloading $packageName $packageVersion"
        $ProgressPreference = 'SilentlyContinue' # Don't display the console progress UI - it's a huge perf hit
        Invoke-WebRequest "https://dotnet.myget.org/F/roslyn-tools/api/v2/package/$packageName/$packageVersion/" -OutFile $packagePath
        Expand-ZipFile $packagePath $packageDir
    }

    return Join-Path $packageDir 'tools'
}

function Get-ToolsetVersion([string] $toolsetPackageDir) {
    $nuspecFile = Get-ChildItem -Path $toolsetPackageDir -Filter '*.nuspec' | Select-Object -First 1
    $nuspecXml = [System.Xml.XmlDocument](Get-Content -Path $nuspecFile -Raw)
    return $nuspecXml.package.metadata.version;
}

function Initialize-Toolset() {
    $toolsetVersion = $GlobalJson.'msbuild-sdks'.'DotNet.Build.Sdk'

    if (Test-Path variable:\global:_ToolsetBuildProj) {
        $toolsetPackageDir = Join-Path ([System.IO.Path]::GetDirectoryName($global:_ToolsetBuildProj)) '../'
        if (Test-Path $toolsetPackageDir) {
            $toolsetVersionInUse = Get-ToolsetVersion $toolsetPackageDir
            if ($toolsetVersionInUse -eq $toolsetVersion) {
                return $global:_ToolsetBuildProj
            }
        }

        Remove-ToolsetVariables
    }

    Clear-NuGetLocalsHttpCache
    Set-NuGetPackageCachePath

    $toolsetLocationFile = Join-Path $ToolsetDir "$toolsetVersion.txt"

    if (Test-Path $toolsetLocationFile) {
        $path = Get-Content $toolsetLocationFile -TotalCount 1
        if (Test-Path $path) {
            return $global:_ToolsetBuildProj = $path
        }
    }

    if (-not $restore) {
        Write-Host "Toolset version $toolsetVersion has not been restored."
        Exit-WithExitCode 1
    }

    $proj = Join-Path $ToolsetDir 'restore.proj'

    '<Project Sdk="DotNet.Build.Sdk" />' | Set-Content $proj
    Invoke-MSBuild `
        /target:'__WriteToolsetLocation' `
        /property:"__ToolsetLocationOutputFile=$toolsetLocationFile" `
        /property:"RestoreNoCache=true" `
        /consoleLoggerParameters:'NoSummary;ErrorsOnly' `
        /fileloggerparameters:"LogFile=$(Join-Path $LogDir 'toolset-restore.log');Verbosity=normal;Encoding=UTF-8" `
        /binaryLogger:"LogFile=$(Join-Path $LogDir 'toolset-restore.binlog')" `
        $proj

    $path = Get-Content $toolsetLocationFile -TotalCount 1
    if (-not (Test-Path $path)) {
        throw "Invalid toolset path: $path"
    }

    return $global:_ToolsetBuildProj = $path
}

function Clear-NuGetLocalsHttpCache() {
    $httpCacheDir = Join-Path $env:LOCALAPPDATA 'NuGet/v3-cache'
    if (Test-Path $httpCacheDir) {
        Write-Host "Clearing NuGet HTTP cache: $httpCacheDir"
        & rimraf $httpCacheDir --quiet > $null
        Write-Host 'Local resources cleared.'
    }
}

function Set-NuGetPackageCachePath() {
    if ($null -eq $env:NUGET_PACKAGES) {
        # Use local cache on CI to ensure deterministic build,
        # use global cache in dev builds to avoid cost of downloading packages.
        if ($useGlobalNuGetCache) {
            $env:NUGET_PACKAGES = Join-Path $env:UserProfile '.nuget/packages'
        } else {
            $env:NUGET_PACKAGES = $PackagesDir
        }
    }
}

function Invoke-MSBuild() {
    if ($ci) {
        if ($nodeReuse) {
            throw 'Node reuse must be disabled in CI build.'
        }
    }

    $buildTool = Initialize-BuildTool

    $cmdArgs = "$($buildTool.Command) /maxcpucount /verbosity:$verbosity /consoleloggerparameters:Summary /filelogger /nodeReuse:$nodeReuse /nologo"

    if ($warnAsError) {
        $cmdArgs += ' /warnaserror /property:TreatWarningsAsErrors=true'
    } else {
        $cmdArgs += ' /property:TreatWarningsAsErrors=false'
    }

    foreach ($arg in $args) {
        if ($null -ne $arg -and $arg.Trim() -ne '') {
            $cmdArgs += " `"$arg`""
        }
    }

    $exitCode = Invoke-Process $buildTool.Path $cmdArgs

    if ($exitCode -ne 0) {
        Write-Host "Build failed (exit code: '$exitCode')." -ForegroundColor Red

        $buildLog = Get-MSBuildLogCommandLineArgument $args
        if ($null -ne $buildLog) {
            Write-Host "See text log: $buildLog" -ForegroundColor DarkGray
        }

        $buildBinLog = Get-MSBuildBinaryLogCommandLineArgument $args
        if ($null -ne $buildBinLog) {
            Write-Host "See binary log: $buildBinLog" -ForegroundColor DarkGray
        }

        Exit-WithExitCode $exitCode
    }
}

function Initialize-BuildTool() {
    if (Test-Path variable:\global:_BuildTool) {
        return $global:_BuildTool
    }

    if (-not $msbuildEngine) {
        $msbuildEngine = Get-DefaultMSBuildEngine
    }

    # Initialize dotnet cli if listed in 'tools'
    $dotnetRoot = $null
    if (Get-Member -InputObject $GlobalJson.tools -Name 'dotnet') {
        $dotnetRoot = Initialize-DotNetCli -install:$restore
    }

    if ($msbuildEngine -eq 'dotnet') {
        if (-not $dotnetRoot) {
            Write-Host "global.json must specify 'tools.dotnet'." -ForegroundColor Red
            Exit-WithExitCode 1
        }

        $buildTool = @{ Path = Join-Path $dotnetRoot 'dotnet.exe'; Command = 'msbuild' }
    } elseif ($msbuildEngine -eq 'vs') {
        try {
            $msbuildPath = Initialize-VisualStudioMSBuild -install:$restore
        } catch {
            Write-Host $_ -ForegroundColor Red
            Exit-WithExitCode 1
        }

        $buildTool = @{ Path = $msbuildPath; Command = '' }
    } else {
        Write-Host "Unexpected value of -msbuildEngine: '$msbuildEngine'." -ForegroundColor Red
        Exit-WithExitCode 1
    }

    return $global:_BuildTool = $buildTool
}

function Get-DefaultMSBuildEngine() {
    # Presence of tools.vs indicates the repo needs to build using VS MSBuild on Windows.
    if (Get-Member -InputObject $GlobalJson.tools -Name 'vs') {
        return 'vs'
    }

    if (Get-Member -InputObject $GlobalJson.tools -Name 'dotnet') {
        return 'dotnet'
    }

    Write-Host "-msbuildEngine must be specified, or global.json must specify 'tools.dotnet' or 'tools.vs'." -ForegroundColor Red
    Exit-WithExitCode 1
}

function Get-MSBuildLogCommandLineArgument([string[]] $arguments) {
    foreach ($argument in $arguments) {
        if ($null -ne $argument) {
            $arg = $argument.Trim()
            if ($arg.StartsWith('/fileloggerparameters:LogFile=', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/fileloggerparameters:LogFile='.Length)
            }

            if ($arg.StartsWith('/flp:LogFile=', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/flp:LogFile='.Length)
            }
        }
    }

    return $null
}

function Get-MSBuildBinaryLogCommandLineArgument([string[]] $arguments) {
    foreach ($argument in $arguments) {
        if ($null -ne $argument) {
            $arg = $argument.Trim()
            if ($arg.StartsWith('/binaryLogger:LogFile=', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/binaryLogger:LogFile='.Length)
            }

            if ($arg.StartsWith('/binaryLogger:', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/binaryLogger:'.Length)
            }

            if ($arg.StartsWith('/bl:LogFile=', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/bl:LogFile='.Length)
            }

            if ($arg.StartsWith('/bl:', 'OrdinalIgnoreCase')) {
                return $arg.Substring('/bl:'.Length)
            }
        }
    }

    return $null
}

$RepoRoot = Resolve-RootDirectory 'global.json'
$EngRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$GlobalJson = Get-Content (Join-Path $RepoRoot 'global.json') -Raw | ConvertFrom-Json
$Config = Get-Config (Join-Path $RepoRoot 'Config.props')
$SourceDir = $Config.SourceDir
$BaseOutputDir = $Config.BaseOutputDir
$BinDir = $Config.BinDir
$PackagesDir = $Config.PackagesDir
$BuildToolsDir = $Config.BuildToolsDir
$ToolsetDir = $Config.ToolsetDir
$TempDir = $Config.TempDir
$LogDir = Join-Path (Join-Path $BaseOutputDir 'log') $configuration

New-Directory $BinDir
New-Directory $BuildToolsDir
New-Directory $ToolsetDir
New-Directory $TempDir
New-Directory $LogDir

# Import custom tools configuration, if present in the repo.
# Note: Import in global scope so that the script set top-level variables without qualification.
if (-not $disableConfigureToolsetImport) {
    $configureToolsetScript = Join-Path $EngRoot 'configure-toolset.ps1'
    if (Test-Path $configureToolsetScript) {
        . $configureToolsetScript
        if ((Test-Path variable:\failOnConfigureToolsetError) -and $failOnConfigureToolsetError) {
            if ((Test-Path variable:\LASTEXITCODE) -and ($LASTEXITCODE -ne 0)) {
                Write-Host 'configure-toolset.ps1 returned a non-zero exit code' -ForegroundColor Red
                Exit-WithExitCode $LASTEXITCODE
            }
        }
    }
}