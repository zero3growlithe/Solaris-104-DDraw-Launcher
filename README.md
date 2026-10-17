# Solaris 104 DDraw Launcher

A small launcher for running the Windows CD game **Solaris 104** directly from
the **original disc** while playing through the
[cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) DirectDraw wrapper
(`ddraw.dll`). It takes care of two things the game cannot do by itself on
modern Windows:

1. **Original-CD validation** before launching, so you never start from a
   half-working extracted ISO.
2. **A video window-order monitor** that keeps the game's video windows in
   front of the background window while cut videos play.

## Files

| File | What it does |
|------|--------------|
| `Launch Solaris 104.ps1` | The actual launcher (PowerShell 5.1+, ships with Windows). Validates the disc, starts the game with the disc as its working directory, then monitors the game's windows while it runs. |
| `Launch Solaris 104.cmd` | Double-click wrapper around the PowerShell script. Forwards all arguments, pauses the console on error, propagates the game's exit code. |

Both files belong **next to the game executable** in your local game folder:

```
<Solaris game folder>/
├── solaris.exe              <- the game itself
├── ddraw.dll                <- cnc-ddraw wrapper
├── ddraw.ini                <- cnc-ddraw config (optional)
├── Launch Solaris 104.ps1
└── Launch Solaris 104.cmd
```

## Original-CD validation

Before the game starts, the launcher verifies that the disc you give it is
the **original Solaris 104 CD** (a real optical drive or a mounted archival
image, e.g. the BIN files mounted on a virtual drive):

* the disc root must contain `AUTORUN.INF`, `S104.EXE`, `SOLARIS.EXE`,
  `DATA.RES`, `SOLARIS.RES`;
* the volume label must be exactly `SOLARIS104`;
* `solaris.exe` and `DATA.RES` must expose the original **protected directory
  records** — both files report their length as the special marker
  `0x7FFFFFFF` (2147483647 bytes) on the original disc.

The marker check is the point: extractable ISO images replace those directory
records, so their `solaris.exe`/`DATA.RES` have normal (smaller) lengths. The
launcher refuses to continue in that case, because the game itself would
neither pass its own original-CD check nor find all of its data there.

## Launch details

The game executable is started with the **disc root as its working directory**
(`Start-Process -WorkingDirectory`), which is how the original game expects to
read `DATA.RES` from the CD, while the code runs from your local copy and
renders through `ddraw.dll`.

## Window-order monitor

The game creates two internal windows during playback:

* `sol_background_win` — the video background window,
* `gw_win` — the actual video window.

The launcher polls them every 50 ms (`EnumWindows` + `GetClassName` for the
game's process id) and enforces a sensible z-order:

* **a video is playing** (`gw_win` carries the `WS_VISIBLE` style):
  both windows get shown (`ShowWindow`) and raised to `HWND_TOPMOST`
  (`SetWindowPos`, no-move/no-size/no-activate). The background window is
  also re-raised, because the game engine never shows it itself — without
  this the video sits behind an empty background.
* **no video is playing**: the video background window gets hidden again so
  it doesn't cover up the actual game.

The monitor is pure user-mode windowing (no graphics hooking, no injection
into the game process) and terminates with the game process. Pass
`-DisableWindowFix` to run the game without it.

## Usage

```
Launch Solaris 104.cmd              double-click launch (game + window monitor)

powershell -File "Launch Solaris 104.ps1" [options]

  -DiscRoot <path>     validate the given disc root instead of auto-scanning
                       all CD-ROM drives (path must be on the mounted disc)
  -ValidateOnly        run all checks and stop; the game is not started
  -DisableWindowFix    start the game only, without the window-order monitor
```

`-DiscRoot` is required when more than one Solaris 104 disc is mounted, or to
skip the automatic drive scan.