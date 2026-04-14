<#
.SYNOPSIS
  Builds and validates WindowsAppSDK Samples with a two-stage pipeline-aligned workflow.

.DESCRIPTION
  Two-stage pipeline-aligned workflow matching SDK release validation:
    Build stage: NuGet restore -> MSBuild /t:restore -> MSBuild build (3 steps per solution)
    Run stage:   Validates that expected build artifacts were produced

  All binary logs are centralized in a single directory for easy analysis.
  Continues on failure (never exits early) and writes a JSON report + console summary.

  The build stage mirrors the Azure DevOps pipeline logic in
  WindowsAppSDK-BuildSamplesCompat-Job.yml and SamplesCI-All.yml:
    Step 1: nuget.exe restore (only for solutions with packages.config)
    Step 2: msbuild /t:restore (PackageReference restore, separate from build)
    Step 3: msbuild build (no /restore flag)

.PARAMETER Stage
  Which stage(s) to execute: build, run, or all (default).

.PARAMETER Mode
  Which samples to include: all (default), stable-only, experimental-only.

.PARAMETER Platform
  Target platform: x86, x64, arm64, auto (default). 'auto' picks arm64 on ARM64 OS, else x64.

.PARAMETER Configuration
  Build configuration: Debug or Release (default).

.PARAMETER Sample
  Restrict to a single sample folder name under Samples/, e.g. 'AppLifecycle' or 'WindowsML'.

.PARAMETER BinLogDir
  Directory for centralized binary logs. Default: build-logs under repo root.

.PARAMETER ReportPath
  Path for the JSON report file. Defaults to build-report-<timestamp>.json in the repo root.

.PARAMETER ExtraProperties
  Extra MSBuild properties appended verbatim, e.g.
  '/p:WindowsAppSDKVerifyTransitiveDependencies=false'.

.PARAMETER LocalPackagesDir
  Optional additional NuGet package source directory. Passed as
  /p:RestoreAdditionalProjectSources for pipeline compatibility with local package feeds.

.EXAMPLE
  ./build-report.ps1
  # Build and validate all samples (both stages)

.EXAMPLE
  ./build-report.ps1 -Stage build -Mode stable-only
  # Build only stable samples, skip artifact validation

.EXAMPLE
  ./build-report.ps1 -ExtraProperties '/p:WindowsAppSDKVerifyTransitiveDependencies=false'
  # Build with pipeline-aligned transitive dependency workaround

.EXAMPLE
  ./build-report.ps1 -LocalPackagesDir .\Samples\localpackages
  # Build using a local NuGet package source (matching SDK release pipeline)
#>

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [ValidateSet('build', 'run', 'all')]
    [string]$Stage = 'all',

    [ValidateSet('all', 'stable-only', 'experimental-only')]
    [string]$Mode = 'all',

    [ValidateSet('x86', 'x64', 'arm64', 'auto')]
    [string]$Platform = 'auto',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$Sample = '',

    [string]$BinLogDir = '',

    [string]$ReportPath = '',

    [string]$ExtraProperties = '',

    [string]$LocalPackagesDir = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Experimental sample roots (relative to Samples\).
# Any .sln whose path begins with one of these prefixes is classified 'experimental'.
# ---------------------------------------------------------------------------
$script:ExperimentalPrefixes = @(
    'AppContentSearch',
    'WindowsAIFoundry',
    'WindowsML',
    'WinUI\ConditionalPredicate',
    'WinUI/ConditionalPredicate'
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Initialize-VSEnvironment {
    if (Get-Command msbuild -ErrorAction SilentlyContinue) {
        Write-Host 'MSBuild already on PATH.' -ForegroundColor DarkGray
        return
    }
    if ($env:VSINSTALLDIR) {
        Write-Host "VS environment already initialized: $env:VSINSTALLDIR" -ForegroundColor DarkGray
        return
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        $vswhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (-not (Test-Path $vswhere)) {
        Write-Error 'vswhere.exe not found. Install Visual Studio 2022 with MSBuild.'
        exit 1
    }
    $installPath = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild -property installationPath |
                   Select-Object -First 1
    if (-not $installPath) {
        Write-Error 'No suitable Visual Studio installation found.'
        exit 1
    }
    $devShellDll = Join-Path $installPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (Test-Path $devShellDll) {
        Write-Host "Initializing VS DevShell: $installPath" -ForegroundColor Yellow
        try {
            Import-Module $devShellDll -ErrorAction Stop
            Enter-VsDevShell -VsInstallPath $installPath -SkipAutomaticLocation | Out-Null
        } catch {
            Write-Warning "DevShell init failed: $($_.Exception.Message)"
        }
    }
}

function Resolve-Platform {
    param([string]$Value)
    if ($Value -ne 'auto') { return $Value }
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        switch ($arch) {
            'arm64' { return 'arm64' }
            'x86'   { return 'x64' }
            default { return 'x64' }
        }
    } catch { return 'x64' }
}

function Initialize-NuGet {
    if (-not (Test-Path $script:nugetDir))   { New-Item -ItemType Directory -Path $script:nugetDir   | Out-Null }
    if (-not (Test-Path $script:packagesDir)) { New-Item -ItemType Directory -Path $script:packagesDir | Out-Null }
    if (-not (Test-Path $script:nugetExe)) {
        Write-Host 'Downloading nuget.exe...' -ForegroundColor Yellow
        Invoke-WebRequest -UseBasicParsing https://dist.nuget.org/win-x86-commandline/latest/nuget.exe -OutFile $script:nugetExe
    }
}

function Get-SolutionCategory {
    param([string]$SolutionFullPath)
    $rel = $SolutionFullPath.Substring($script:samplesRoot.Length).TrimStart('\', '/')
    foreach ($prefix in $script:ExperimentalPrefixes) {
        if ($rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'experimental'
        }
    }
    return 'stable'
}

function Get-Solutions {
    param([string]$SampleFilter)
    if (-not [string]::IsNullOrWhiteSpace($SampleFilter)) {
        $dir = Join-Path $script:samplesRoot $SampleFilter
        if (-not (Test-Path $dir)) { Write-Error "Sample not found: $dir"; exit 1 }
        return Get-ChildItem -Path $dir -Filter *.sln -Recurse | Sort-Object FullName
    }
    return Get-ChildItem -Path $script:samplesRoot -Filter *.sln -Recurse | Sort-Object FullName
}

# Returns a unique binlog path by mirroring the Samples directory tree under BinLogDir.
# Naming: {sln-stem}.{step}.{platform}.{config}.binlog  (matches pipeline convention)
function Get-BinLogPath {
    param(
        [string]$SolutionFullPath,
        [string]$Step,
        [string]$ResolvedPlatform,
        [string]$Config
    )
    $relPath  = $SolutionFullPath.Substring($script:samplesRoot.Length).TrimStart('\', '/')
    $relDir   = Split-Path $relPath -Parent
    $slnStem  = [IO.Path]::GetFileNameWithoutExtension($relPath)
    $targetDir = Join-Path $script:binLogDir $relDir
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    return Join-Path $targetDir "$slnStem.$Step.$ResolvedPlatform.$Config.binlog"
}

# Builds the MSBuild argument list for restore or build steps.
# Mirrors the properties passed by the SDK pipeline (VCToolsInstallDir, PublishReadyToRun, etc.)
function Get-MSBuildArgs {
    param(
        [string]$SolutionPath,
        [string]$BinLogPath,
        [string]$ResolvedPlatform,
        [string]$Config,
        [switch]$ForRestore
    )
    $msbArgs = @('/m')

    if ($ForRestore) {
        $msbArgs += '/t:restore'
        # PublishReadyToRun only in restore step (matches both SamplesCI-All.yml and Aggregator pipeline)
        $msbArgs += '/p:PublishReadyToRun=true'
    }

    $msbArgs += "/p:Platform=$ResolvedPlatform"
    $msbArgs += "/p:Configuration=$Config"
    $msbArgs += "/p:NugetPackageDirectory=$script:packagesDir"

    # VCToolsInstallDir: prefer the value set by DevShell; the pipeline detects it via VsDevCmd.bat
    if ($env:VCToolsInstallDir) {
        $vcDir = $env:VCToolsInstallDir.TrimEnd('\')
        $msbArgs += "/p:VCToolsInstallDir=$vcDir\"
    }

    # LocalPackagesDir maps to RestoreAdditionalProjectSources in the Aggregator pipeline
    if (-not [string]::IsNullOrWhiteSpace($script:localPkgDir)) {
        $msbArgs += "/p:RestoreAdditionalProjectSources=$($script:localPkgDir)"
    }

    $msbArgs += "/bl:$BinLogPath"

    # Extra user properties (e.g. /p:WindowsAppSDKVerifyTransitiveDependencies=false)
    if (-not [string]::IsNullOrWhiteSpace($ExtraProperties)) {
        $ExtraProperties.Trim() -split '\s+(?=/)' | Where-Object { $_ } | ForEach-Object { $msbArgs += $_ }
    }

    $msbArgs += $SolutionPath
    return $msbArgs
}

# Step 1: NuGet restore for packages.config projects only (conditional — skips if none found)
function Invoke-NuGetRestore {
    param([string]$SolutionPath)
    $hasPackagesConfig = @(Get-ChildItem -Path (Split-Path $SolutionPath -Parent) -Filter packages.config -Recurse -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasPackagesConfig) { return $true }

    Write-Host "  [nuget] Restoring packages.config..." -ForegroundColor DarkCyan
    & $script:nugetExe restore $SolutionPath `
        -ConfigFile (Join-Path $script:samplesRoot 'nuget.config') `
        -PackagesDirectory $script:packagesDir | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Step 2: MSBuild /t:restore (PackageReference restore, separate from build)
function Invoke-MSBuildRestore {
    param([string]$SolutionPath, [string]$BinLogPath)

    Write-Host "  [restore] MSBuild /t:restore..." -ForegroundColor DarkCyan
    $msbArgs = Get-MSBuildArgs -SolutionPath $SolutionPath -BinLogPath $BinLogPath `
        -ResolvedPlatform $script:resolvedPlatform -Config $Configuration -ForRestore

    $output = & msbuild @msbArgs 2>&1
    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

# Step 3: MSBuild build (no /restore flag — restore already done in step 2)
function Invoke-MSBuildBuild {
    param([string]$SolutionPath, [string]$BinLogPath)

    Write-Host "  [build]   MSBuild build..." -ForegroundColor DarkCyan
    $msbArgs = Get-MSBuildArgs -SolutionPath $SolutionPath -BinLogPath $BinLogPath `
        -ResolvedPlatform $script:resolvedPlatform -Config $Configuration

    $output = & msbuild @msbArgs 2>&1
    $exitCode = $LASTEXITCODE

    # Extract warning/error counts from MSBuild summary line
    $warnings = 0; $errors = 0
    $output | Select-String '(\d+) Warning\(s\)'  | ForEach-Object { $warnings = [int]$_.Matches[0].Groups[1].Value }
    $output | Select-String '(\d+) Error\(s\)'    | ForEach-Object { $errors   = [int]$_.Matches[0].Groups[1].Value }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Warnings = $warnings
        Errors   = $errors
        Output   = $output
    }
}

# Run stage: find build artifacts (.exe, .msix, .appx) for a solution
function Find-BuildOutputs {
    param(
        [string]$SolutionPath,
        [string]$ResolvedPlatform,
        [string]$Config
    )
    $solutionDir = Split-Path $SolutionPath -Parent
    $outputs = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    # Search the solution dir and one level of project subdirectories
    $searchRoots = @($solutionDir)
    $searchRoots += @(Get-ChildItem -Path $solutionDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    foreach ($root in $searchRoots) {
        # Check common output paths matching platform/config
        $exes = Get-ChildItem -Path $root -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notmatch '\\obj\\' -and
                    $_.FullName -notmatch '\\packages\\' -and
                    $_.Name -notmatch '^(createdump|hostfxr|hostpolicy|dotnet|csc|vbc)\.' -and
                    ($_.FullName -match "\\$Config\\" -or $_.FullName -match "\\$ResolvedPlatform\\")
                }
        foreach ($e in $exes) { $outputs.Add($e) }

        $packages = Get-ChildItem -Path $root -Include '*.msix', '*.appx' -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\obj\\' }
        foreach ($p in $packages) { $outputs.Add($p) }
    }

    return $outputs
}

# Add a result record to the results list
function Add-Result {
    param(
        [string]$Solution,
        [string]$Category,
        [string]$Phase,
        [string]$Step,
        [string]$Status,
        [int]$ExitCode,
        [int]$Warnings,
        [int]$Errors,
        [double]$Duration,
        [string]$BinLog
    )
    $script:results.Add([PSCustomObject]@{
        Solution = $Solution
        Category = $Category
        Phase    = $Phase
        Step     = $Step
        Status   = $Status
        ExitCode = $ExitCode
        Warnings = $Warnings
        Errors   = $Errors
        Duration = $Duration
        BinLog   = $BinLog
    })
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Initialize-VSEnvironment
if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) {
    Write-Error 'msbuild not found. Run from a VS Developer PowerShell or ensure MSBuild is on PATH.'
    exit 1
}

$script:resolvedPlatform = Resolve-Platform -Value $Platform
$repoRoot                = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:nugetDir         = Join-Path $repoRoot '.nuget'
$script:nugetExe         = Join-Path $script:nugetDir 'nuget.exe'
$script:packagesDir      = Join-Path $repoRoot 'packages'
$script:samplesRoot      = Join-Path $repoRoot 'Samples'
$script:localPkgDir      = $LocalPackagesDir

# Centralized binlog directory
if ([string]::IsNullOrWhiteSpace($BinLogDir)) {
    $script:binLogDir = Join-Path $repoRoot 'build-logs'
} else {
    $script:binLogDir = $BinLogDir
}
if (-not (Test-Path $script:binLogDir)) {
    New-Item -ItemType Directory -Path $script:binLogDir -Force | Out-Null
}

Initialize-NuGet

$allSolutions = Get-Solutions -SampleFilter $Sample
if (-not $allSolutions -or $allSolutions.Count -eq 0) {
    Write-Warning 'No solutions found.'
    exit 0
}

# Apply Mode filter
$solutions = @($allSolutions | Where-Object {
    $cat = Get-SolutionCategory -SolutionFullPath $_.FullName
    switch ($Mode) {
        'stable-only'       { $cat -eq 'stable' }
        'experimental-only' { $cat -eq 'experimental' }
        default             { $true }
    }
})

$total = $solutions.Count
Write-Host ''
Write-Host "=== build-report.ps1 ===" -ForegroundColor Cyan
Write-Host "Stage=$Stage  Mode=$Mode  Platform=$($script:resolvedPlatform)  Configuration=$Configuration" -ForegroundColor Cyan
if ($ExtraProperties)  { Write-Host "ExtraProperties=$ExtraProperties" -ForegroundColor Cyan }
if ($LocalPackagesDir) { Write-Host "LocalPackagesDir=$LocalPackagesDir" -ForegroundColor Cyan }
Write-Host "BinLogDir=$($script:binLogDir)" -ForegroundColor Cyan
Write-Host "Solutions: $total" -ForegroundColor Cyan
Write-Host ''

$script:results = [System.Collections.Generic.List[PSCustomObject]]::new()
$scriptSw       = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# BUILD STAGE
# Pipeline-aligned 3-step build: nuget restore -> msbuild /t:restore -> msbuild build
# ---------------------------------------------------------------------------
if ($Stage -eq 'build' -or $Stage -eq 'all') {
    Write-Host ('-' * 60) -ForegroundColor Cyan
    Write-Host ' BUILD STAGE' -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor Cyan

    $idx = 0
    foreach ($sln in $solutions) {
        $idx++
        $relPath  = $sln.FullName.Substring($script:samplesRoot.Length).TrimStart('\', '/')
        $category = Get-SolutionCategory -SolutionFullPath $sln.FullName

        Write-Host ''
        Write-Host "[$idx/$total] $relPath  ($category)" -ForegroundColor $(if ($category -eq 'experimental') { 'Yellow' } else { 'White' })

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Step 1: NuGet restore (packages.config only — conditional)
        $restoreOk = Invoke-NuGetRestore -SolutionPath $sln.FullName
        if (-not $restoreOk) {
            $sw.Stop()
            Write-Host "  FAIL (NuGet restore)" -ForegroundColor Red
            Add-Result -Solution $relPath -Category $category -Phase 'build' -Step 'nuget-restore' `
                -Status 'FAIL' -ExitCode 1 -Warnings 0 -Errors 0 -Duration $sw.Elapsed.TotalSeconds -BinLog ''
            continue
        }

        # Step 2: MSBuild /t:restore
        $restoreBinLog = Get-BinLogPath -SolutionFullPath $sln.FullName -Step 'restore' `
            -ResolvedPlatform $script:resolvedPlatform -Config $Configuration
        $restoreResult = Invoke-MSBuildRestore -SolutionPath $sln.FullName -BinLogPath $restoreBinLog
        if ($restoreResult.ExitCode -ne 0) {
            $sw.Stop()
            $restoreResult.Output | Out-File -FilePath ($restoreBinLog -replace '\.binlog$', '.log') -Encoding utf8
            Write-Host ("  FAIL (MSBuild restore)  ({0:F1}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Red
            Add-Result -Solution $relPath -Category $category -Phase 'build' -Step 'msbuild-restore' `
                -Status 'FAIL' -ExitCode $restoreResult.ExitCode -Warnings 0 -Errors 0 `
                -Duration $sw.Elapsed.TotalSeconds -BinLog $restoreBinLog
            continue
        }

        # Step 3: MSBuild build (no /restore — already restored in step 2)
        $buildBinLog = Get-BinLogPath -SolutionFullPath $sln.FullName -Step 'build' `
            -ResolvedPlatform $script:resolvedPlatform -Config $Configuration
        $buildResult = Invoke-MSBuildBuild -SolutionPath $sln.FullName -BinLogPath $buildBinLog
        $buildResult.Output | Out-File -FilePath ($buildBinLog -replace '\.binlog$', '.log') -Encoding utf8

        $sw.Stop()
        $status = if ($buildResult.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
        $color  = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
        Write-Host ("  {0}  ({1:F1}s)  warnings={2}  errors={3}" -f $status, $sw.Elapsed.TotalSeconds, $buildResult.Warnings, $buildResult.Errors) -ForegroundColor $color

        Add-Result -Solution $relPath -Category $category -Phase 'build' -Step 'msbuild-build' `
            -Status $status -ExitCode $buildResult.ExitCode -Warnings $buildResult.Warnings `
            -Errors $buildResult.Errors -Duration $sw.Elapsed.TotalSeconds -BinLog $buildBinLog
    }
}

# ---------------------------------------------------------------------------
# RUN STAGE (artifact validation)
# Verifies that expected build outputs (.exe, .msix, .appx) were produced.
# TAEF-based testing is available in the SDK pipeline (TestAll.ps1) but not locally.
# ---------------------------------------------------------------------------
if ($Stage -eq 'run' -or $Stage -eq 'all') {
    Write-Host ''
    Write-Host ('-' * 60) -ForegroundColor Cyan
    Write-Host ' RUN STAGE (artifact validation)' -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor Cyan

    $idx = 0
    foreach ($sln in $solutions) {
        $idx++
        $relPath  = $sln.FullName.Substring($script:samplesRoot.Length).TrimStart('\', '/')
        $category = Get-SolutionCategory -SolutionFullPath $sln.FullName

        # If build stage ran and failed for this solution, skip the run check
        $priorBuild = $script:results | Where-Object { $_.Solution -eq $relPath -and $_.Phase -eq 'build' } | Select-Object -Last 1
        if ($priorBuild -and $priorBuild.Status -eq 'FAIL') {
            Write-Host "[$idx/$total] $relPath  SKIP (build failed)" -ForegroundColor DarkGray
            Add-Result -Solution $relPath -Category $category -Phase 'run' -Step 'artifact-check' `
                -Status 'SKIP' -ExitCode -1 -Warnings 0 -Errors 0 -Duration 0 -BinLog ''
            continue
        }

        $outputs = Find-BuildOutputs -SolutionPath $sln.FullName -ResolvedPlatform $script:resolvedPlatform -Config $Configuration
        $count   = if ($outputs) { @($outputs).Count } else { 0 }
        $status  = if ($count -gt 0) { 'PASS' } else { 'FAIL' }
        $color   = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
        Write-Host "[$idx/$total] $relPath  $status ($count artifact(s))" -ForegroundColor $color

        Add-Result -Solution $relPath -Category $category -Phase 'run' -Step 'artifact-check' `
            -Status $status -ExitCode $(if ($status -eq 'PASS') { 0 } else { 1 }) `
            -Warnings 0 -Errors 0 -Duration 0 -BinLog ''
    }
}

$scriptSw.Stop()

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
$buildResults = @($script:results | Where-Object Phase -eq 'build')
$runResults   = @($script:results | Where-Object { $_.Phase -eq 'run' -and $_.Status -ne 'SKIP' })

$buildPassed  = @($buildResults | Where-Object Status -eq 'PASS')
$buildFailed  = @($buildResults | Where-Object Status -eq 'FAIL')
$runPassed    = @($runResults   | Where-Object Status -eq 'PASS')
$runFailed    = @($runResults   | Where-Object Status -eq 'FAIL')

$totalWarnings     = ($buildResults | Measure-Object Warnings -Sum).Sum
$stableBuildPassed = @($buildPassed | Where-Object Category -eq 'stable').Count
$stableBuildFailed = @($buildFailed | Where-Object Category -eq 'stable').Count
$expBuildPassed    = @($buildPassed | Where-Object Category -eq 'experimental').Count
$expBuildFailed    = @($buildFailed | Where-Object Category -eq 'experimental').Count
$totalDuration     = [System.String]::Format('{0:hh\:mm\:ss}', $scriptSw.Elapsed)

Write-Host ''
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ' BUILD REPORT SUMMARY' -ForegroundColor Cyan
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ("  Total:          {0,3} solutions   ({1} elapsed)" -f $total, $totalDuration)

if ($buildResults.Count -gt 0) {
    Write-Host ''
    Write-Host '  Build Stage:' -ForegroundColor Cyan
    Write-Host ("    Passed:       {0,3}" -f $buildPassed.Count) -ForegroundColor Green
    Write-Host ("    Failed:       {0,3}" -f $buildFailed.Count) -ForegroundColor $(if ($buildFailed.Count -gt 0) { 'Red' } else { 'Green' })
    Write-Host ("    Warnings:     {0,3}" -f $totalWarnings)
    Write-Host ("    Stable:       PASS={0}  FAIL={1}" -f $stableBuildPassed, $stableBuildFailed)
    Write-Host ("    Experimental: PASS={0}  FAIL={1}" -f $expBuildPassed, $expBuildFailed)
}

if ($runResults.Count -gt 0) {
    Write-Host ''
    Write-Host '  Run Stage (artifact validation):' -ForegroundColor Cyan
    Write-Host ("    Passed:       {0,3}" -f $runPassed.Count) -ForegroundColor Green
    Write-Host ("    Failed:       {0,3}" -f $runFailed.Count) -ForegroundColor $(if ($runFailed.Count -gt 0) { 'Red' } else { 'Green' })
}

$allFailed = @($script:results | Where-Object Status -eq 'FAIL')
if ($allFailed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Failed:' -ForegroundColor Red
    foreach ($r in $allFailed) {
        Write-Host ("    [{0}] {1}  ({2}/{3})" -f $r.Category, $r.Solution, $r.Phase, $r.Step) -ForegroundColor Red
        if ($r.BinLog) {
            Write-Host ("           binlog: {0}" -f $r.BinLog) -ForegroundColor DarkRed
        }
    }
}
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# JSON report
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ReportPath = Join-Path $repoRoot "build-report-$timestamp.json"
}

$reportData = [PSCustomObject]@{
    GeneratedAt      = (Get-Date -Format 'o')
    Stage            = $Stage
    Mode             = $Mode
    Platform         = $script:resolvedPlatform
    Configuration    = $Configuration
    ExtraProperties  = $ExtraProperties
    LocalPackagesDir = $LocalPackagesDir
    BinLogDir        = $script:binLogDir
    TotalSolutions   = $total
    Build            = [PSCustomObject]@{
        Passed   = $buildPassed.Count
        Failed   = $buildFailed.Count
        Warnings = $totalWarnings
    }
    Run              = [PSCustomObject]@{
        Passed  = $runPassed.Count
        Failed  = $runFailed.Count
        Skipped = @($script:results | Where-Object { $_.Phase -eq 'run' -and $_.Status -eq 'SKIP' }).Count
    }
    ElapsedSeconds   = $scriptSw.Elapsed.TotalSeconds
    Results          = $script:results
}
$reportData | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding utf8

Write-Host ''
Write-Host "JSON report:  $ReportPath" -ForegroundColor DarkGray
Write-Host "Binary logs:  $($script:binLogDir)" -ForegroundColor DarkGray
