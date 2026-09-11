# UE Restart Command

An Unreal Engine 5 plugin to easily save, exit, restart Unreal Editor, and compile via Live Coding.

[!['https://youtu.be/K-ZsTbUhANY'](https://github.com/user-attachments/assets/e199e7fb-5cfb-4c54-92cb-234a1dbc9ee6)](https://youtu.be/K-ZsTbUhANY)

## Features

- **Restart Editor** - Save and then restart the Editor.
- **Exit Editor** - Save and then exit the Editor.
- **Live Coding Compilation** - Compile .cpp files using Live Coding.
- **Save Packages** - Save all unsaved packages.

## Setup Instructions

### 1. Clone the Repository

```bash
git clone https://github.com/SpirrowGames/UeRestartCommand.git
```

### 2. Add as a Plugin

1. Create a `Plugins` folder in your project's root directory if it doesn't already exist.
2. Copy the cloned `UeRestartCommand` folder into the `Plugins` folder.
3. Launch Unreal Editor and ensure "UE Restart Command" is enabled under **Edit > Plugins**.
4. If `Unreal Editor Restart Command - Python Module Loaded` is output to the Output Log, the Python module has also been loaded.

> Since this plugin utilizes the Python API, the engine's standard "Python Editor Script Plugin" must be enabled.

## About the API

While this plugin can be used via C++/Blueprints, it is primarily intended to be executed externally from Python.

### C++ Class: `UEditorRestartLib`

Implemented as a Blueprint Function Library, accessible from both Python and Blueprints.

| Function | Return Value | Description |
|------|--------|------|
| `SaveAllDirtyPackages()` | `bool` | Saves all unsaved packages. |
| `ExitEditor()` | `void` | Exits the Editor (without saving). |
| `RestartEditor()` | `void` | Restarts the Editor (without saving). |
| `SaveAndExitEditor()` | `void` | Saves and then exits the Editor. |
| `SaveAndRestartEditor()` | `void` | Saves and then restarts the Editor. |
| `CompileLiveCoding()` | `bool` | Compiles via Live Coding. |

### Usage from Python

You can use it directly via the `unreal` package.

```py
import unreal

# Compile LiveCoding
unreal.EditorRestartLib.compile_live_coding()

# Save and Restart
unreal.EditorRestartLib.save_and_restart_editor()

# Save and Exit
unreal.EditorRestartLib.save_and_exit_editor()

# Save only
unreal.EditorRestartLib.save_all_dirty_packages() 

# Exit only
unreal.EditorRestartLib.exit_editor()

# Restart only
unreal.EditorRestartLib.restart_editor()
```

Additionally, wrapper functions are automatically loaded at startup.  
These are convenient for direct calls from the Output Log Python console or other Python scripts.

```py
# Compile LiveCoding
compile_live_coding();

# Save and Restart
save_and_restart_editor()

# Save and Exit
save_and_exit_editor()

# Save only
save_all_dirty_packages() 

# Exit only
exit_editor()

# Restart only
restart_editor()
```

### Usage from Blueprints

1. Open a Blueprint.
2. Right-click and search for the "Editor | Restart" category.
3. The following functions are available:
   - **Save All Dirty Packages**
   - **Exit Editor**
   - **Restart Editor**
   - **Save And Exit Editor**
   - **Save And Restart Editor**
   - **Compile Live Coding**

## Integration with ue-python-cli

While there are standard ways to execute Python scripts in Unreal Editor externally (such as `UnrealEditor-Cmd.exe` or `Python Remote Execution`), you can also use [ue-python-cli](https://github.com/self-taught-code-tokushima/ue-python-cli).

Since `ue-python-cli` is a CLI tool, it can be easily used from Coding Agents.

### How to use ue-python-cli

```bash
# Install as a tool and use
uv tool install git+https://github.com/self-taught-code-tokushima/ue-python-cli 
ue-python exec %python code%

# Run directly with uvx
uvx --from git+https://github.com/self-taught-code-tokushima/ue-python-cli ue-python exec %python code%
```

### Executing Functions

```bash
# Hot Reload (CompileLiveCoding)
ue-python exec "compile_live_coding()"

# Save and Restart
ue-python exec "save_and_restart_editor()"

# Save and Exit
ue-python exec "save_and_exit_editor()"

# Save only
ue-python exec "save_all_dirty_packages()"

# Exit only
ue-python exec "exit_editor()"

# Restart only
ue-python exec "restart_editor()"
```

## Rebuilding after a header change (`Scripts/ue-dev`)

Live Coding cannot apply changes to headers, new `UCLASS`es, or new
`UPROPERTY`/`UFUNCTION` declarations. Those need a full rebuild, and a full
rebuild needs the Editor closed — which the Editor cannot orchestrate for
itself.

`Scripts/ue-dev.cmd` does the whole sequence in one command:

```
Scripts\ue-dev.cmd rebuild -Project path\to\Your.uproject -WaitReady
```

1. Finds the Editor process bound to *this* project and asks it to
   `save_and_exit_editor()`, then waits for the process to actually exit.
   **If no Editor is running it just builds** — so this still works after a
   crash, which an in-Editor tool cannot do.
2. Resolves the engine from the `.uproject`'s `EngineAssociation`, so the build
   can never silently target a different engine than the project is associated
   with.
3. Runs `Build.bat <Project>Editor Win64 <Config> <uproject> -waitmutex`,
   retrying once with `-NoUBA -NoXGE` if a *distributed* build failed.
4. Moves `Saved/PackageRestoreData.json` aside so the "restore packages?" modal
   cannot stall an unattended run.
5. Relaunches the Editor and, with `-WaitReady`, waits until it accepts Python
   remote execution again.

### Commands

| Command | Purpose |
|---|---|
| `rebuild` | save → exit → build → relaunch (the main loop) |
| `launch` | Launch the Editor (resolves the engine for you) |
| `wait-ready` | Block until the Editor accepts remote execution |
| `status` | Print the result of the last `rebuild` |
| `resolve-engine` | Show which engine this project resolves to, and how |

### Options

| Option | Effect |
|---|---|
| `-Project <path>` | `.uproject` or a directory containing one. Defaults to the nearest one at or above the current directory |
| `-Config <name>` | Build configuration. Default `Development` |
| `-NoSave` | Exit without saving dirty packages |
| `-NoLaunch` | Build only; do not relaunch |
| `-WaitReady` | After relaunch, wait until the Editor is reachable again |
| `-Force` | Terminate the Editor if it will not exit. **Off by default — this can lose unsaved work** |
| `-NoLocalBuildFallback` | Do not retry a failed build with `-NoUBA -NoXGE` |
| `-NoSkipPackageRestore` | Leave `PackageRestoreData.json` in place |
| `-ExitTimeout` / `-ReadyTimeout` | Seconds to wait for shutdown / readiness. Default 120 / 300 |

### Machine-readable progress

Every stage is written to `<Project>/Saved/UeRestartCommand/build-status.json`,
and the final status is also printed to stdout as one JSON line. Stale status
and logs are deleted at the start of each run, so a caller can never mistake the
previous run's result for this one's.

```jsonc
{ "stage": "completed", "complete": true, "success": true, "exit_code": 0, ... }
```

`stage` moves through `waiting_for_editor_exit` → `building`
[→ `building_local_fallback`] → `relaunching` → `completed`, with
`build_failed`, `editor_exit_timeout` and `worker_error` as terminal failures.
The process exit code is `0` on success, the build's own exit code on a build
failure, and `3`/`4`/`5` for engine-resolution, shutdown-timeout and
readiness-timeout failures.

### Requirements

PowerShell 7, and [uv](https://docs.astral.sh/uv/) on `PATH` (the Editor is
driven through `uvx ... ue-python`, so no separate install is needed). Set
`UE_ENGINE_DIR` to override engine resolution.

## Project Structure

```
UeRestartCommand/
├── Content/
│   └── Python/
│       ├── init_unreal.py          # Loads wrapper functions globally at startup
│       ├── compile_live_coding.py
│       ├── restart_editor.py
│       └── save_and_exit.py
│ 
├── Source/
│   └── UeRestartCommand/
│       ├── Public/
│       │   └── EditorRestartLib.h  # C++ API Header
│       ├── Private/
│       │   ├── EditorRestartLib.cpp         # C++ API Implementation
│       │   └── UeRestartCommand.cpp         # Module Implementation
│       └── UeRestartCommand.Build.cs        # Build Configuration
│
├── Scripts/
│   ├── ue-dev.ps1                  # Build/restart orchestrator (PowerShell 7)
│   └── ue-dev.cmd                  # Launcher; resolves pwsh.exe
│
├── UeRestartCommand.uplugin        # Plugin Definition
├── THIRD_PARTY_NOTICES.md          # Attribution for adapted material
└── README.md                       # This file
```

## Troubleshooting

### `AttributeError: module 'unreal' has no attribute 'EditorRestartLib'`

**Cause**: The plugin is not enabled, or the Editor has not been restarted.

**Resolution**:
1. Open **Edit → Plugins** in the Editor.
2. Search for "UE Restart Command" and enable it.
3. Restart the Editor.

### `Live Coding module is not available`

**Cause**: Live Coding is disabled.

**Resolution**:
1. Open **Edit → Editor Preferences** in the Editor.
2. Enable **General → Live Coding**.
3. Restart the Editor.

### Build Error: "Cannot open include file"

**Cause**: Missing dependency modules.

**Resolution**: Ensure `UeRestartCommand.Build.cs` includes the following:
```csharp
PrivateDependencyModuleNames.AddRange(new string[] {
    "UnrealEd",
    "LiveCoding"
});
```

## Requirements

- Unreal Engine 5.7 or higher
- Windows 64-bit (current build configuration)

## Reference Links

- [Unreal Engine Python API](https://dev.epicgames.com/documentation/en-us/unreal-engine/PythonAPI)
- [Live Coding](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-live-coding-to-recompile-unreal-engine-applications-at-runtime)
