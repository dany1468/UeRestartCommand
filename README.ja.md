# UE Restart Command

Unreal Editor の保存、終了、再起動、Live Coding コンパイルを簡単に行うための Unreal Engine 5 プラグインです。

## 特徴

- **Editor 再起動** - 保存してから Editor を再起動
- **Editor 終了** - 保存してから Editor を終了
- **Live Coding コンパイル** - Live Coding で .cpp ファイルをコンパイル
- **パッケージ保存** - 全ての未保存パッケージを保存

## セットアップ手順

### クイックセットアップ（推奨）

UE5 プロジェクトのルートディレクトリで以下を実行します。このプラグインを
`Plugins/` に git submodule として追加し、[`ue-dev`](#ヘッダ変更後のリビルド-scriptsue-dev)
の go-task 連携をセットアップし、Python Remote Execution の設定まで一度に済ませます。

```powershell
irm https://raw.githubusercontent.com/dany1468/ue5-toolkit/main/install.ps1 | iex
```

何を変更するか・実行前に中身を確認する方法は
[ue5-toolkit](https://github.com/dany1468/ue5-toolkit) を参照してください。

### 手動セットアップ

#### 1. submodule として追加

```bash
git submodule add https://github.com/dany1468/UeRestartCommand.git Plugins/UeRestartCommand
```

#### 2. プラグインを有効化

1. Unreal Editor を起動し、**Edit > Plugins** から "UE Restart Command" が有効になっていることを確認します。
2. Output Log に `Unreal Editor Restart Command - Python Module Loaded` が出力されていれば Python モジュールも読み込まれています。

> このプラグインは Python API を利用しているため、エンジンの標準プラグインである "Python Editor Script Plugin" が有効である必要があります。

## API について

このプラグインは C++/Blueprint での利用も可能ですが、基本的には Python から外部実行されることを想定しています。

### C++ クラス: `UEditorRestartLib`

Blueprint Function Library として実装されており、Python と Blueprint の両方から利用可能です。

| 関数 | 戻り値 | 説明 |
|------|--------|------|
| `SaveAllDirtyPackages()` | `bool` | 全ての未保存パッケージを保存 |
| `ExitEditor()` | `void` | Editor を終了（保存なし） |
| `RestartEditor()` | `void` | Editor を再起動（保存なし） |
| `SaveAndExitEditor()` | `void` | 保存してから Editor を終了 |
| `SaveAndRestartEditor()` | `void` | 保存してから Editor を再起動 |
| `CompileLiveCoding()` | `bool` | Live Coding でコンパイル |

### Python から使用

直接利用する場合は `unreal` パッケージから利用できます。

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

また、上記をラップした関数も起動時に自動でロードされます。  
Output Log の Python コンソールや、他の Pythonスクリプト内から直接呼び出す際に便利です。

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

### Blueprint から使用

1. Blueprint を開く
2. 右クリックして "Editor | Restart" カテゴリを探す
3. 以下の関数が利用可能です：
   - **Save All Dirty Packages** - 全て保存
   - **Exit Editor** - 終了
   - **Restart Editor** - 再起動
   - **Save And Exit Editor** - 保存して終了
   - **Save And Restart Editor** - 保存して再起動
   - **Compile Live Coding** - Live Coding のコンパイル

## ue-python-cli との組み合わせ

Unreal Editor への外部からの Python スクリプトの実行は標準的な方法 (`UnrealEditor-Cmd.exe` や `Python Remote Execution`) がありますが、[ue-python-cli](https://github.com/self-taught-code-tokushima/ue-python-cli) を利用することもできます。

`ue-python-cli` は CLI ツールであるため、Coding Agent からも簡単に利用できます。

### ue-python-cli の使い方

```bash
# ツールとしてインストールして利用
uv tool install git+https://github.com/self-taught-code-tokushima/ue-python-cli 
ue-python exec %python code%

# uvx で直接実行
uvx --from git+https://github.com/self-taught-code-tokushima/ue-python-cli ue-python exec %python code%
```

### 関数の実行

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

## ヘッダ変更後のリビルド (`Scripts/ue-dev`)

Live Coding はヘッダの変更・新しい `UCLASS`・`UPROPERTY`/`UFUNCTION` の追加を
適用できません。これらにはフルビルドが必要で、フルビルドには Editor を閉じる
必要があります。そして **Editor は自分自身を閉じた後の処理を担当できません**。

`Scripts/ue-dev.cmd` はこの一連の流れをコマンド 1 つで実行します。

```
Scripts\ue-dev.cmd rebuild -Project path\to\Your.uproject -WaitReady
```

1. **このプロジェクトの** Editor プロセスを特定して `save_and_exit_editor()` を
   送り、プロセスが実際に終了するまで待ちます。
   **Editor が起動していなければそのままビルドに進みます** —— クラッシュ後でも
   動くという、Editor 内ツールには原理的にできないことです。
2. `.uproject` の `EngineAssociation` からエンジンを解決するため、
   プロジェクトが紐づくエンジンと違うエンジンで誤ってビルドすることがありません。
3. `Build.bat <Project>Editor Win64 <Config> <uproject> -waitmutex` を実行し、
   **分散ビルドが**失敗した場合のみ `-NoUBA -NoXGE` で 1 度だけ再試行します。
4. `Saved/PackageRestoreData.json` を退避し、「パッケージを復元しますか?」の
   モーダルで無人実行が止まらないようにします。
5. Editor を再起動し、`-WaitReady` 指定時は Python Remote Execution が
   再び通るようになるまで待ちます。

### サブコマンド

| コマンド | 用途 |
|---|---|
| `rebuild` | 保存 → 終了 → ビルド → 再起動（主経路） |
| `launch` | Editor を起動（エンジンパスの解決込み） |
| `wait-ready` | Editor が応答するまで待機 |
| `status` | 直前の `rebuild` の結果を表示 |
| `resolve-engine` | どのエンジンにどう解決されるかを表示 |

### オプション

| オプション | 効果 |
|---|---|
| `-Project <path>` | `.uproject` かそれを含むディレクトリ。省略時はカレントから上に探索 |
| `-Config <name>` | ビルド構成。既定は `Development` |
| `-NoSave` | 保存せずに終了する |
| `-NoLaunch` | ビルドのみ。再起動しない |
| `-WaitReady` | 再起動後、Editor が応答するまで待つ |
| `-Force` | Editor が終了しない場合に強制終了する。**既定は無効 —— 未保存の作業を失う可能性があります** |
| `-NoLocalBuildFallback` | `-NoUBA -NoXGE` での再試行を行わない |
| `-NoSkipPackageRestore` | `PackageRestoreData.json` を退避しない |
| `-ExitTimeout` / `-ReadyTimeout` | 終了待ち / 起動待ちの秒数。既定は 120 / 300 |

### 進捗の取得

各段階が `<Project>/Saved/UeRestartCommand/build-status.json` に書き出され、
最終状態は stdout にも JSON 1 行で出力されます。実行開始時に古い status と
ログを削除するため、**前回の結果を今回のものと取り違える事故が起きません**。

```jsonc
{ "stage": "completed", "complete": true, "success": true, "exit_code": 0, ... }
```

`stage` は `waiting_for_editor_exit` → `building`
[→ `building_local_fallback`] → `relaunching` → `completed` と遷移し、
`build_failed` / `editor_exit_timeout` / `worker_error` が終端の失敗状態です。
終了コードは成功なら `0`、ビルド失敗ならビルド自体の終了コード、
エンジン解決・終了待ち・起動待ちの失敗はそれぞれ `3` / `4` / `5` です。

### 必要な環境

PowerShell 7 と、`PATH` 上の [uv](https://docs.astral.sh/uv/)
（Editor の操作は `uvx ... ue-python` 経由なので個別のインストールは不要です）。
エンジン解決を上書きしたい場合は環境変数 `UE_ENGINE_DIR` を設定してください。

## プロジェクト構造

```
UeRestartCommand/
├── Content/
│   └── Python/
│       ├── init_unreal.py          # 起動時にラッパー関数をグローバルにロード
│       ├── compile_live_coding.py
│       ├── restart_editor.py
│       └── save_and_exit.py
│ 
├── Source/
│   └── UeRestartCommand/
│       ├── Public/
│       │   └── EditorRestartLib.h  # C++ API ヘッダー
│       ├── Private/
│       │   ├── EditorRestartLib.cpp         # C++ API 実装
│       │   └── UeRestartCommand.cpp         # モジュール実装
│       └── UeRestartCommand.Build.cs        # ビルド設定
│
├── Scripts/
│   ├── ue-dev.ps1                  # ビルド/再起動オーケストレータ (PowerShell 7)
│   ├── ue-dev.cmd                  # 起動ラッパ。pwsh.exe を解決する
│   └── BuildTasks.yml              # go-task タスク定義。導入先プロジェクトの Taskfile.yml から include する
│
├── UeRestartCommand.uplugin        # プラグイン定義
├── THIRD_PARTY_NOTICES.md          # 移植元の著作権表示
└── README.md                       # このファイル
```

## トラブルシューティング

### `AttributeError: module 'unreal' has no attribute 'EditorRestartLib'`

**原因**: プラグインが有効化されていないか、Editor が再起動されていません。

**解決方法**:
1. Editor で **Edit → Plugins** を開く
2. "UE Restart Command" を検索して有効化
3. Editor を再起動

### `Live Coding module is not available`

**原因**: Live Coding が無効化されています。

**解決方法**:
1. Editor で **Edit → Editor Preferences** を開く
2. **General → Live Coding** を有効化
3. Editor を再起動

### ビルドエラー: "Cannot open include file"

**原因**: 依存モジュールが不足しています。

**解決方法**: `UeRestartCommand.Build.cs` に以下が含まれているか確認：
```csharp
PrivateDependencyModuleNames.AddRange(new string[] {
    "UnrealEd",
    "LiveCoding"
});
```

## 必要な環境

- Unreal Engine 5.7 以上
- Windows 64-bit（現在のビルド設定）

## 参考リンク

- [Unreal Engine Python API](https://dev.epicgames.com/documentation/en-us/unreal-engine/PythonAPI)
- [Live Coding](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-live-coding-to-recompile-unreal-engine-applications-at-runtime)
