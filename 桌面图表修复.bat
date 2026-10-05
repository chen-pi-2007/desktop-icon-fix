<# : batch launcher
@echo off
chcp 65001 >nul
title 桌面问题修复工具
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText('%~f0', [Text.Encoding]::UTF8))"
exit /b
#>
# 上面是批处理启动器，下面是 PowerShell 主体。
# 整个文件会被 PowerShell 读入执行，上面那段对 PowerShell 来说只是注释。

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = '桌面问题修复工具'

$ExpKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
$AdvKey   = "$ExpKey\Advanced"
$NspKey   = "$ExpKey\HideDesktopIcons\NewStartPanel"
$NameKey  = "$ExpKey\NamingTemplates"
$ArrowKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
$CacheDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
$Suffixes = ' - 快捷方式', ' - Shortcut'
$SysIcons = [ordered]@{
    '此电脑'   = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
    '回收站'   = '{645FF040-5081-101B-9F08-00AA002F954E}'
    '用户文件' = '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'
    '网络'     = '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'
    '控制面板' = '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'
}

# ===== 通用工具 =====

function Ok($m)      { Write-Host "  [√] $m" -ForegroundColor Green }
function Bad($m)     { Write-Host "  [×] $m" -ForegroundColor Red }
function Warn($m)    { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Info($m)    { Write-Host "  [-] $m" -ForegroundColor Gray }
function Section($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

function Confirm-Yes($q) { (Read-Host "  $q [Y/N]") -match '^[Yy]' }

function Get-Reg($Path, $Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 需要改 HKLM 时，单独弹 UAC 提权执行 reg.exe，脚本本身保持普通权限运行
function Invoke-AdminReg([string]$Arguments) {
    try {
        if (Test-Admin) {
            $p = Start-Process reg.exe -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
        } else {
            $p = Start-Process reg.exe -ArgumentList $Arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        }
        return $p.ExitCode -eq 0
    } catch {
        Bad '需要管理员权限，已取消'
        return $false
    }
}

function Test-Missing($p) {
    if (-not $p -or $p.StartsWith('\\') -or $p.StartsWith('::')) { return $false }
    try { return -not (Test-Path -LiteralPath $p) } catch { return $false }
}

function Get-DesktopDirs {
    @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

function Move-ToRecycleBin($Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        Ok "已移到回收站：$(Split-Path $Path -Leaf)"
    } catch {
        Bad "删除失败：$(Split-Path $Path -Leaf)（公共桌面上的文件需要管理员权限）"
    }
}

# ===== 资源管理器与缓存 =====

function Start-ExplorerIfNeeded {
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

function Restart-Explorer {
    Write-Host '  正在重启资源管理器...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-ExplorerIfNeeded
    Ok '资源管理器已重启'
}

function Get-CacheFiles {
    $old = "$env:LOCALAPPDATA\IconCache.db"
    if (Test-Path -LiteralPath $old) { Get-Item -LiteralPath $old -Force }
    Get-ChildItem -LiteralPath $CacheDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(iconcache|thumbcache)_.*\.db$' }
}

function Clear-IconCache {
    Write-Host '  关闭资源管理器（桌面和任务栏会消失几秒）...'
    $left = @()
    for ($i = 1; $i -le 3; $i++) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        # 第二轮起连缩略图生成进程一起结束，它也会占用缓存文件
        if ($i -gt 1) { Stop-Process -Name dllhost -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 800
        foreach ($f in @(Get-CacheFiles)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
        $left = @(Get-CacheFiles)
        if ($left.Count -eq 0) { break }
    }
    Start-ExplorerIfNeeded
    & ie4uinit.exe -show 2>$null
    if ($left.Count -eq 0) {
        Ok '图标缓存和缩略图缓存已全部清除，图标会重新生成'
    } else {
        Warn "有 $($left.Count) 个缓存文件被占用没删掉，重启电脑后马上再运行一次即可"
    }
}

# ===== 检查项 =====

function Test-SysIconShown($Name) {
    $v = Get-Reg $NspKey $SysIcons[$Name]
    if ($null -eq $v) { return $Name -eq '回收站' }   # 没设置过时，系统默认只显示回收站
    return $v -eq 0
}

function Get-ShortcutIssues {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($d in Get-DesktopDirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter *.lnk -Force -ErrorAction SilentlyContinue)) {
            try { $lnk = $ws.CreateShortcut($f.FullName) } catch { continue }
            $target = [Environment]::ExpandEnvironmentVariables($lnk.TargetPath)
            $icon   = [Environment]::ExpandEnvironmentVariables(($lnk.IconLocation -replace ',\s*-?\d+$', ''))
            if (Test-Missing $target) {
                [pscustomobject]@{ File = $f; Kind = 'Target'; Detail = $target; Lnk = $lnk; Target = $target }
            } elseif (Test-Missing $icon) {
                [pscustomobject]@{ File = $f; Kind = 'Icon'; Detail = $icon; Lnk = $lnk; Target = $target }
            }
        }
    }
}

# 文件夹通过 desktop.ini 设置了自定义图标，但图标文件已经不在了
function Get-FolderIconIssues {
    foreach ($d in Get-DesktopDirs) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue)) {
            $ini = Join-Path $dir.FullName 'desktop.ini'
            if (-not (Test-Path -LiteralPath $ini)) { continue }
            $line = Get-Content -LiteralPath $ini -Force -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*(IconResource|IconFile)\s*=' } | Select-Object -First 1
            if (-not $line) { continue }
            $p = [Environment]::ExpandEnvironmentVariables((($line -split '=', 2)[1].Trim() -replace ',\s*-?\d+$', ''))
            if ($p -and -not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $dir.FullName $p }
            if (Test-Missing $p) { [pscustomobject]@{ Folder = $dir; Ini = $ini; Detail = $p } }
        }
    }
}

function Get-SuffixShortcuts {
    foreach ($d in Get-DesktopDirs) {
        Get-ChildItem -LiteralPath $d -Filter *.lnk -Force -ErrorAction SilentlyContinue | Where-Object {
            $n = $_.BaseName
            @($Suffixes | Where-Object { $n.EndsWith($_) }).Count -gt 0
        }
    }
}

function Test-LnkAssocBroken {
    (Get-Reg 'Registry::HKEY_CLASSES_ROOT\.lnk' '(default)') -ne 'lnkfile' -or
        (Test-Path "$ExpKey\FileExts\.lnk\UserChoice")
}

# ===== 菜单功能 =====

function Invoke-Diagnose {
    $tips = New-Object System.Collections.Generic.List[string]

    Section '资源管理器'
    if (Get-Process explorer -ErrorAction SilentlyContinue) { Ok '资源管理器正在运行' }
    else { Bad '资源管理器没有运行（桌面和任务栏会消失）'; $tips.Add('[8] 重启资源管理器') }

    Section '桌面位置'
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk -and (Test-Path -LiteralPath $desk)) { Ok "桌面文件夹：$desk" }
    else {
        Bad "桌面文件夹不存在：$(Get-Reg "$ExpKey\User Shell Folders" 'Desktop')"
        $tips.Add('桌面路径指向的位置不存在：在"此电脑"里右键"桌面" → 属性 → 位置 → 还原默认值')
    }
    if ($desk -like '*OneDrive*') { Info '桌面同步在 OneDrive 里，OneDrive 没运行或同步出错时图标可能显示不全' }

    Section '图标显示'
    if ((Get-Reg $AdvKey 'HideIcons') -eq 1) { Bad '桌面图标被设置成了隐藏'; $tips.Add('[4] 恢复桌面图标显示') }
    else { Ok '桌面图标没有被隐藏' }
    $noDesk = @(
        (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDesktop'),
        (Get-Reg 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDesktop'))
    if ($noDesk -contains 1) {
        Bad '组策略禁用了桌面（NoDesktop），可能是被软件改过或公司电脑的策略'
        $tips.Add('[4] 恢复桌面图标显示')
    }
    $shown = @($SysIcons.Keys | Where-Object { Test-SysIconShown $_ })
    Info ('桌面上显示的系统图标：' + $(if ($shown.Count) { $shown -join '、' } else { '无' }))
    if ((Get-Reg $AdvKey 'IconsOnly') -eq 1) { Info '缩略图预览：已关闭（只显示图标）' }
    else { Info '缩略图预览：已开启' }
    if (Get-Reg $ArrowKey '29') { Info '快捷方式小箭头：已去除' } else { Info '快捷方式小箭头：系统默认' }

    Section '图标缓存'
    $files = @(Get-CacheFiles)
    $mb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Info "缓存文件 $($files.Count) 个，共 $mb MB"
    if ($mb -gt 500) { Warn '缓存偏大，建议清理'; $tips.Add('[2] 清理图标/缩略图缓存') }
    Info '缓存损坏没法直接检测出来：只要出现白图标、黑底、图标错乱，就运行 [2]'

    Section '快捷方式和自定义图标'
    if (Test-LnkAssocBroken) {
        Bad '快捷方式(.lnk)的打开方式被改过，所有快捷方式都会打不开'
        $tips.Add('[3] 处理失效快捷方式和图标')
    } else { Ok '快捷方式(.lnk)文件关联正常' }

    $issues = @(Get-ShortcutIssues)
    foreach ($i in $issues) {
        if ($i.Kind -eq 'Target') { Bad "$($i.File.Name)：指向的文件不存在 → $($i.Detail)" }
        else { Warn "$($i.File.Name)：图标文件丢失，会显示成白图标 → $($i.Detail)" }
    }
    $folderIssues = @(Get-FolderIconIssues)
    foreach ($i in $folderIssues) { Warn "文件夹 $($i.Folder.Name)：自定义图标丢失 → $($i.Detail)" }
    if ($issues.Count + $folderIssues.Count -eq 0) { Ok '桌面上的快捷方式和文件夹图标都正常' }
    else { $tips.Add('[3] 处理失效快捷方式和图标') }

    $named = @(Get-SuffixShortcuts)
    if ($named.Count) { Info "有 $($named.Count) 个快捷方式名字带「- 快捷方式」后缀，可以用 [7] 去掉" }

    Section '诊断结论'
    if ($tips.Count -eq 0) {
        Ok '没有发现明显问题。如果图标显示不对（白图标、黑底），运行 [2] 清理缓存'
    } else {
        Warn '建议执行：'
        $tips | Select-Object -Unique | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
    }
}

function Repair-Shortcuts {
    $changed = $false

    Section '快捷方式文件关联'
    if (Test-LnkAssocBroken) {
        Warn '快捷方式(.lnk)的打开方式被改过'
        if (Confirm-Yes '恢复成系统默认？') {
            Remove-Item "$ExpKey\FileExts\.lnk\UserChoice" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item 'HKCU:\Software\Classes\.lnk' -Recurse -Force -ErrorAction SilentlyContinue
            if ((Get-Reg 'Registry::HKEY_CLASSES_ROOT\.lnk' '(default)') -ne 'lnkfile') {
                Invoke-AdminReg 'add "HKLM\SOFTWARE\Classes\.lnk" /ve /d lnkfile /f' | Out-Null
            }
            if (Test-LnkAssocBroken) { Bad '没能完全恢复（可能被安全软件锁定了），请检查后重试' }
            else { Ok '已恢复'; $changed = $true }
        }
    } else { Ok '正常' }

    $issues = @(Get-ShortcutIssues)

    Section '指向的文件已不存在的快捷方式'
    $dead = @($issues | Where-Object Kind -eq 'Target')
    if ($dead.Count -eq 0) { Ok '没有' }
    else {
        $dead | ForEach-Object { Bad "$($_.File.Name) → $($_.Detail)" }
        Write-Host '  这些通常是软件卸载或移动后留下的，删除会移到回收站，可以找回。'
        $a = Read-Host '  [A] 全部删除   [S] 逐个确认   [N] 不处理'
        if ($a -match '^[AaSs]') {
            foreach ($i in $dead) {
                if ($a -match '^[Ss]' -and -not (Confirm-Yes "删除 $($i.File.Name)？")) { continue }
                Move-ToRecycleBin $i.File.FullName
            }
        }
    }

    Section '图标文件丢失的快捷方式（显示白图标）'
    $noIcon = @($issues | Where-Object Kind -eq 'Icon')
    if ($noIcon.Count -eq 0) { Ok '没有' }
    else {
        $noIcon | ForEach-Object { Warn "$($_.File.Name) → $($_.Detail)" }
        if (Confirm-Yes '把它们的图标改回程序自带的图标？') {
            foreach ($i in $noIcon) {
                try {
                    $i.Lnk.IconLocation = "$($i.Target),0"
                    $i.Lnk.Save()
                    Ok "已修复：$($i.File.Name)"
                    $changed = $true
                } catch { Bad "修复失败：$($i.File.Name)（公共桌面上的文件需要管理员权限）" }
            }
        }
    }

    Section '自定义图标丢失的文件夹'
    $folderIssues = @(Get-FolderIconIssues)
    if ($folderIssues.Count -eq 0) { Ok '没有' }
    else {
        $folderIssues | ForEach-Object { Warn "$($_.Folder.Name) → $($_.Detail)" }
        if (Confirm-Yes '把这些文件夹恢复成默认图标？') {
            foreach ($i in $folderIssues) {
                try {
                    $lines = Get-Content -LiteralPath $i.Ini -Force |
                        Where-Object { $_ -notmatch '^\s*(IconResource|IconFile|IconIndex)\s*=' }
                    Set-Content -LiteralPath $i.Ini -Value $lines -Encoding Unicode -Force
                    Ok "已恢复：$($i.Folder.Name)"
                    $changed = $true
                } catch { Bad "恢复失败：$($i.Folder.Name)" }
            }
        }
    }

    if ($changed) {
        & ie4uinit.exe -show 2>$null
        Info '图标如果没马上变过来，运行 [2] 清理一下缓存'
    }
}

function Restore-DesktopIcons {
    $changed = $false
    if ((Get-Reg $AdvKey 'HideIcons') -eq 1) {
        Set-Reg $AdvKey 'HideIcons' 0
        Ok '已取消隐藏桌面图标'
        $changed = $true
    }
    $polPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if ((Get-Reg "HKCU:\$polPath" 'NoDesktop') -eq 1) {
        Remove-ItemProperty -LiteralPath "HKCU:\$polPath" -Name 'NoDesktop' -Force
        Ok '已移除禁用桌面的策略（当前用户）'
        $changed = $true
    }
    if ((Get-Reg "HKLM:\$polPath" 'NoDesktop') -eq 1) {
        Warn '整台电脑的策略禁用了桌面，如果是公司电脑请先问一下管理员'
        if ((Confirm-Yes '仍然移除？') -and (Invoke-AdminReg "delete `"HKLM\$polPath`" /v NoDesktop /f")) {
            Ok '已移除禁用桌面的策略（整台电脑）'
            $changed = $true
        }
    }

    Section '桌面系统图标'
    $keys = @($SysIcons.Keys)
    while ($true) {
        for ($n = 0; $n -lt $keys.Count; $n++) {
            $state = if (Test-SysIconShown $keys[$n]) { '显示' } else { '隐藏' }
            Write-Host ("  [{0}] {1}：{2}" -f ($n + 1), $keys[$n], $state)
        }
        $c = Read-Host '  输入序号切换显示/隐藏，直接回车结束'
        if (-not $c) { break }
        if ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $keys.Count) { continue }
        $k = $keys[[int]$c - 1]
        Set-Reg $NspKey $SysIcons[$k] ([int](Test-SysIconShown $k))   # 显示中 → 写 1 隐藏；隐藏中 → 写 0 显示
        $changed = $true
    }

    if ($changed) { Restart-Explorer } else { Ok '没有需要改动的地方' }
}

function Switch-Thumbnails {
    $off = (Get-Reg $AdvKey 'IconsOnly') -eq 1
    if ($off) {
        Info '当前：缩略图预览已关闭（文件夹统一显示黄色图标，图片不显示预览）'
        if (-not (Confirm-Yes '重新开启缩略图预览？')) { return }
        Set-Reg $AdvKey 'IconsOnly' 0
    } else {
        Info '当前：缩略图预览已开启'
        Write-Host '  关闭后：文件夹统一显示黄色图标，不再出现白纸、黑底；但图片和视频也不再显示预览。'
        if (-not (Confirm-Yes '关闭缩略图预览？')) { return }
        Set-Reg $AdvKey 'IconsOnly' 1
    }
    Restart-Explorer
}

function Switch-ShortcutArrow {
    $key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
    if (Get-Reg $ArrowKey '29') {
        Info '当前：快捷方式小箭头已去除'
        if (-not (Confirm-Yes '恢复小箭头？')) { return }
        $ok = Invoke-AdminReg "delete `"$key`" /v 29 /f"
    } else {
        Info '当前：快捷方式图标左下角有小箭头'
        if (-not (Confirm-Yes '去除小箭头？（会弹出管理员确认）')) { return }
        $ok = Invoke-AdminReg "add `"$key`" /v 29 /t REG_EXPAND_SZ /d `"%SystemRoot%\System32\imageres.dll,197`" /f"
    }
    if ($ok) { Ok '设置已修改，接下来清理图标缓存让它生效'; Clear-IconCache }
}

function Set-ShortcutNaming {
    $noSuffix = (Get-Reg $NameKey 'ShortcutNameTemplate') -eq '%s.lnk'
    Info ('以后新建快捷方式：' + $(if ($noSuffix) { '不加后缀' } else { '会加「- 快捷方式」后缀（系统默认）' }))
    $list = @(Get-SuffixShortcuts)
    Info "桌面上现有带后缀的快捷方式：$($list.Count) 个"
    Write-Host ''
    Write-Host '  [1] 以后新建快捷方式不加后缀'
    Write-Host '  [2] 恢复系统默认（加后缀）'
    Write-Host '  [3] 去掉桌面上现有快捷方式的后缀'
    switch (Read-Host '  请选择（直接回车返回）') {
        '1' {
            Set-Reg $NameKey 'ShortcutNameTemplate' '%s.lnk' 'String'
            Ok '已设置，重启资源管理器后生效'
            if (Confirm-Yes '现在重启资源管理器？') { Restart-Explorer }
        }
        '2' {
            Remove-ItemProperty -LiteralPath $NameKey -Name 'ShortcutNameTemplate' -Force -ErrorAction SilentlyContinue
            Ok '已恢复默认，重启资源管理器后生效'
            if (Confirm-Yes '现在重启资源管理器？') { Restart-Explorer }
        }
        '3' {
            if ($list.Count -eq 0) { Ok '没有带后缀的快捷方式'; return }
            foreach ($f in $list) {
                $new = $f.BaseName
                foreach ($s in $Suffixes) {
                    if ($new.EndsWith($s)) { $new = $new.Substring(0, $new.Length - $s.Length) }
                }
                if (Test-Path -LiteralPath (Join-Path $f.DirectoryName "$new.lnk")) {
                    Warn "跳过 $($f.Name)：已经有同名的 $new.lnk"
                    continue
                }
                try {
                    Rename-Item -LiteralPath $f.FullName -NewName "$new.lnk" -ErrorAction Stop
                    Ok "$($f.Name) → $new.lnk"
                } catch { Bad "$($f.Name) 改名失败（公共桌面上的文件需要管理员权限）" }
            }
        }
    }
}

# ===== 主菜单 =====

while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  ================ 桌面问题修复工具 ================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   [1] 全面诊断（只检查，不改动任何东西）'
    Write-Host '   [2] 清理图标/缩略图缓存（白图标、黑底、图标错乱）'
    Write-Host '   [3] 处理失效快捷方式和丢失的图标'
    Write-Host '   [4] 恢复桌面图标（图标全没了、此电脑/回收站不见了）'
    Write-Host '   [5] 缩略图预览 开启/关闭'
    Write-Host '   [6] 快捷方式小箭头 去除/恢复（需要管理员）'
    Write-Host '   [7] 快捷方式名字里的「- 快捷方式」后缀'
    Write-Host '   [8] 重启资源管理器（桌面卡死、任务栏没反应）'
    Write-Host '   [0] 退出'
    Write-Host ''
    $choice = Read-Host '  请选择'
    if ($choice -notmatch '^[0-8]$') { continue }
    switch ($choice) {
        '1' { Invoke-Diagnose }
        '2' { Clear-IconCache }
        '3' { Repair-Shortcuts }
        '4' { Restore-DesktopIcons }
        '5' { Switch-Thumbnails }
        '6' { Switch-ShortcutArrow }
        '7' { Set-ShortcutNaming }
        '8' { Restart-Explorer }
        '0' { exit }
    }
    Read-Host "`n  按回车返回菜单" | Out-Null
}
