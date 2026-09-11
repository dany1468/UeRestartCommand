#Requires -Version 7.0
<#
.SYNOPSIS
    Host-side orchestrator for the UeRestartCommand development loop.

.DESCRIPTION
    Drives the outer loop that the editor itself cannot: save -> exit -> full
    build -> relaunch. Because it runs outside the editor process it also works
    when the editor is already closed or has crashed, which is the one thing an
    in-editor tool can never do.

    Editor-side work (saving, exiting) is delegated to the UeRestartCommand
    plugin's Python API over Unreal's Python Remote Execution, invoked through
    ue-python-cli. Everything that needs the editor to be dead or absent lives
    here.

.NOTES
    Windows / PowerShell 7 only, by design.
    See THIRD_PARTY_NOTICES.md for the soft-ue-cli (MIT) material this adapts.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('rebuild', 'launch', 'wait-ready', 'status', 'resolve-engine')]
    [string]$Command = 'rebuild',

    # Path to the .uproject, or a directory containing one. Defaults to the
    # nearest .uproject found walking up from the current directory.
    [string]$Project,

    [ValidateSet('Debug', 'DebugGame', 'Development', 'Shipping', 'Test')]
    [string]$Config = 'Development',

    # Exit without saving dirty packages. Default is to save.
    [switch]$NoSave,

    # Build only; do not relaunch the editor afterwards.
    [switch]$NoLaunch,

    # After relaunching, block until the editor accepts Python remote execution.
    [switch]$WaitReady,

    # Terminate the editor if it does not exit within -ExitTimeout. Off by
    # default: killing the editor can lose unsaved work.
    [switch]$Force,

    # Do not retry a failed build with -NoUBA -NoXGE.
    [switch]$NoLocalBuildFallback,

    # Leave Saved/PackageRestoreData.json in place (the editor will then show
    # its "restore packages?" modal on the next launch).
    [switch]$NoSkipPackageRestore,

    [int]$ExitTimeout = 120,
    [int]$ReadyTimeout = 300
)

$ErrorActionPreference = 'Stop'

# Measured default on PowerShell 7.6.6 is $false, but pin it explicitly: if a
# profile or a future PowerShell default flipped this to $true, Build.bat's
# non-zero exit would throw instead of landing in $LASTEXITCODE, and the
# -NoUBA -NoXGE retry below would never be reached.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------

$script:StatusPath   = $null
$script:BuildLogPath = $null
$script:EngineDir    = $null
$script:EngineSource = $null
$script:LastStatus   = $null
$script:StartedAt    = (Get-Date).ToUniversalTime().ToString('o')

# Command functions report their outcome through this rather than by returning
# it. A function that both returns a code and writes to the output stream would
# have its real output captured into the caller's assignment and never reach
# stdout, which is exactly the trap these commands fall into.
$script:ExitCode = 1

$script:UePythonCliSpec = if ($env:UE_PYTHON_CLI_SPEC) {
    $env:UE_PYTHON_CLI_SPEC
} else {
    'git+https://github.com/self-taught-code-tokushima/ue-python-cli'
}

# ---------------------------------------------------------------------------
# Logging and status
# ---------------------------------------------------------------------------

function Write-DevLog {
    param([string]$Message, [string]$Color = 'Gray')

    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($script:BuildLogPath) {
        try {
            Add-Content -LiteralPath $script:BuildLogPath -Value $line -Encoding utf8
        } catch {
            # Logging must never take the run down.
        }
    }
}

<#
    Stage transitions:
      waiting_for_editor_exit -> building [-> building_local_fallback]
        -> relaunching -> completed
      terminal failures: build_failed | editor_exit_timeout | worker_error
#>
function Write-BuildStatus {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [bool]$Complete = $false,
        [bool]$Success = $false,
        $ExitCode = $null,
        [string]$Message = '',
        [string]$ErrorText = ''
    )

    $payload = [ordered]@{
        schema_version   = 1
        stage            = $Stage
        complete         = $Complete
        success          = $Success
        exit_code        = $ExitCode
        message          = $Message
        started_at       = $script:StartedAt
        updated_at       = (Get-Date).ToUniversalTime().ToString('o')
        build_log_path   = $script:BuildLogPath
        orchestrator_pid = $PID
        engine_dir       = $script:EngineDir
        engine_source    = $script:EngineSource
    }
    if ($ErrorText) { $payload['error'] = $ErrorText }

    $script:LastStatus = $payload

    if ($script:StatusPath) {
        try {
            # -Depth is explicit: ConvertTo-Json defaults to 2 and would
            # silently truncate if this payload ever grows nested fields.
            # PowerShell 7 writes UTF-8 without BOM, so readers use plain utf-8.
            $json = $payload | ConvertTo-Json -Depth 5 -Compress
            Set-Content -LiteralPath $script:StatusPath -Value $json -Encoding utf8
        } catch {
            Write-Host "Could not write status file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Write-FinalStatus {
    # One machine-readable line on stdout so a caller gets the outcome without
    # having to go read the status file.
    if ($script:LastStatus) {
        Write-Output ($script:LastStatus | ConvertTo-Json -Depth 5 -Compress)
    }
}

# ---------------------------------------------------------------------------
# Project and engine resolution
# ---------------------------------------------------------------------------

function Resolve-UProject {
    param([string]$Hint)

    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint)) {
            throw "Project path not found: $Hint"
        }
        $item = Get-Item -LiteralPath $Hint
        if ($item.PSIsContainer) {
            $found = Get-ChildItem -LiteralPath $item.FullName -Filter '*.uproject' -File |
                     Select-Object -First 1
            if (-not $found) { throw "No .uproject found in $($item.FullName)" }
            return $found.FullName
        }
        return $item.FullName
    }

    $dir = (Get-Location).Path
    while ($dir) {
        $found = Get-ChildItem -LiteralPath $dir -Filter '*.uproject' -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    throw "No .uproject found at or above $((Get-Location).Path). Pass -Project."
}

function Test-UsableEngineDir {
    param([string]$Dir)

    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }

    # Same two-file check soft-ue-cli's IsUsableEngineDir() uses.
    return (Test-Path -LiteralPath (Join-Path $Dir 'Build/BatchFiles/Build.bat') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $Dir 'Binaries/Win64/UnrealEditor.exe') -PathType Leaf)
}

function ConvertTo-EngineDir {
    # Accepts either an engine root (...\UE_5.8) or its Engine subdir, and
    # returns the normalized Engine dir, or $null if neither is usable.
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    $c = $Candidate.Trim().TrimEnd('\', '/')
    if (Test-UsableEngineDir $c) { return (Get-Item -LiteralPath $c).FullName }

    $withEngine = Join-Path $c 'Engine'
    if (Test-UsableEngineDir $withEngine) { return (Get-Item -LiteralPath $withEngine).FullName }

    return $null
}

function Get-RegistryValue {
    param([string]$Key, [string]$Name)

    try {
        $props = Get-ItemProperty -LiteralPath $Key -ErrorAction Stop
        $prop = $props.PSObject.Properties[$Name]
        if ($prop) { return [string]$prop.Value }
    } catch {
        # An absent key is the normal case, not an error.
    }
    return $null
}

function Resolve-EngineDir {
    <#
        Resolution order matters. The %ProgramFiles%\Epic Games sweep that
        soft-ue-cli relies on is LAST, because engines installed to a custom
        location (E:\UE\UE_5.8 here) are invisible to it. The launcher manifest
        is the source that actually covers that case.
    #>
    param([string]$UProjectPath)

    $tried = [System.Collections.Generic.List[string]]::new()
    $assoc = ''

    try {
        $json = Get-Content -LiteralPath $UProjectPath -Raw -Encoding utf8 | ConvertFrom-Json
        $prop = $json.PSObject.Properties['EngineAssociation']
        if ($prop) { $assoc = ([string]$prop.Value).Trim() }
    } catch {
        # Fall through with an empty association; the override may still work.
    }

    # 0. Explicit override beats everything.
    if ($env:UE_ENGINE_DIR) {
        $tried.Add("env:UE_ENGINE_DIR = $($env:UE_ENGINE_DIR)")
        $d = ConvertTo-EngineDir $env:UE_ENGINE_DIR
        if ($d) {
            return [pscustomobject]@{ Dir = $d; Source = 'env_ue_engine_dir'; Association = $assoc; Tried = $tried }
        }
    }

    if ($assoc) {
        # 1. Association is already an absolute path.
        if ([System.IO.Path]::IsPathRooted($assoc)) {
            $tried.Add("association (absolute) = $assoc")
            $d = ConvertTo-EngineDir $assoc
            if ($d) {
                return [pscustomobject]@{ Dir = $d; Source = 'association_absolute'; Association = $assoc; Tried = $tried }
            }
        }

        # 2. Registered builds. Source builds associate by GUID and only appear here.
        foreach ($hive in @('HKCU:\Software\Epic Games\Unreal Engine\Builds',
                            'HKLM:\SOFTWARE\Epic Games\Unreal Engine\Builds')) {
            $v = Get-RegistryValue -Key $hive -Name $assoc
            if ($v) {
                $tried.Add("$hive :: $assoc = $v")
                $d = ConvertTo-EngineDir $v
                if ($d) {
                    return [pscustomobject]@{ Dir = $d; Source = 'registry_builds'; Association = $assoc; Tried = $tried }
                }
            }
        }

        # 3. Launcher manifest. Covers engines installed outside %ProgramFiles%.
        $manifest = Join-Path $env:ProgramData 'Epic/UnrealEngineLauncher/LauncherInstalled.dat'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            try {
                $m = Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json
                $want = "UE_$assoc"
                foreach ($entry in $m.InstallationList) {
                    if ($entry.ArtifactId -eq $want -or $entry.AppName -eq $want) {
                        $tried.Add("LauncherInstalled.dat :: $want = $($entry.InstallLocation)")
                        $d = ConvertTo-EngineDir $entry.InstallLocation
                        if ($d) {
                            return [pscustomobject]@{ Dir = $d; Source = 'launcher_installed_dat'; Association = $assoc; Tried = $tried }
                        }
                    }
                }
            } catch {
                $tried.Add("LauncherInstalled.dat unreadable: $($_.Exception.Message)")
            }
        } else {
            $tried.Add("LauncherInstalled.dat not present at $manifest")
        }

        # 4. Per-version install key.
        $key = "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$assoc"
        $v = Get-RegistryValue -Key $key -Name 'InstalledDirectory'
        if ($v) {
            $tried.Add("$key :: InstalledDirectory = $v")
            $d = ConvertTo-EngineDir $v
            if ($d) {
                return [pscustomobject]@{ Dir = $d; Source = 'registry_installed_directory'; Association = $assoc; Tried = $tried }
            }
        }

        # 5. Default install location sweep. Last resort.
        $roots = @($env:ProgramFiles, ${env:ProgramW6432}, ${env:ProgramFiles(x86)}) |
                 Where-Object { $_ } |
                 ForEach-Object { Join-Path $_ 'Epic Games' } |
                 Select-Object -Unique
        foreach ($root in $roots) {
            foreach ($candidate in @((Join-Path $root "UE_$assoc"), (Join-Path $root $assoc))) {
                $tried.Add($candidate)
                $d = ConvertTo-EngineDir $candidate
                if ($d) {
                    return [pscustomobject]@{ Dir = $d; Source = 'program_files_scan'; Association = $assoc; Tried = $tried }
                }
            }
        }
    } else {
        $tried.Add('.uproject has no EngineAssociation field')
    }

    return [pscustomobject]@{ Dir = $null; Source = $null; Association = $assoc; Tried = $tried }
}

# ---------------------------------------------------------------------------
# Editor process control
# ---------------------------------------------------------------------------

function Get-CommandLineUProject {
    <#
        Pulls every .uproject argument out of a command line and returns it as
        an absolute path.

        A substring match against the absolute .uproject path is NOT enough:
        the editor is routinely launched with the project written relative to
        the engine's Binaries\Win64 directory, e.g.
            "E:\UE\UE_5.8\Engine\Binaries\Win64\UnrealEditor.exe"
            "../../../../../UnrealProjects/.../URC_Sample.uproject"
        which shares no common substring with the absolute path at all.
    #>
    param([string]$CommandLine, [string]$ExecutablePath)

    $resolved = @()
    $tokenMatches = [regex]::Matches(
        $CommandLine,
        '"(?<quoted>[^"]*\.uproject)"|(?<bare>\S+\.uproject)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $tokenMatches) {
        $token = if ($m.Groups['quoted'].Success) {
            $m.Groups['quoted'].Value
        } else {
            $m.Groups['bare'].Value
        }
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        try {
            if ([System.IO.Path]::IsPathRooted($token)) {
                $resolved += [System.IO.Path]::GetFullPath($token)
            } elseif ($ExecutablePath) {
                $baseDir = Split-Path -Parent $ExecutablePath
                $resolved += [System.IO.Path]::GetFullPath((Join-Path $baseDir $token))
            }
        } catch {
            # An unparseable token just is not a match.
        }
    }
    return $resolved
}

function Get-ProjectEditorProcess {
    <#
        soft-ue-cli runs inside the editor and therefore knows its own PID.
        We do not, and the user may well have several editors open, so identify
        the ones whose command line names this exact project.
    #>
    param([string]$UProjectPath)

    $matched = @()
    try {
        $procs = Get-CimInstance -ClassName Win32_Process `
                                 -Filter "Name='UnrealEditor.exe'" -ErrorAction Stop
    } catch {
        Write-DevLog "Could not enumerate processes: $($_.Exception.Message)" 'Yellow'
        return $matched
    }

    $target = [System.IO.Path]::GetFullPath($UProjectPath)
    foreach ($p in $procs) {
        $cmdLine = [string]$p.CommandLine
        if (-not $cmdLine) { continue }

        $candidates = Get-CommandLineUProject -CommandLine $cmdLine `
                                              -ExecutablePath ([string]$p.ExecutablePath)
        foreach ($candidate in $candidates) {
            if ($candidate.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
                $matched += $p
                break
            }
        }
    }
    return $matched
}

function Invoke-UePythonCli {
    param([string[]]$Arguments)

    if (-not (Get-Command uvx -ErrorAction SilentlyContinue)) {
        throw 'uvx was not found on PATH. Install uv: https://docs.astral.sh/uv/'
    }

    $all = @('--from', $script:UePythonCliSpec, 'ue-python') + $Arguments

    $prevNative = $PSNativeCommandUseErrorActionPreference
    $prevEap = $ErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $code = $null
    try {
        $output = & uvx @all 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
        $ErrorActionPreference = $prevEap
    }

    if ($null -eq $code) { $code = 0 }
    return [pscustomobject]@{ ExitCode = [int]$code; Output = $output }
}

function Stop-ProjectEditor {
    # Returns $true if no editor for this project is running any more.
    param(
        [string]$UProjectPath,
        [bool]$SaveFirst,
        [int]$TimeoutSeconds,
        [bool]$ForceKill
    )

    $procs = @(Get-ProjectEditorProcess -UProjectPath $UProjectPath)
    if ($procs.Count -eq 0) {
        # Not a failure: building with no editor running is the whole point of
        # keeping this outside the editor.
        Write-DevLog 'No editor running for this project; going straight to build.' 'Cyan'
        return $true
    }

    $editorPids = @($procs | ForEach-Object { [int]$_.ProcessId })
    Write-DevLog "Editor process(es) for this project: $($editorPids -join ', ')" 'Cyan'
    Write-BuildStatus -Stage 'waiting_for_editor_exit' `
                      -Message "Asking editor ($($editorPids -join ',')) to exit."

    $fn = if ($SaveFirst) { 'save_and_exit_editor()' } else { 'exit_editor()' }
    Write-DevLog "Sending to editor: $fn"

    $result = Invoke-UePythonCli -Arguments @('exec', $fn)
    if ($result.Output.Trim()) { Write-DevLog $result.Output.Trim() }
    if ($result.ExitCode -ne 0) {
        # The editor may still be shutting down cleanly; the process wait below
        # is the real signal, so do not give up here.
        Write-DevLog "ue-python exec exited $($result.ExitCode); still waiting on the process." 'Yellow'
    }

    foreach ($editorPid in $editorPids) {
        Wait-Process -Id $editorPid -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue

        if (Get-Process -Id $editorPid -ErrorAction SilentlyContinue) {
            if (-not $ForceKill) {
                Write-DevLog "Editor $editorPid still running after $TimeoutSeconds s." 'Red'
                return $false
            }
            Write-DevLog "Editor $editorPid did not exit; -Force given, terminating." 'Yellow'
            Stop-Process -Id $editorPid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $editorPid -Timeout 30 -ErrorAction SilentlyContinue
            if (Get-Process -Id $editorPid -ErrorAction SilentlyContinue) {
                Write-DevLog "Could not terminate editor $editorPid." 'Red'
                return $false
            }
        }
    }

    Write-DevLog 'Editor exited.' 'Green'
    return $true
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

function Invoke-BuildBat {
    param([string]$BuildBat, [string[]]$BuildArgs)

    # Build.bat writes warnings to stderr and signals failure through its exit
    # code. Keep native-command error handling relaxed across this call so a
    # failure lands in $LASTEXITCODE rather than throwing past the retry.
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $prevEap = $ErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'

    $script:LastBuildHadCompileError = $false
    $code = $null
    try {
        Write-DevLog ('> "{0}" {1}' -f $BuildBat, ($BuildArgs -join ' '))
        & $BuildBat @BuildArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            if (-not $script:LastBuildHadCompileError -and
                $line -match 'OtherCompilationError|\): (?:fatal )?error [A-Z]+\d+') {
                $script:LastBuildHadCompileError = $true
            }
            Write-Host $line
            try {
                Add-Content -LiteralPath $script:BuildLogPath -Value $line -Encoding utf8
            } catch { }
        }
        $code = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
        $ErrorActionPreference = $prevEap
    }

    if ($null -eq $code) { $code = 0 }
    return [int]$code
}

function Invoke-UnrealBuild {
    param(
        [string]$BuildBat,
        [string]$Target,
        [string]$BuildConfig,
        [string]$UProjectPath,
        [bool]$LocalFallback
    )

    # Positional argument form, matching soft-ue-cli's PowerShell worker.
    # (Its Python offline path uses -Project=/-WaitMutex/-FromMsBuild instead;
    # the two disagree. Positional is the form that worker actually ships.)
    # -waitmutex makes concurrent builds queue instead of colliding. Keep it.
    $buildArgs = @($Target, 'Win64', $BuildConfig, $UProjectPath, '-waitmutex')

    Write-BuildStatus -Stage 'building' -Message "Building $Target Win64 $BuildConfig"
    $exitCode = Invoke-BuildBat -BuildBat $BuildBat -BuildArgs $buildArgs

    if ($exitCode -ne 0 -and $LocalFallback -and $script:LastBuildHadCompileError) {
        # The fallback exists for flaky distributed execution (UBA/XGE), not for
        # broken code. Your source will not compile any differently with
        # -NoUBA -NoXGE, and on a large target that pointless second pass costs
        # real time before the failure is reported.
        Write-DevLog "Build failed with compiler errors; skipping the -NoUBA -NoXGE retry." 'Yellow'
    }
    elseif ($exitCode -ne 0 -and $LocalFallback) {
        $fallbackArgs = @($buildArgs)
        if ($fallbackArgs -notcontains '-NoUBA') { $fallbackArgs += '-NoUBA' }
        if ($fallbackArgs -notcontains '-NoXGE') { $fallbackArgs += '-NoXGE' }

        if ($fallbackArgs.Count -gt $buildArgs.Count) {
            Write-DevLog "Build failed with exit code $exitCode. Retrying locally with -NoUBA -NoXGE..." 'Yellow'
            Write-BuildStatus -Stage 'building_local_fallback' `
                              -Message 'Distributed build failed; retrying with -NoUBA -NoXGE.'
            $exitCode = Invoke-BuildBat -BuildBat $BuildBat -BuildArgs $fallbackArgs
        }
    }

    return $exitCode
}

# ---------------------------------------------------------------------------
# Relaunch
# ---------------------------------------------------------------------------

function Move-PackageRestoreMarker {
    # Renaming (never deleting) this file suppresses the editor's "restore
    # packages?" modal on the next launch. One modal is enough to stall an
    # unattended loop indefinitely.
    param([string]$ProjectDir)

    $marker = Join-Path $ProjectDir 'Saved/PackageRestoreData.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return }

    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$marker.ue-dev-skipped-$stamp"
        $i = 1
        while (Test-Path -LiteralPath $backup) {
            $backup = "$marker.ue-dev-skipped-$stamp-$i"
            $i++
        }
        Move-Item -LiteralPath $marker -Destination $backup -Force
        Write-DevLog "Moved package restore marker to $backup"
    } catch {
        # Non-fatal by design.
        Write-DevLog "Could not move package restore marker: $($_.Exception.Message)" 'Yellow'
    }
}

function Wait-EditorReady {
    # `ue-python list` reports every editor instance on the machine, so a
    # different project already being open would otherwise satisfy this check
    # while our editor is still loading. Require our project by name.
    param([int]$TimeoutSeconds, [string]$ProjectName)

    Write-DevLog "Waiting for '$ProjectName' to accept Python remote execution..." 'Cyan'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $result = Invoke-UePythonCli -Arguments @('list')
        if ($result.ExitCode -eq 0 -and
            $result.Output.IndexOf($ProjectName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            # Same settle delay the original wait-for-editor.ps1 used: the
            # remote-exec port opens before the splash screen is gone.
            Start-Sleep -Seconds 5
            Write-DevLog 'Editor is ready and accepting connections.' 'Green'
            return $true
        }
        Start-Sleep -Seconds 5
    }

    Write-DevLog "Editor did not become ready within $TimeoutSeconds s." 'Red'
    return $false
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Initialize-Paths {
    param([string]$ProjectDir)

    $outDir = Join-Path $ProjectDir 'Saved/UeRestartCommand'
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $script:StatusPath   = Join-Path $outDir 'build-status.json'
    $script:BuildLogPath = Join-Path $outDir 'build.log'
}

function Clear-StaleArtifacts {
    # Without this a caller can read the previous run's result and act on it.
    foreach ($path in @($script:StatusPath, $script:BuildLogPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ResolveEngineCommand {
    param([string]$UProjectPath)

    $resolved = Resolve-EngineDir -UProjectPath $UProjectPath
    $payload = [ordered]@{
        uproject           = $UProjectPath
        engine_association = $resolved.Association
        engine_dir         = $resolved.Dir
        engine_source      = $resolved.Source
        resolved           = [bool]$resolved.Dir
        candidates_tried   = @($resolved.Tried)
    }
    Write-Output ($payload | ConvertTo-Json -Depth 5)
    $script:ExitCode = if ($resolved.Dir) { 0 } else { 3 }
}

function Invoke-StatusCommand {
    if (-not (Test-Path -LiteralPath $script:StatusPath -PathType Leaf)) {
        Write-Output (@{ stage = 'none'; message = 'No build status recorded.' } |
                      ConvertTo-Json -Compress)
        $script:ExitCode = 0
        return
    }
    Get-Content -LiteralPath $script:StatusPath -Raw -Encoding utf8 | Write-Output
    $script:ExitCode = 0
}

function Invoke-LaunchCommand {
    # Launch only. Exists so callers never need to know where the engine lives.
    param([string]$UProjectPath, [string]$ProjectDir, [string]$ProjectName)

    $resolved = Resolve-EngineDir -UProjectPath $UProjectPath
    if (-not $resolved.Dir) {
        Write-DevLog "Could not resolve engine. Tried: $($resolved.Tried -join '; ')" 'Red'
        $script:ExitCode = 3
        return
    }
    $script:EngineDir = $resolved.Dir
    $script:EngineSource = $resolved.Source

    if (-not $NoSkipPackageRestore) {
        Move-PackageRestoreMarker -ProjectDir $ProjectDir
    }

    $editorExe = Join-Path $resolved.Dir 'Binaries/Win64/UnrealEditor.exe'
    Write-DevLog "Launching $editorExe"
    Start-Process -FilePath $editorExe -ArgumentList @($UProjectPath) | Out-Null

    if ($WaitReady -and -not (Wait-EditorReady -TimeoutSeconds $ReadyTimeout -ProjectName $ProjectName)) {
        $script:ExitCode = 5
        return
    }
    $script:ExitCode = 0
}

function Invoke-WaitReadyCommand {
    param([string]$ProjectName)

    $script:ExitCode = if (Wait-EditorReady -TimeoutSeconds $ReadyTimeout -ProjectName $ProjectName) {
        0
    } else {
        5
    }
}

function Invoke-RebuildCommand {
    param([string]$UProjectPath, [string]$ProjectDir, [string]$ProjectName)

    Clear-StaleArtifacts
    Write-DevLog "Project: $UProjectPath" 'Cyan'

    # --- Engine resolution -------------------------------------------------
    $resolved = Resolve-EngineDir -UProjectPath $UProjectPath
    if (-not $resolved.Dir) {
        $detail = ($resolved.Tried -join '; ')
        Write-BuildStatus -Stage 'worker_error' -Complete $true -Success $false -ExitCode 3 `
            -Message "Could not resolve an engine for EngineAssociation '$($resolved.Association)'." `
            -ErrorText "Tried: $detail"
        Write-DevLog "Could not resolve engine. Tried: $detail" 'Red'
        Write-DevLog 'Set UE_ENGINE_DIR to override.' 'Yellow'
        $script:ExitCode = 3
        return
    }

    $script:EngineDir = $resolved.Dir
    $script:EngineSource = $resolved.Source
    Write-DevLog "Engine: $($resolved.Dir)  (via $($resolved.Source))" 'Cyan'

    $buildBat  = Join-Path $resolved.Dir 'Build/BatchFiles/Build.bat'
    $editorExe = Join-Path $resolved.Dir 'Binaries/Win64/UnrealEditor.exe'

    # --- Shut the editor down ---------------------------------------------
    $stopped = Stop-ProjectEditor -UProjectPath $UProjectPath `
                                  -SaveFirst (-not $NoSave) `
                                  -TimeoutSeconds $ExitTimeout `
                                  -ForceKill ([bool]$Force)
    if (-not $stopped) {
        Write-BuildStatus -Stage 'editor_exit_timeout' -Complete $true -Success $false -ExitCode 4 `
            -Message "Editor did not exit within $ExitTimeout s. Not building over a live editor." `
            -ErrorText 'Close the editor manually, or re-run with -Force.'
        $script:ExitCode = 4
        return
    }

    # --- Build -------------------------------------------------------------
    $exitCode = Invoke-UnrealBuild -BuildBat $buildBat `
                                   -Target "${ProjectName}Editor" `
                                   -BuildConfig $Config `
                                   -UProjectPath $UProjectPath `
                                   -LocalFallback (-not $NoLocalBuildFallback)

    if ($exitCode -ne 0) {
        Write-BuildStatus -Stage 'build_failed' -Complete $true -Success $false -ExitCode $exitCode `
            -Message "Build failed with exit code $exitCode. See $($script:BuildLogPath)."
        Write-DevLog "Build FAILED (exit $exitCode)." 'Red'
        $script:ExitCode = $exitCode
        return
    }
    Write-DevLog 'Build succeeded.' 'Green'

    if ($NoLaunch) {
        Write-BuildStatus -Stage 'completed' -Complete $true -Success $true -ExitCode 0 `
            -Message 'Build completed; relaunch skipped (-NoLaunch).'
        $script:ExitCode = 0
        return
    }

    # --- Relaunch ----------------------------------------------------------
    Write-BuildStatus -Stage 'relaunching' -Success $true -ExitCode 0 `
                      -Message 'Build completed; relaunching editor.'

    if (-not $NoSkipPackageRestore) {
        Move-PackageRestoreMarker -ProjectDir $ProjectDir
    }

    Write-DevLog "Launching $editorExe"
    Start-Process -FilePath $editorExe -ArgumentList @($UProjectPath) | Out-Null

    if ($WaitReady) {
        if (-not (Wait-EditorReady -TimeoutSeconds $ReadyTimeout -ProjectName $ProjectName)) {
            Write-BuildStatus -Stage 'completed' -Complete $true -Success $false -ExitCode 5 `
                -Message "Build succeeded and the editor was launched, but it did not become ready within $ReadyTimeout s."
            $script:ExitCode = 5
            return
        }
    }

    Write-BuildStatus -Stage 'completed' -Complete $true -Success $true -ExitCode 0 `
        -Message 'Build completed and editor relaunched.'
    $script:ExitCode = 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
    $uprojectPath = Resolve-UProject -Hint $Project
    $projectDir   = Split-Path -Parent $uprojectPath
    $projectName  = [System.IO.Path]::GetFileNameWithoutExtension($uprojectPath)

    Initialize-Paths -ProjectDir $projectDir

    switch ($Command) {
        'resolve-engine' { Invoke-ResolveEngineCommand -UProjectPath $uprojectPath }
        'status'         { Invoke-StatusCommand }
        'wait-ready'     { Invoke-WaitReadyCommand -ProjectName $projectName }
        'launch'         {
            Invoke-LaunchCommand -UProjectPath $uprojectPath `
                                 -ProjectDir $projectDir `
                                 -ProjectName $projectName
        }
        'rebuild'        {
            Invoke-RebuildCommand -UProjectPath $uprojectPath `
                                  -ProjectDir $projectDir `
                                  -ProjectName $projectName
            Write-FinalStatus
        }
    }
} catch {
    $message = $_.Exception.Message
    Write-Host "ue-dev: $message" -ForegroundColor Red
    if ($script:StatusPath) {
        Write-BuildStatus -Stage 'worker_error' -Complete $true -Success $false -ExitCode 1 `
            -Message 'Orchestrator failed before completion.' -ErrorText $message
        Write-FinalStatus
    }
    $script:ExitCode = 1
}

exit $script:ExitCode
