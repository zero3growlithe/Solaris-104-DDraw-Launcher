[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $DiscRoot,

    [Parameter()]
    [switch] $ValidateOnly,

    [Parameter()]
    [switch] $DisableWindowFix
)

$ErrorActionPreference = 'Stop'

$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameExe = Join-Path $localRoot 'solaris.exe'
$ddrawDll = Join-Path $localRoot 'ddraw.dll'
$ddrawConfig = Join-Path $localRoot 'ddraw.ini'

function Test-SolarisDiscRoot {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $requiredFiles = @(
        'AUTORUN.INF'
        'S104.EXE'
        'SOLARIS.EXE'
        'DATA.RES'
        'SOLARIS.RES'
    )

    foreach ($name in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf)) {
    throw "The local game executable was not found: $gameExe"
}

if (-not (Test-Path -LiteralPath $ddrawDll -PathType Leaf)) {
    throw "The DirectDraw compatibility DLL was not found: $ddrawDll"
}

if (-not (Test-Path -LiteralPath $ddrawConfig -PathType Leaf)) {
    Write-Warning "ddraw.ini was not found. cnc-ddraw will use its defaults."
}

if ($DiscRoot) {
    $resolvedDiscRoot = (Resolve-Path -LiteralPath $DiscRoot).Path
    $driveRoot = [System.IO.Path]::GetPathRoot($resolvedDiscRoot)
    $drive = [System.IO.DriveInfo]::new($driveRoot)

    if ($drive.DriveType -ne [System.IO.DriveType]::CDRom) {
        throw "The selected path is not on an optical or mounted-disc drive: $resolvedDiscRoot"
    }

    $resolvedDiscRoot = $drive.RootDirectory.FullName
    if (-not (Test-SolarisDiscRoot -Path $resolvedDiscRoot)) {
        throw "The selected path does not look like the original Solaris 104 disc root: $resolvedDiscRoot"
    }
}
else {
    $discCandidates = @(
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object {
                $_.DriveType -eq [System.IO.DriveType]::CDRom -and
                $_.IsReady -and
                (Test-SolarisDiscRoot -Path $_.RootDirectory.FullName)
            }
    )

    if ($discCandidates.Count -eq 0) {
        throw 'The original Solaris 104 CD was not found. Insert it (or mount your archival image) and try again.'
    }

    if ($discCandidates.Count -gt 1) {
        $roots = ($discCandidates | ForEach-Object RootDirectory | ForEach-Object FullName) -join ', '
        throw "More than one Solaris 104 disc was found ($roots). Pass the desired root with -DiscRoot."
    }

    $resolvedDiscRoot = $discCandidates[0].RootDirectory.FullName
}

$discDrive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($resolvedDiscRoot))
$discExeInfo = Get-Item -LiteralPath (Join-Path $resolvedDiscRoot 'solaris.exe')
$discDataInfo = Get-Item -LiteralPath (Join-Path $resolvedDiscRoot 'DATA.RES')
$protectedLengthMarker = [int64]0x7FFFFFFF

if ($discDrive.VolumeLabel -ne 'SOLARIS104') {
    throw "The disc volume label is '$($discDrive.VolumeLabel)', not 'SOLARIS104'."
}

if ($discExeInfo.Length -ne $protectedLengthMarker -or $discDataInfo.Length -ne $protectedLengthMarker) {
    throw @'
The mounted image does not expose the original Solaris 104 protected directory records.
Both solaris.exe and DATA.RES must report a length of 0x7FFFFFFF. The extractable ISO
intentionally replaces these markers and therefore cannot pass the game's original-CD check.
'@
}

Write-Host "Launching local game executable: $gameExe"
Write-Host "Reading game data from disc:      $resolvedDiscRoot"
Write-Host "Using DirectDraw wrapper:          $ddrawDll"
Write-Host 'Original-disc metadata:            valid (0x7FFFFFFF markers present)'

if ($ValidateOnly) {
    Write-Host 'Validation succeeded; the game was not started.'
    exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class SolarisWindowControl
{
    private const int GWL_STYLE = -16;
    private const long WS_VISIBLE = 0x10000000L;
    private const int SW_HIDE = 0;
    private const int SW_SHOWNOACTIVATE = 4;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maximumCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern IntPtr GetWindowLongPtr32(IntPtr hWnd, int index);

    private static IntPtr GetWindowLongPtr(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, index)
            : GetWindowLongPtr32(hWnd, index);
    }

    public static IntPtr FindWindow(int processId, string wantedClass)
    {
        IntPtr result = IntPtr.Zero;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint windowProcessId;
            GetWindowThreadProcessId(hWnd, out windowProcessId);
            if (windowProcessId != (uint)processId)
                return true;

            StringBuilder className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            if (String.Equals(className.ToString(), wantedClass, StringComparison.Ordinal))
            {
                result = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return result;
    }

    public static bool HasVisibleStyle(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero &&
            (GetWindowLongPtr(hWnd, GWL_STYLE).ToInt64() & WS_VISIBLE) != 0;
    }

    public static bool IsEffectivelyVisible(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero && IsWindowVisible(hWnd);
    }

    public static void HideVideoBackground(IntPtr background)
    {
        if (background != IntPtr.Zero)
            ShowWindow(background, SW_HIDE);
    }

    public static void ShowVideoChain(IntPtr background, IntPtr video)
    {
        if (background == IntPtr.Zero || video == IntPtr.Zero)
            return;

        ShowWindow(background, SW_SHOWNOACTIVATE);
        SetWindowPos(
            background,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);

        ShowWindow(video, SW_SHOWNOACTIVATE);
        SetWindowPos(
            video,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
'@

$process = Start-Process -FilePath $gameExe -WorkingDirectory $resolvedDiscRoot -PassThru

if ($DisableWindowFix) {
    Write-Host 'Window-order monitor:              disabled'
    $process.WaitForExit()
    exit $process.ExitCode
}

Write-Host 'Window-order monitor:              active'
$lastMode = $null
$lastBackground = [IntPtr]::Zero
$lastVideo = [IntPtr]::Zero

while (-not $process.HasExited) {
    $background = [SolarisWindowControl]::FindWindow($process.Id, 'sol_background_win')
    $video = [SolarisWindowControl]::FindWindow($process.Id, 'gw_win')

    if ($background -ne [IntPtr]::Zero -and $video -ne [IntPtr]::Zero) {
        if ($background -ne $lastBackground -or $video -ne $lastVideo) {
            $lastMode = $null
            $lastBackground = $background
            $lastVideo = $video
        }

        $videoPlaying = [SolarisWindowControl]::HasVisibleStyle($video)
        if ($videoPlaying) {
            if ($lastMode -ne 'Video' -or
                -not [SolarisWindowControl]::IsEffectivelyVisible($background) -or
                -not [SolarisWindowControl]::IsEffectivelyVisible($video)) {
                [SolarisWindowControl]::ShowVideoChain($background, $video)
            }

            if ($lastMode -ne 'Video') {
                Write-Host 'Window-order monitor:              video in front'
                $lastMode = 'Video'
            }
        }
        else {
            if ([SolarisWindowControl]::IsEffectivelyVisible($background)) {
                [SolarisWindowControl]::HideVideoBackground($background)
            }

            if ($lastMode -ne 'Game') {
                Write-Host 'Window-order monitor:              game in front'
                $lastMode = 'Game'
            }
        }
    }

    Start-Sleep -Milliseconds 50
    $process.Refresh()
}

$process.WaitForExit()
exit $process.ExitCode
