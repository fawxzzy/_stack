[CmdletBinding()]
param(
    [string]$ShortcutName = "Stack Release Launcher",
    [string]$IconPath,
    [switch]$StartMenu,
    [switch]$UseWindowsTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ShortcutIconPath {
    param(
        [string]$RequestedPath,
        [string]$DefaultPath,
        [string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates = @($RequestedPath)
        if (-not [System.IO.Path]::IsPathRooted($RequestedPath)) {
            $candidates += (Join-Path $RepoRoot $RequestedPath)
        }

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }

        throw "Icon path not found: $RequestedPath"
    }

    if (Test-Path -LiteralPath $DefaultPath) {
        return (Resolve-Path -LiteralPath $DefaultPath).Path
    }

    return $null
}

function Resolve-TerminalCommand {
    param(
        [string]$RepoRoot,
        [string]$LauncherScript,
        [string]$PowerShellExe,
        [switch]$UseWindowsTerminal
    )

    $launcherArguments = @(
        "-NoLogo"
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", """$LauncherScript"""
        "-StackRoot", """$RepoRoot"""
    )

    if (-not $UseWindowsTerminal) {
        return [pscustomobject]@{
            TargetPath = $PowerShellExe
            Arguments = ($launcherArguments -join " ")
            Mode = "PowerShell"
        }
    }

    $windowsTerminalPath = $null
    $defaultWindowsTerminalPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path -LiteralPath $defaultWindowsTerminalPath) {
        $windowsTerminalPath = $defaultWindowsTerminalPath
    } else {
        $wtCommand = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($wtCommand) {
            $windowsTerminalPath = $wtCommand.Source
        }
    }

    if (-not $windowsTerminalPath) {
        Write-Warning "Windows Terminal was requested but wt.exe was not found. Falling back to powershell.exe."
        return [pscustomobject]@{
            TargetPath = $PowerShellExe
            Arguments = ($launcherArguments -join " ")
            Mode = "PowerShellFallback"
        }
    }

    $terminalArguments = @(
        $launcherArguments
        "-UseWindowsTerminal"
    )
    return [pscustomobject]@{
        TargetPath = $PowerShellExe
        Arguments = ($terminalArguments -join " ")
        Mode = "WindowsTerminal"
    }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$launcherScript = Join-Path $repoRoot "ops\Open-ReleaseLauncher.ps1"

if (-not (Test-Path -LiteralPath $launcherScript)) {
    throw "Launcher script not found: $launcherScript"
}

$desktopPath = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::DesktopDirectory)
$startMenuProgramsPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$targetFolder = if ($StartMenu) { $startMenuProgramsPath } else { $desktopPath }

if (-not (Test-Path -LiteralPath $targetFolder)) {
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
}

$shortcutPath = Join-Path $targetFolder ($ShortcutName + ".lnk")

$powerShellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powerShellExe)) {
    $powerShellExe = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
}

$defaultIconPath = Join-Path $repoRoot "ops\assets\release-launcher.ico"
$resolvedIconPath = Resolve-ShortcutIconPath -RequestedPath $IconPath -DefaultPath $defaultIconPath -RepoRoot $repoRoot
$terminalCommand = Resolve-TerminalCommand -RepoRoot $repoRoot -LauncherScript $launcherScript -PowerShellExe $powerShellExe -UseWindowsTerminal:$UseWindowsTerminal

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $terminalCommand.TargetPath
$shortcut.Arguments = $terminalCommand.Arguments
$shortcut.WorkingDirectory = $repoRoot
$shortcut.Description = "Open the _stack release launcher"
$shortcut.WindowStyle = 1
$shortcut.IconLocation = if ($resolvedIconPath) { $resolvedIconPath } else { "$($terminalCommand.TargetPath),0" }
$shortcut.Save()

Write-Host "Created shortcut:"
Write-Host "  $shortcutPath"
Write-Host "Launch mode:"
Write-Host "  $($terminalCommand.Mode)"
Write-Host "Icon source:"
Write-Host "  $resolvedIconPath"
Write-Host ""
Write-Host "Next:"
if ($StartMenu) {
    Write-Host "  1. Open Start"
    Write-Host "  2. Find $ShortcutName"
    Write-Host "  3. Right-click it"
    Write-Host "  4. Pin to taskbar"
} else {
    Write-Host "  1. Right-click the shortcut"
    Write-Host "  2. Pin to taskbar"
    Write-Host "  Prefer the -StartMenu install path if Windows hides the pin option on the Desktop shortcut."
}
Write-Host "  If the pinned taskbar icon stays stale, unpin the old entry and pin the refreshed shortcut again."
