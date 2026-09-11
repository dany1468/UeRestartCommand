# Third Party Notices

This project incorporates material from the projects listed below.

---

## soft-ue-cli

`Scripts/ue-dev.ps1` adapts the build-and-relaunch procedure implemented by
soft-ue-cli. The adaptation is a rewrite rather than a copy — the code is
restructured as a standalone host-side PowerShell 7 orchestrator instead of a
worker script generated and spawned from inside the editor — but it follows the
original closely enough in sequence, branching and constants to be treated as a
derivative work.

Specifically, the following are derived from soft-ue-cli:

| Element in `Scripts/ue-dev.ps1` | Derived from |
|---|---|
| Overall `wait for editor exit -> build -> retry -> relaunch` sequence | `BuildAndRelaunchTool.cpp`, generated PowerShell worker |
| `-NoUBA -NoXGE` local build fallback and its "not already applied" guard | same |
| `PackageRestoreData.json` timestamped rename with numeric collision suffix | same (`$SkipPackageRestore` block) |
| Status-file stage names (`building`, `building_local_fallback`, `build_failed`, `worker_error`, `completed`) and payload field set | same (`Write-BridgeStatus`) |
| `Test-UsableEngineDir` two-file validity check and the `Engine` suffix normalization | `BuildAndRelaunchTool.cpp`, `IsUsableEngineDir()` / `NormalizeEngineDir()` |
| Registry-based engine directory lookup | `soft_ue_cli/__main__.py`, `_candidate_engine_dirs_from_registry()` |

Source: <https://github.com/softdaddy-o/soft-ue-cli>

```
MIT License

Copyright (c) 2026 soft-ue-expert

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Not covered by the above

Unreal Engine API surface used by this project — `Build.bat` argument forms,
`ELiveCodingCompileResult`, `FEditorFileUtils::SaveDirtyPackages`,
`LauncherInstalled.dat` and the `Epic Games\Unreal Engine\Builds` registry
layout — is Epic Games' engine and tooling specification, not soft-ue-cli's
work, and is used directly.
