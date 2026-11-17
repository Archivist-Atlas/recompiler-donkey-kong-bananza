# Donkey Kong Bananza (dkb-pc-recomp) installer for Windows (driven by NUP Studio)
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Donkey Kong Bananza",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
function Say($msg) { Write-Host "[DKB-Recomp] $msg" -ForegroundColor Cyan }

if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) {
    Say "error: missing .nup file: $Nup"
    exit 1
}
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Donkey Kong Bananza"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
$clang64Prefix = "C:\msys64\clang64"
$clang64Bin = Join-Path $clang64Prefix "bin"

if (-not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "ninja.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "python.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\SDL3\SDL.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vpx\vpx_decoder.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vma\vk_mem_alloc.h"))) {
    if (-not (Test-Path -LiteralPath $globalMsysInstaller)) {
        Say "error: MSYS2 missing and global installer not found: $globalMsysInstaller"
        exit 1
    }
    & $globalMsysInstaller -Msys "C:\msys64"
    if ($LASTEXITCODE -ne 0) {
        Say "MSYS2 installation cancelled or failed; stopping recompilation."
        exit 1
    }
}

$pyExe = Join-Path $clang64Bin "python.exe"
$xlateExe = Join-Path $source "bin\totk_xlate.exe"
$xlateId = Join-Path $source "bin\totk_xlate.id"
foreach ($req in @($pyExe, $xlateExe, $xlateId, (Join-Path $clang64Bin "clang.exe"), (Join-Path $clang64Bin "ninja.exe"))) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;" + $env:PATH
$env:CLANG64_PREFIX = "C:/msys64/clang64"
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"

# ---- Global Saves folder (<ParentDir>\Saves\<GameFolderName>) ----
$parentInstallDir = Split-Path -Parent $Dir
$globalSavesRoot = Join-Path $parentInstallDir "Saves"
$globalSaveDir = Join-Path $globalSavesRoot (Split-Path -Leaf $Dir)
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null

$legacyProfileDir = Join-Path $Dir "profile"
if ((Test-Path -LiteralPath $legacyProfileDir) -and -not (Get-ChildItem -LiteralPath $globalSaveDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Say "migrating existing saves into global folder: $globalSaveDir"
    Copy-Item -Path (Join-Path $legacyProfileDir "*") -Destination $globalSaveDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 1. Extract ExeFS & packed RomFS from .nup ----
$workRoot = Join-Path $Dir "_work"
$exefsDir = Join-Path $Dir "exefs"
$romfsDir = Join-Path $Dir "romfs"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath (Join-Path $romfsDir "romfs.bin"))) {
    Say "extracting ExeFS and packing RomFS from .nup..."
    $extractTmp = Join-Path $workRoot "extracted"
    if (Test-Path -LiteralPath $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    & $pyExe (Join-Path $source "tools\extract_nup.py") $Nup --select latest --pack --out $extractTmp
    if ($LASTEXITCODE -ne 0) { Say "extract_nup.py failed"; exit 1 }
    if (Test-Path -LiteralPath $exefsDir) { Remove-Item -Recurse -Force $exefsDir }
    if (Test-Path -LiteralPath $romfsDir) { Remove-Item -Recurse -Force $romfsDir }
    Move-Item -LiteralPath (Join-Path $extractTmp "exefs") -Destination $exefsDir -Force
    Move-Item -LiteralPath (Join-Path $extractTmp "romfs") -Destination $romfsDir -Force
}

# Detect game version target (dkb100 vs dkb458752) from exefs/main SHA-256
$mainHash = (Get-FileHash -LiteralPath (Join-Path $exefsDir "main") -Algorithm SHA256).Hash.ToLowerInvariant()
$target = "dkb100"
foreach ($cand in @("dkb458752", "dkb100")) {
    $expPath = Join-Path $source "tools\data\expected-$cand.json"
    if (Test-Path -LiteralPath $expPath) {
        $exp = Get-Content -LiteralPath $expPath -Raw | ConvertFrom-Json
        if ($exp.exefs_sha256.main -and $exp.exefs_sha256.main.ToLowerInvariant() -eq $mainHash) {
            $target = $cand
            break
        }
    }
}
Say "detected target version: $target"

# ---- 2. Lift ARM64 ExeFS (main, sdk) to C ----
$genDir = Join-Path $workRoot "gen"
$jobs = [Math]::Max(1, [Environment]::ProcessorCount)
if (-not (Test-Path -LiteralPath (Join-Path $genDir "main\manifest.json")) -or -not (Test-Path -LiteralPath (Join-Path $genDir "sdk\manifest.json"))) {
    Say "lifting ARM64 code (main, sdk) to C..."
    New-Item -ItemType Directory -Force -Path $genDir | Out-Null
    $patchesFile = Join-Path $source "recomp\patches-$target.txt"
    & $pyExe (Join-Path $source "recomp\gen.py") --exefs $exefsDir --out $genDir --modules "main,sdk" --jobs $jobs --patches $patchesFile
    if ($LASTEXITCODE -ne 0) { Say "recomp/gen.py failed"; exit 1 }
}

# ---- 3. Compile native Windows executable (dkb.exe) ----
$buildDir = Join-Path $workRoot "build"
$dkbExe = Join-Path $Dir "dkb.exe"
if (-not (Test-Path -LiteralPath $dkbExe)) {
    Say "compiling dkb.exe with Clang64 + Ninja..."
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    & $pyExe (Join-Path $source "tools\build_game.py") `
        --version $target `
        --expected (Join-Path $source "tools\data\expected-$target.json") `
        --gen $genDir `
        --out $buildDir `
        --modules "main,sdk" `
        --exefs $exefsDir `
        --romfs $romfsDir `
        --profile $globalSaveDir `
        --jobs $jobs `
        --full-build
    if ($LASTEXITCODE -ne 0) { Say "build_game.py failed"; exit 1 }

    Copy-Item -LiteralPath (Join-Path $buildDir "dkb.exe") -Destination $dkbExe -Force
    Copy-Item -LiteralPath (Join-Path $buildDir "romfs-index.bin") -Destination (Join-Path $Dir "romfs-index.bin") -Force
}

# Copy required runtime DLLs and shader translator next to dkb.exe
foreach ($dll in @("SDL3.dll", "libiconv-2.dll", "libopus-0.dll")) {
    $dllSrc = Join-Path $clang64Bin $dll
    if (Test-Path -LiteralPath $dllSrc) {
        Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $Dir $dll) -Force
    }
}
Copy-Item -LiteralPath $xlateExe -Destination (Join-Path $Dir "totk_xlate.exe") -Force
Copy-Item -LiteralPath $xlateId -Destination (Join-Path $Dir "totk_xlate.id") -Force

# ---- 4. Pre-translate game shaders if shader_list is available ----
$shaderCacheDir = Join-Path $Dir "shader-cache"
if (-not (Test-Path -LiteralPath $shaderCacheDir)) {
    $censusPy = Join-Path $source "tools\dkb_shader_census.py"
    if (Test-Path -LiteralPath $censusPy) {
        Say "preparing shader census..."
        Push-Location $Dir
        & $pyExe $censusPy --version $target --romfs $romfsDir --out $Dir
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $Dir "seed-nvn2.bin"))) {
            Say "pre-translating shaders..."
            $env:TOTK_PROFILE_DIR = $globalSaveDir
            & $dkbExe --translate-shaders
        }
        Remove-Item -LiteralPath (Join-Path $Dir "seed-nvn2.bin") -Force -ErrorAction SilentlyContinue
        Pop-Location
    }
}

# ---- 5. Pre-launch UI, config, shortcuts & Windows uninstaller ----
$repoRoot = Resolve-Path (Join-Path $source "..\..\..")
$launcherUiSrc = $LauncherUiPath
if (-not $launcherUiSrc -or -not (Test-Path -LiteralPath $launcherUiSrc)) {
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}
$isLauncherExe = $launcherUiSrc -match "\.exe$"
$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$launchConfigPath = Join-Path $Dir "launch_options.json"
$tplPath = Join-Path $source "launch_options_template.json"
if (Test-Path -LiteralPath $tplPath) {
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl | Add-Member -NotePropertyName "working_dir" -NotePropertyValue $Dir -Force
    $tpl | Add-Member -NotePropertyName "command" -NotePropertyValue @($dkbExe) -Force
    if (-not $tpl.env) {
        $tpl | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $tpl.env | Add-Member -NotePropertyName "TOTK_PROFILE_DIR" -NotePropertyValue $globalSaveDir -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($launchConfigPath, ($tpl | ConvertTo-Json -Depth 10), $utf8NoBom)
}

$iconSrc = $IconPath
if (-not $iconSrc -or -not (Test-Path -LiteralPath $iconSrc)) {
    $iconSrc = Join-Path $source "game_icon.ico"
}
$iconDst = Join-Path $Dir "game_icon.ico"
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
}
$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$runner = Join-Path $Dir "dkb.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} else {
@"
@echo off
cd /d "$Dir"
set "TOTK_PROFILE_DIR=$globalSaveDir"
set "TOTK_FULLSCREEN=0"
set "TOTK_WINDOW_MODE=windowed"
"$dkbExe" %*
"@ | Set-Content -Encoding ASCII $runner
}

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Donkey Kong Bananza" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 6. Clean up temporary build files ----
Say "cleaning up temporary build files in $Dir..."
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# ---- 7. Register in Windows Installed Apps + create uninstaller (never deletes ROM or saves) ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous désinstaller $safeShortcutName ?`n`nLe dossier d'installation et les raccourcis seront supprimés.`nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprimés.",
    "Désinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
if (Test-Path -LiteralPath "$desktopLnk") { Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$startMenuDir") { Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$uninstRegPath") {
    Remove-Item -LiteralPath "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Location `$env:TEMP
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 /nobreak >nul & rmdir /s /q ``"$Dir``"" -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

$sizeKb = [int](((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
New-Item -Path $uninstRegPath -Force | Out-Null
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp (NUP Studio)"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value "$iconDst,0" }
$uninstCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $sizeKb -Type DWord

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed by default, F11 for fullscreen)."
