param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$PasswordFile = '',
    [string]$MagicExe = '',
    [string]$PythonExe = '',
    [switch]$Collapse,
    [switch]$DeleteSource,
    [switch]$MagicFallback,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'

# 所有依赖路径都跟着脚本目录走，不再写死 D:\解压姬 —— 别人把仓库克隆到哪都能跑
if (-not $PasswordFile) { $PasswordFile = Join-Path $PSScriptRoot 'passwords.txt' }
if (-not $MagicExe) { $MagicExe = Join-Path $PSScriptRoot 'magic-extractor.exe' }
$SevenZip = Join-Path $PSScriptRoot 'bin\extractors\7z\7z.exe'

# 找 python：优先用调用方（jieyaji_web.py 传它自己的 sys.executable），
# 其次环境变量、PATH、常见安装位置。都找不到就返回 ''，调用方跳过快速通道回落 7z。
$script:PythonExeResolved = $null
function Get-PythonExe {
    if ($null -ne $script:PythonExeResolved) { return $script:PythonExeResolved }
    $cands = @()
    if ($PythonExe) { $cands += $PythonExe }
    if ($env:JIEYAJI_PYTHON) { $cands += $env:JIEYAJI_PYTHON }
    try { $c = Get-Command python.exe -ErrorAction Stop; $cands += $c.Source } catch {}
    if ($env:LOCALAPPDATA) {
        foreach ($v in @('Python314', 'Python313', 'Python312', 'Python311')) {
            $cands += (Join-Path $env:LOCALAPPDATA ('Programs\Python\' + $v + '\python.exe'))
        }
    }
    $cands += 'C:\Python314\python.exe'
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { $script:PythonExeResolved = $c; return $c }
    }
    $script:PythonExeResolved = ''
    return ''
}

# Several workers run at once (threads > 1) and they all append to their own log
# file, but the UI merges every job log into one panel - without a per-archive
# tag the lines from 4 concurrent workers interleave into unreadable soup.
$script:LogTag = '[' + [System.IO.Path]::GetFileName($FilePath) + ']'

function Write-Log([string]$m) {
    $line = if ($script:LogTag) { $script:LogTag + ' ' + $m } else { $m }
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } else {
        [System.Console]::Out.WriteLine($line)
    }
}

# Cross-process mutex shared with pwtest.py (same name on both sides). Used to
# guard read-modify-write cycles on shared files (hot password cache, password
# book) that concurrent workers would otherwise clobber.
function Invoke-WithFileMutex([string]$name, [scriptblock]$body) {
    $mtx = $null
    $acquired = $false
    try {
        $mtx = New-Object System.Threading.Mutex($false, $name)
        try { $acquired = $mtx.WaitOne(20000) } catch { $acquired = $true }
    } catch {
        $mtx = $null
    }
    try {
        return (& $body)
    } finally {
        if ($mtx) {
            if ($acquired) { try { $mtx.ReleaseMutex() } catch {} }
            try { $mtx.Dispose() } catch {}
        }
    }
}

function Quote-Arg([string]$s) {
    return '"' + $s.Replace('"', '\"') + '"'
}

# Kill every descendant of a process (orphaned grandchildren like hung unrar.exe
# keep source archives locked forever). Call after the parent has exited.
function Stop-ProcessTree([int]$parentPid) {
    try {
        $children = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $parentPid) -ErrorAction SilentlyContinue
        foreach ($c in $children) {
            Stop-ProcessTree $c.ProcessId
            try { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
    } catch {}
}

# Give a started process an already-closed stdin: any interactive prompt
# (e.g. unrar asking for a password) gets EOF instantly instead of hanging forever.
function Close-ProcStdin($proc) {
    try { $proc.StandardInput.Close() } catch {}
}

function Invoke-MagicExtract([string]$file, [string]$outDir, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MagicExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = 'extract ' + (Quote-Arg $file) + ' ' + (Quote-Arg $outDir)
    $psi.Arguments += ' --create-log-files false'
    if ($pw -ne '') {
        $psi.Arguments += ' --password ' + (Quote-Arg $pw)
    }
    Write-Log ('magic-extractor extracting: ' + $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(300000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            Stop-ProcessTree $p.Id
            Write-Log ("WARN magic-extractor timeout: " + $file)
            return $false
        }
        $code = $p.ExitCode
        Stop-ProcessTree $p.Id
        if ($code -eq 0) {
            Write-Log ('OK magic-extractor extract done -> ' + $outDir)
        } else {
            Write-Log ('WARN magic-extractor extract failed (exit ' + $code + '): ' + $file)
        }
        return $code -eq 0
    } catch {
        Write-Log ("WARN magic-extractor start failed: " + $_.Exception.Message)
        return $false
    }
}

function Find-WinRAR {
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WinRAR.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\WinRAR.exe'
    )) {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        } catch {}
    }
    foreach ($c in @((Join-Path $env:ProgramFiles 'WinRAR\WinRAR.exe'), (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\WinRAR.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return ''
}

# Last-resort extractor: WinRAR's scanner tolerates broken zip central
# directories that 7z/magic-extractor reject outright (e.g. MP4+ZIP64
# polyglot where the zip EOCD points at garbage). Tries without password.
function Invoke-WinRARExtract([string]$file, [string]$outDir, [string]$pw) {
    $wr = Find-WinRAR
    if (-not $wr) {
        Write-Log 'WARN WinRAR not found; skipping WinRAR fallback'
        return $false
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wr
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = 'x -y -o+ ' + (Quote-Arg $file) + ' ' + (Quote-Arg $outDir)
    if ($pw -ne '') {
        $psi.Arguments += ' -p' + (Quote-Arg $pw)
    } else {
        # '-p-' means "never ask for a password". Without it WinRAR pops its GUI
        # password dialog on an encrypted archive and then simply sits there: the
        # dialog cannot be answered (stdin is closed) and the call burns the full
        # 10-minute timeout. With '-p-' it fails fast instead. The old fallback
        # below could never fire, because a hung process never returns an exit code.
        $psi.Arguments += ' -p-'
    }
    try {
        Write-Log ('WinRAR extracting (tolerant scanner): ' + $file)
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(600000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            Stop-ProcessTree $p.Id
            Write-Log 'WARN WinRAR fallback timeout'
            return $false
        }
        Stop-ProcessTree $p.Id
        if ($p.ExitCode -le 1) {
            $n = @(Get-ChildItem -LiteralPath $outDir -Force -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) {
                Write-Log ('OK WinRAR extract done: ' + $n + ' item(s) -> ' + $outDir)
                return $true
            }
        }
        Write-Log ('WARN WinRAR extract failed (exit ' + $p.ExitCode + '): ' + $file)
        return $false
    } catch {
        Write-Log ('WARN WinRAR start failed: ' + $_.Exception.Message)
        return $false
    }
}

function Test-Password7z([string]$file, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    # 'l' (list) only reads the archive header: wrong password fails in ~0.1s,
    # correct password succeeds instantly. 't' would do a full data verify
    # (minutes on multi-GB volumes) and timeout before confirming the password.
    $psi.Arguments = 'l ' + (Quote-Arg ('-p' + $pw)) + ' -y ' + (Quote-Arg $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(300000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            return $false
        }
        return $p.ExitCode -eq 0
    } catch {
        Write-Log ("WARN 7z start failed (" + $SevenZip + "): " + $_.Exception.Message)
        return $false
    }
}

# ---- Archive probe: one password-free listing, reused by every candidate ----
#
# 'l' reads only the archive header, so on archives whose header is PLAINTEXT
# it succeeds no matter what password you pass. That is true for the vast
# majority of rar password packs (WinRAR's '-p' encrypts data only; '-hp'
# encrypts the header too) and for ordinary zips. Therefore 'l -p<pw>' can
# NEVER validate a password there - it answered exit 0 to "", to a wrong
# password and to the right one alike, and the caller happily concluded the
# archive had no password.
#
# The same listing does tell us two useful things for free:
#   * whether the header itself is encrypted (listing fails without a password)
#   * which entries carry 'Encrypted = +', and which of them is smallest
# so we list ONCE per archive and then verify each candidate against the
# smallest ENCRYPTED entry with '7z t', which really touches data.
# (Only encrypted entries qualify: mixed archives may hold plain decoys whose
# data decrypts fine with any password and would validate a wrong one.)
#
# $script:ArcProbe keys:
#   Ok              listing succeeded without a password
#   HeaderEncrypted listing failed -> header needs a password (-hp rar, 7z -mhe)
#   AnyEncrypted    at least one entry carries Encrypted = +
#   MinEntry        smallest non-empty encrypted file entry (verification target)
function Initialize-ArchiveProbe([string]$file) {
    $script:ArcProbe = @{ Ok = $false; HeaderEncrypted = $false; AnyEncrypted = $false; MinEntry = '' }
    if (-not (Test-Path -LiteralPath $SevenZip)) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
    $psi.Arguments = 'l -slt ' + (Quote-Arg $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(120000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            return
        }
        if ($p.ExitCode -ne 0) {
            $script:ArcProbe.HeaderEncrypted = $true
            return
        }
    } catch { return }
    $script:ArcProbe.Ok = $true
    # Single pass, no per-entry objects: resource packs with 100k+ entries are
    # common enough that building and sorting a list of them would be wasteful.
    $inEntries = $false
    $curPath = ''
    $curSize = [int64]0
    $curIsFolder = $false
    $curEnc = $false
    $anyEnc = $false
    $bestSize = [int64]0
    $bestPath = ''
    foreach ($ln in ($out -split "`r?`n")) {
        if ($ln -match '^-{6,}') { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($ln -match '^Path\s*=\s*(.*)$') {
            if ($curEnc -and -not $curIsFolder -and $curSize -gt 0) {
                $anyEnc = $true
                if ($bestPath -eq '' -or $curSize -lt $bestSize) { $bestSize = $curSize; $bestPath = $curPath }
            }
            $curPath = $matches[1].Trim()
            $curSize = [int64]0
            $curIsFolder = $false
            $curEnc = $false
        } elseif ($ln -match '^Size\s*=\s*(\d+)') {
            $curSize = [int64]$matches[1]
        } elseif ($ln -match '^Folder\s*=\s*\+') {
            $curIsFolder = $true
        } elseif ($ln -match '^Encrypted\s*=\s*\+') {
            $curEnc = $true
        }
    }
    if ($curEnc -and -not $curIsFolder -and $curSize -gt 0) {
        $anyEnc = $true
        if ($bestPath -eq '' -or $curSize -lt $bestSize) { $bestSize = $curSize; $bestPath = $curPath }
    }
    $script:ArcProbe.AnyEncrypted = $anyEnc
    $script:ArcProbe.MinEntry = $bestPath
}

# Validate one password candidate against an archive that Initialize-ArchiveProbe
# has already listed. Returns $true when the password is right.
function Test-ArchivePassword([string]$file, [string]$pw) {
    if (-not $script:ArcProbe -or -not $script:ArcProbe.Ok) {
        # Header is encrypted (or 7z is unavailable): here 'l' genuinely needs
        # the password, and 'l -p<pw>' is both correct and cheap.
        return (Test-Password7z $file $pw)
    }
    if (-not $script:ArcProbe.AnyEncrypted) {
        # Nothing is encrypted: every password "works", only the empty one is
        # meaningful. $attempts always starts with '', so this matches at once.
        return ($pw -eq '')
    }
    if ($script:ArcProbe.MinEntry -eq '') {
        return (Test-Password7z $file $pw)
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
    # 't' with a single entry: a wrong password is rejected by the AES check
    # value immediately, a right one decrypts just that one entry.
    $psi.Arguments = 't ' + (Quote-Arg ('-p' + $pw)) + ' -y ' + (Quote-Arg $file) + ' ' + (Quote-Arg $script:ArcProbe.MinEntry)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        $null = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(600000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            return $false
        }
        return $p.ExitCode -eq 0
    } catch { return $false }
}

# SUPERSEDED by Initialize-ArchiveProbe + Test-ArchivePassword (2026-09-19):
# kept only as a reference. Listed the archive once PER CANDIDATE, took the
# first entry (a plain decoy in mixed archives validates any password) and
# could not list header-encrypted archives at all.
function Test-ZipPasswordSingle([string]$file, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    # 7z emits GBK on this system; without an explicit encoding the worker
    # (no console) reads it as UTF-8 and entry paths become mojibake.
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
    $psi.Arguments = 'l -slt ' + (Quote-Arg $file)
    $firstEntry = ''
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        $out = $p.StandardOutput.ReadToEnd()
        $null = $p.WaitForExit(30000)
        $firstEntry = ''
        $curPath = ''
        $curIsFolder = $false
        $afterPath = ''
        foreach ($ln in ($out -split "`r?`n")) {
            if ($ln -match '^\s*Path\s*=\s*(.+)$') {
                if ($curPath -ne '' -and -not $curIsFolder -and $firstEntry -eq '') {
                    $firstEntry = $curPath
                }
                $curPath = $matches[1].Trim()
                $curIsFolder = $false
                $afterPath = 'path'
            } elseif ($afterPath -eq 'path' -and $ln -match '^\s*Type\s*=') {
                # this Path was the archive itself, not an entry
                $curPath = ''
            } elseif ($ln -match '^\s*Folder\s*=\s*([+\-])') {
                $curIsFolder = ($matches[1] -eq '+')
                $afterPath = 'folder'
            }
        }
        if ($curPath -ne '' -and -not $curIsFolder -and $firstEntry -eq '') {
            $firstEntry = $curPath
        }
    } catch {
        return $false
    }
    if ($firstEntry -eq '') { return $false }
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $SevenZip
    $psi2.UseShellExecute = $false
    $psi2.CreateNoWindow = $true
    $psi2.RedirectStandardInput = $true
    $psi2.RedirectStandardOutput = $true
    $psi2.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
    $psi2.Arguments = 't ' + (Quote-Arg ('-p' + $pw)) + ' -y ' + (Quote-Arg $file) + ' ' + (Quote-Arg $firstEntry)
    try {
        $p2 = [System.Diagnostics.Process]::Start($psi2)
        Close-ProcStdin $p2
        $out2 = $p2.StandardOutput.ReadToEnd()
        if (-not $p2.WaitForExit(60000)) {
            try { $p2.Kill(); $p2.WaitForExit() } catch {}
            return $false
        }
        return $p2.ExitCode -eq 0
    } catch {
        return $false
    }
}

# Primary extractor once a password is known: 7z handles multi-volume
# (.7z.001/.../rar parts) natively, which magic-extractor can't (it even
# crashes on .001 identify). Falls through to magic-extractor/WinRAR below.
function Invoke-7zExtract([string]$file, [string]$outDir, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = 'x -y -o' + (Quote-Arg $outDir) + ' ' + (Quote-Arg ('-p' + $pw)) + ' ' + (Quote-Arg $file)
    Write-Log ('extracting with 7z (may take minutes): ' + $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(1800000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            Stop-ProcessTree $p.Id
            Write-Log 'WARN 7z extract timeout'
            return $false
        }
        Stop-ProcessTree $p.Id
        # exit 2 = warnings (e.g. encrypted entries without matching password,
        # while plain entries were extracted) - still counts as success if output
        # is non-empty. Broken-directory zip polyglots often mix one plain
        # payload entry with AES decoys.
        if ($p.ExitCode -le 2) {
            $n = @(Get-ChildItem -LiteralPath $outDir -Force -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) {
                $allFiles = @(Get-ChildItem -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
                if ($allFiles.Count -gt 0) {
                    $zero = @($allFiles | Where-Object { $_.Length -eq 0 }).Count
                    if ($zero -gt 0 -and $zero -eq $allFiles.Count) {
                        Write-Log 'WARN 7z extract all files 0 bytes (wrong password)'
                        try { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Path $outDir -Force | Out-Null } catch {}
                        return $false
                    }
                    if ($zero -gt 0) { Write-Log ("WARN 7z extract produced " + $zero + " empty file(s)") }
                }
                Write-Log ('OK 7z extract done: ' + $n + ' item(s) -> ' + $outDir)
                return $true
            }
        }
        Write-Log ('WARN 7z extract failed (exit ' + $p.ExitCode + '): ' + $file)
        return $false
    } catch {
        Write-Log ("WARN 7z extract start failed: " + $_.Exception.Message)
        return $false
    }
}

# In-process fast password test via pwtest.py (py7zr/zipfile, smallest-item verify).
# Returns the matched password as a string ('' means no password),
# or $null when unavailable/unsupported/not matched -> caller falls back to the 7z loop.
function Test-PasswordFast([string]$file, [string]$pwFile) {
    $script = Join-Path $PSScriptRoot 'pwtest.py'
    if (-not (Test-Path -LiteralPath $script)) { return $null }
    $py = Get-PythonExe
    if (-not $py) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = (Quote-Arg $script) + ' ' + (Quote-Arg $file) + ' ' + (Quote-Arg $pwFile)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(300000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            Write-Log 'WARN fast password test timeout, fallback to 7z loop'
            return $null
        }
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line.StartsWith('FOUND ')) {
                $b64 = $line.Substring(6).Trim()
                if ($b64 -eq '') { return '' }
                return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
            }
            if ($line -eq 'NOTFOUND') {
                Write-Log 'fast test: tried all candidates, no match (fallback to 7z loop)'
                return $null
            }
            if ($line -eq 'UNSUPPORTED') {
                Write-Log 'fast test: format not supported by fast path, skipped (fallback to 7z loop)'
                return $null
            }
        }
        if ($stderr -and $stderr.Trim() -ne '') {
            Write-Log ('WARN fast password test stderr: ' + ($stderr -replace "`r?`n", ' '))
        }
        return $null
    } catch {
        Write-Log ('WARN fast password test failed to start: ' + $_.Exception.Message)
        return $null
    }
}

function Get-HotPasswords {
    $hot = Join-Path $PSScriptRoot 'data\hot_passwords.txt'
    if (-not (Test-Path -LiteralPath $hot)) { return @() }
    try {
        return @([System.IO.File]::ReadAllLines($hot) | Where-Object { $_ -ne '' })
    } catch { return @() }
}

function Add-ToPasswordBook([string]$pw) {
    if ($pw -eq '' -or $pw -eq '__jieyaji_no_password__') { return }
    $pwFile = Join-Path $PSScriptRoot 'passwords.txt'
    # Same cross-process serialisation as the hot cache: an exclusive open
    # (FileShare::None) with 3 short retries was easy for 8 concurrent workers
    # to lose, and a lost password means the next archive pays the full loop.
    Invoke-WithFileMutex 'Local\JieyajiPwBook' {
        for ($r = 0; $r -lt 6; $r++) {
            try {
                if (-not (Test-Path -LiteralPath $pwFile)) { return }
                $content = [System.IO.File]::ReadAllText($pwFile, [System.Text.Encoding]::UTF8)
                foreach ($l in ($content -split "`r?`n")) { if ($l -eq $pw) { return } }
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::AppendAllText($pwFile, $pw + "`n", $enc)
                Write-Log ('OK added new password to book: ' + $pw)
                return
            } catch {
                Start-Sleep -Milliseconds (200 * ($r + 1))
            }
        }
    }
}

$script:didSync = $false
function Sync-Passwords {
    param([switch]$Force)
    if ($script:didSync -and -not $Force) { return }
    $script:didSync = $true
    $sync = Join-Path $PSScriptRoot 'sync-passwords.py'
    if (-not (Test-Path -LiteralPath $sync)) { return }
    $py = Get-PythonExe
    if (-not $py) { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $py
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardInput = $true
        $psi.Arguments = Quote-Arg $sync
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(10000)) { try { $p.Kill(); $p.WaitForExit() } catch {} }
        $out = $p.StandardOutput.ReadToEnd()
        if ($out -and $out.Trim() -ne '') { Write-Log ('SYNC ' + $out.Trim()) }
    } catch { Write-Log ('WARN sync failed: ' + $_.Exception.Message) }
}

function Save-HotPassword([string]$pw) {
    if ($pw -eq '' -or $pw -eq '__jieyaji_no_password__') { return }
    $hot = Join-Path $PSScriptRoot 'data\hot_passwords.txt'
    # Read-modify-write under a cross-process mutex: with threads > 1 several
    # workers can hit different passwords at the same time and the last writer
    # used to silently erase the others' entries (move-to-front lost updates).
    Invoke-WithFileMutex 'Local\JieyajiHotPw' {
        for ($r = 0; $r -lt 5; $r++) {
            $tmp = ''
            try {
                $lines = @($pw) + @(Get-HotPasswords | Where-Object { $_ -ne $pw })
                if ($lines.Count -gt 50) { $lines = $lines[0..49] }
                $dir = Split-Path $hot -Parent
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $enc = New-Object System.Text.UTF8Encoding($false)
                # Unique temp name per process: a fixed ".tmp" made concurrent
                # workers write into the very same file and fight over the move.
                $tmp = $hot + '.' + $PID + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                [System.IO.File]::WriteAllText($tmp, ($lines -join "`n") + "`n", $enc)
                if (Test-Path -LiteralPath $hot) {
                    # [NullString]::Value, NOT $null: PowerShell coerces $null to
                    # "" for a [string] parameter, and Replace(..., "") throws
                    # "The path is not of a legal form". That made every single
                    # write fail through all retries - the hot cache silently
                    # never grew while the password book got the entry.
                    [System.IO.File]::Replace($tmp, $hot, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($tmp, $hot)
                }
                break
            } catch {
                if ($r -eq 0) { Write-Log ('WARN hot password write failed: ' + $_.Exception.Message) }
                if ($tmp) { try { [System.IO.File]::Delete($tmp) } catch {} }
                Start-Sleep -Milliseconds (150 * ($r + 1))
            }
        }
        # Sweep leftovers from a crashed run (still inside the mutex, so no
        # other worker can be mid-write here).
        try {
            $dir = Split-Path $hot -Parent
            if (Test-Path -LiteralPath $dir) {
                foreach ($f in [System.IO.Directory]::GetFiles($dir, 'hot_passwords.txt.*.tmp')) {
                    try { [System.IO.File]::Delete($f) } catch {}
                }
            }
        } catch {}
    }
    Add-ToPasswordBook $pw
}

function Read-PasswordList([string]$path) {
    $attempts = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $path)) { return ,$attempts }
    $lines = [System.IO.File]::ReadAllLines($path)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $lines) {
        if ($null -eq $l) { continue }
        if ($l -ne '' -and $seen.Add($l)) { $attempts.Add($l) }
        $t = $l.Trim()
        if ($t -ne '' -and $t -ne $l -and $seen.Add($t)) { $attempts.Add($t) }
    }
    # comma = no-unwrap: an empty list must stay a List, not become $null
    return ,$attempts
}

function Move-Contents([string]$src, [string]$dst) {
    Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $dst -Force -ErrorAction Stop
    }
}

function Collapse-Nested([string]$dir, [string]$baseName) {
    while ($true) {
        $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        $dirs = @($children | Where-Object { $_.PSIsContainer })
        $files = @($children | Where-Object { -not $_.PSIsContainer })
        if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
            $inner = $dirs[0].FullName
            Move-Contents $inner $dir
            [System.IO.Directory]::Delete($inner, $true)
            continue
        }
        break
    }
}

# Every staging directory this worker creates, so the final cleanup can wipe them
# all no matter which code path was taken.
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

# Create a staging dir on the SAME VOLUME as $nearPath. The whole pipeline is
# "extract to staging, then move into place", and a cross-volume Move-Item is a
# full copy+delete: on a 34GB archive that doubles the write I/O and can stall on
# a slow source drive. Same volume turns the final move into an instant rename.
# Tries the archive's own folder first, then the volume root, then %TEMP% only as
# a last resort (keeps working on read-only parents / odd UNC shares).
function New-SiblingTempDir([string]$nearPath, [string]$tag) {
    $name = 'zh_' + $tag + '_' + [guid]::NewGuid().ToString('N')
    $candidates = [System.Collections.Generic.List[string]]::new()
    try {
        $full = [System.IO.Path]::GetFullPath($nearPath)
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            $candidates.Add((Join-Path $parent ('.' + $name)))
        }
        $root = [System.IO.Path]::GetPathRoot($full)
        if ($root) { $candidates.Add((Join-Path $root $name)) }
    } catch {}
    if ($env:TEMP) { $candidates.Add((Join-Path $env:TEMP $name)) }
    foreach ($c in $candidates) {
        try {
            New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null
            $script:TempDirs.Add($c)
            $sameVol = $false
            try {
                $sameVol = ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($nearPath))) -eq
                           ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($c)))
            } catch {}
            if ($sameVol) {
                Write-Log ('staging dir (same volume): ' + $c)
            } else {
                Write-Log ('WARN staging dir on a DIFFERENT volume (cross-drive copy expected): ' + $c)
            }
            return $c
        } catch {}
    }
    return ''
}

function Remove-AllTempDirs {
    foreach ($d in $script:TempDirs) {
        try {
            if ($d -and (Test-Path -LiteralPath $d)) {
                [System.IO.Directory]::Delete($d, $true)
            }
        } catch {}
    }
    $script:TempDirs.Clear()
}

function Resolve-OutputDir([string]$file) {
    $parent = Split-Path $file -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $candidate = Join-Path $parent $base
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $parent ($base + ' (' + $n + ')')
        $n++
    }
    return $candidate
}

# Delete a file permanently with retries (returns $true on success).
# Recycle-bin moves of multi-GB volumes copy the data to C:\$Recycle.Bin and
# take minutes (or hang on locks); an unlink is instant and reliable.
function Remove-File([string]$path) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            [System.IO.File]::Delete($path)
            return $true
        } catch {
            if (-not (Test-Path -LiteralPath $path)) {
                return $true
            }
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

# Sibling volumes of the same archive (e.g. 第1章.7z.001 -> .002..009,
# archive.part1.rar -> .part2+.rar). Empty when the file has no split siblings.
function Get-VolumeSiblings([string]$file) {
    $dir = Split-Path $file -Parent
    $leaf = Split-Path $file -Leaf
    $pat = ''
    if ($leaf -match '^(.+)\.\d{3}$') {
        # 第1章.7z.001 / archive.zip.001 / bare archive.001
        $pat = '^' + [regex]::Escape($matches[1]) + '\.\d{3}$'
    } elseif ($leaf -match '^(.+)\.part\d+\.rar$') {
        # archive.part1.rar. The stem must drop the whole ".partN.rar" tail:
        # GetFileNameWithoutExtension would leave "archive.part1" behind and the
        # old code then built "^archive\.part1\.part\d+\.rar$" - a pattern that
        # can never match, so part2+ were never deleted alongside the first one.
        $pat = '^' + [regex]::Escape($matches[1]) + '\.part\d+\.rar$'
    } elseif ($leaf -match '\.z\d{2}$' -or
              ($leaf -match '\.zip$' -and (Test-Path -LiteralPath (Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($leaf) + '.z01'))))) {
        # WinZip split: archive.zip + archive.z01..z99 (first volume is the .zip)
        $pat = '^' + [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($leaf)) + '\.z\d{2}$'
    } elseif ($leaf -match '\.r\d{2}$' -or
              ($leaf -match '\.rar$' -and (Test-Path -LiteralPath (Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($leaf) + '.r00'))))) {
        # old-style RAR split: archive.rar + archive.r00..r99 (first volume is the .rar)
        $pat = '^' + [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($leaf)) + '\.r\d{2}$'
    }
    if (-not $pat) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.Name -match $pat -and $_.FullName -ne $file } |
        ForEach-Object { $_.FullName })
}

function Detect-ArchiveExtension([string]$file) {
    $map = @{
        '7z' = '.7z'; 'zip' = '.zip'; 'rar' = '.rar'; 'tar' = '.tar'
        'gzip' = '.gz'; 'bzip2' = '.bz2'; 'xz' = '.xz'; 'zstd' = '.zst'
        'cab' = '.cab'; 'iso' = '.iso'; 'lzh' = '.lzh'; 'arj' = '.arj'
        'wim' = '.wim'; 'msi' = '.msi'; 'chm' = '.chm'; 'cpio' = '.cpio'
        'rpm' = '.rpm'; 'deb' = '.deb'; 'vhd' = '.vhd'; 'qcow2' = '.qcow2'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = 'l ' + (Quote-Arg $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        $stdout = $p.StandardOutput.ReadToEnd()
        $null = $p.WaitForExit(30000)
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line -match '^\s*Type\s*=\s*(\S+)') {
                $t = $matches[1].ToLowerInvariant()
                if ($t -like 'rar*') { return '.rar' }
                if ($t -like 'zip*') { return '.zip' }
                if ($t -like 'lzh*' -or $t -like 'lha*') { return '.lzh' }
                if ($t -like 'bzip2*') { return '.bz2' }
                if ($t -like 'gzip*') { return '.gz' }
                if ($t -like 'zstd*') { return '.zst' }
                if ($map.ContainsKey($t)) {
                    return $map[$t]
                }
            }
        }
    } catch {}
    # Broken-directory zip polyglots (MP4 head + zip payload with garbage CD):
    # 7z sniffs the MP4 header and refuses, magic-extractor may crash. Detect
    # the zip EOCD signature directly in the file tail as a cheap positive.
    try {
        $fs = [System.IO.File]::OpenRead($file)
        try {
            $len = $fs.Length
            $tailLen = [int][Math]::Min([long]65536, $len)
            $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
            $buf = New-Object byte[] $tailLen
            [void]$fs.Read($buf, 0, $tailLen)
            for ($i = 0; $i -le $tailLen - 4; $i++) {
                if ($buf[$i] -eq 0x50 -and $buf[$i+1] -eq 0x4B) {
                    if (($buf[$i+2] -eq 0x05 -and $buf[$i+3] -eq 0x06) -or
                        ($buf[$i+2] -eq 0x06 -and $buf[$i+3] -eq 0x06) -or
                        ($buf[$i+2] -eq 0x07 -and $buf[$i+3] -eq 0x06)) {
                        Write-Log 'OK detected zip payload (EOCD in tail)'
                        return '.zip'
                    }
                }
            }
        } finally {
            $fs.Close()
        }
    } catch {}
    try {
        $out = (& $MagicExe identify $file 2>&1 | Out-String)
        if ($out -match '(?i)\brar\b') { return '.rar' }
        if ($out -match '(?i)\b7z\b') { return '.7z' }
        if ($out -match '(?i)\bzip\b') { return '.zip' }
        if ($out -match '(?i)\btar\b') { return '.tar' }
        if ($out -match '(?i)\bgzip\b') { return '.gz' }
    } catch {}
    return ''
}

# Video containers that packs ship as "playable" polyglots: a valid MP4/MKV
# that plays fine, with a ZIP payload appended. This disguise cannot carry a
# password (players must be able to read it without prompting), so the password
# loop is pure waste here - alias it to .zip and let WinRAR's tolerant scanner
# walk the local headers.
$VideoExts = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.m4v', '.webm', '.ts', '.mpg', '.mpeg', '.rmvb', '.rm', '.3gp', '.vob')

# Cheap content probe: does this file carry a zip payload? Appended-zip
# polyglots keep the EOCD record at the very end of the file, so scanning the
# last 64KB is a reliable positive; the head is checked for a local header too.
function Test-ZipPayload([string]$file) {
    try {
        $fs = [System.IO.File]::OpenRead($file)
        try {
            $len = $fs.Length
            if ($len -lt 22) { return $false }
            $headLen = [int][Math]::Min([long]65536, $len)
            $head = New-Object byte[] $headLen
            [void]$fs.Read($head, 0, $headLen)
            $hasLocal = $false
            for ($i = 0; $i -le $headLen - 4; $i++) {
                if ($head[$i] -eq 0x50 -and $head[$i+1] -eq 0x4B -and
                    $head[$i+2] -eq 0x03 -and $head[$i+3] -eq 0x04) { $hasLocal = $true; break }
            }
            $tailLen = [int][Math]::Min([long]65536, $len)
            $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
            $tail = New-Object byte[] $tailLen
            [void]$fs.Read($tail, 0, $tailLen)
            for ($i = 0; $i -le $tailLen - 4; $i++) {
                if ($tail[$i] -eq 0x50 -and $tail[$i+1] -eq 0x4B -and
                    $tail[$i+2] -eq 0x05 -and $tail[$i+3] -eq 0x06) { return $true }
            }
            return $hasLocal
        } finally { $fs.Close() }
    } catch { return $false }
}

# Create a .zip alias for the polyglot. A hardlink is instant and costs no
# disk space (the worker and the source are on the same volume because the
# staging dir is a sibling); fall back to a real copy when hardlinks are not
# supported by the filesystem.
function New-ZipAlias([string]$file, [string]$dir) {
    if (-not $dir) { return '' }
    $alias = Join-Path $dir ('polyglot_' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        New-Item -ItemType HardLink -Path $alias -Target $file -ErrorAction Stop | Out-Null
        return $alias
    } catch {}
    try {
        [System.IO.File]::Copy($file, $alias, $true)
        return $alias
    } catch {}
    return ''
}

# Output sanity check used before deleting a source file: an extraction that
# produced nothing (or only 0-byte decoys from a wrong password) must never
# cost the user the source archive.
function Get-OutputStat([string]$path) {
    $files = 0
    $bytes = [long]0
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $fi = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            return @{ Files = 1; Bytes = [long]$fi.Length }
        }
        foreach ($f in (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            $files++
            $bytes += [long]$f.Length
        }
    } catch {}
    return @{ Files = $files; Bytes = $bytes }
}

$ArchiveExts = @('.rar', '.zip', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.tbz2', '.xz', '.zst', '.lz', '.lzh', '.lha', '.arj', '.cab', '.iso', '.wim', '.001', '.zpaq', '.ace', '.alz', '.egg', '.kgb', '.uha', '.arc', '.bcm', '.pea', '.dgc', '.msi', '.img')

# Detect MP4/polyglot files that carry a broken-directory zip payload: 7z
# sniffs the MP4 header and refuses to open, magic-extractor crashes on it.
# We rebuild the central directory (scan local headers) into a temp copy that
# 7z can open, then the normal password loop + extraction runs on the copy.
# Returns the repaired path, or '' when not applicable/failed.
function Repair-BrokenZip([string]$file) {
    $py = Get-PythonExe
    if (-not $py) { return '' }
    $script = Join-Path $PSScriptRoot 'repair-broken-zip.py'
    if (-not (Test-Path -LiteralPath $script)) { return '' }
    $repairDir = New-SiblingTempDir $file 'repair'
    if (-not $repairDir) { Write-Log 'WARN repair staging dir unavailable'; return '' }
    $repaired = Join-Path $repairDir ('repaired_' + [guid]::NewGuid().ToString('N') + '.zip')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = (Quote-Arg $script) + ' ' + (Quote-Arg $file) + ' ' + (Quote-Arg $repaired)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        Close-ProcStdin $p
        if (-not $p.WaitForExit(600000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            Write-Log 'WARN zip repair timeout'
            return ''
        }
        if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $repaired)) {
            Write-Log ('OK repaired broken zip -> ' + $repaired)
            return $repaired
        }
        Write-Log ('WARN zip repair failed (exit ' + $p.ExitCode + ')')
        return ''
    } catch {
        Write-Log ('WARN zip repair start failed: ' + $_.Exception.Message)
        return ''
    }
}

$ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

# Multi-volume non-first parts (.002~.999 / .part2+.rar / .r00+ / .z01+) can't
# be extracted alone. Users drop them only so the group gets cleaned up after the
# first volume finishes (the first-volume worker deletes the whole group).
# NOTE: must run BEFORE creating $temp - exiting here bypasses the try/finally.
$name = Split-Path $FilePath -Leaf
$isVol = $false
$isFirstVol = $false
if ($ext -match '^\.\d{3}$') { $isVol = $true; $isFirstVol = ($ext -eq '.001') }
elseif ($name -match '\.part(\d+)\.rar$') { $isVol = $true; $isFirstVol = ([int]$matches[1] -eq 1) }
elseif ($name -match '\.r\d\d$') { $isVol = $true }
elseif ($name -match '\.z\d\d$') { $isVol = $true }
if ($isVol -and -not $isFirstVol) {
    Write-Log ('SKIP non-first volume (cannot extract alone): ' + $FilePath)
    Write-Log 'SKIP the first volume (.001/.part1.rar) does the extraction and deletes the whole group'
    exit 0
}

$base = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

# Playable-mp4 polyglot: probe the content BEFORE any rename. The old flow
# renamed the user's video in place to "name.zip" - a failed extraction then
# left it stuck under a new name. Keep the original path untouched instead and
# build a .zip alias in staging; the source is deleted only after verification.
$isVideoExt = $VideoExts -contains $ext
$polyglotZip = $false
if ($isVideoExt) {
    $polyglotZip = Test-ZipPayload $FilePath
    if ($polyglotZip) {
        Write-Log ("OK zip payload inside video container (" + $ext + "): alias to .zip + WinRAR")
        Write-Log 'note: this playable polyglot cannot be password-encrypted - password loop will be skipped'
    } else {
        Write-Log ("OK video container (" + $ext + "): no zip payload found")
    }
}

if (-not ($ArchiveExts -contains $ext) -and -not $polyglotZip) {
    Write-Log ("OK detecting real format: " + $FilePath)
    $detected = Detect-ArchiveExtension $FilePath
    if ($detected) {
        $parent = Split-Path $FilePath -Parent
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $newPath = Join-Path $parent ($baseName + $detected)
        $n = 2
        while (Test-Path -LiteralPath $newPath) {
            $newPath = Join-Path $parent ($baseName + ' (' + $n + ')' + $detected)
            $n++
        }
        [System.IO.File]::Move($FilePath, $newPath)
        Write-Log ("OK detected real format " + $detected + ", renamed to " + $newPath)
        $FilePath = $newPath
        $ext = $detected
    } else {
        Write-Log 'WARN could not detect archive format'
    }
}

if ($polyglotZip) {
    Write-Log 'OK mp4 polyglot: zip mode, no password possible'
} elseif ($ArchiveExts -contains $ext) {
    Write-Log ("OK normal archive ($ext): start password loop")
} else {
    Write-Log ("OK non-archive extension ($ext): detect content")
}

# Created here (not earlier) so the try/finally below always owns its cleanup.
$temp = New-SiblingTempDir $FilePath 'extract'
if (-not $temp) { Write-Log 'FAIL could not create staging directory'; exit 1 }

try {
    if (-not (Test-Path -LiteralPath $SevenZip)) {
        Write-Log ("WARN 7z not found: " + $SevenZip + " (7z fast path disabled)")
    }

    # mp4 polyglot: hardlink the source as *.zip in its own staging dir (kept
    # apart from $temp so the alias never gets mistaken for extracted content).
    $polyglotAlias = ''
    if ($polyglotZip) {
        $aliasDir = New-SiblingTempDir $FilePath 'zipalias'
        if ($aliasDir) {
            $polyglotAlias = New-ZipAlias $FilePath $aliasDir
            if ($polyglotAlias) {
                Write-Log ('OK mp4 -> .zip alias: ' + $polyglotAlias)
            } else {
                Write-Log 'WARN could not create .zip alias; will try the original file'
            }
        } else {
            Write-Log 'WARN alias staging dir unavailable'
        }
    }

    $attempts = Read-PasswordList $PasswordFile
    if ($attempts.Count -eq 0) {
        $attempts.Add('')
    }
    $hotPws = Get-HotPasswords
    if ($hotPws.Count -gt 0) {
        $merged = [System.Collections.Generic.List[string]]::new()
        $seenM = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $hotPws) { if ($seenM.Add($p)) { $merged.Add($p) } }
        foreach ($p in $attempts) { if ($seenM.Add($p)) { $merged.Add($p) } }
        $attempts = $merged
    }
    if (-not $attempts.Contains('')) { $attempts.Insert(0, '') }
    Write-Log ("OK loaded " + $attempts.Count + " password candidates (" + $hotPws.Count + " hot)")

    $found = $null
    $winrarOk = $false
    $tryIndex = 0
    if ($polyglotZip) {
        # Playable mp4 polyglots cannot carry a password: the player has to read
        # the payload without prompting. Skip the candidate loop entirely.
        $found = ''
        Write-Log 'mp4 polyglot: password loop skipped'
    } else {
    Write-Log 'Fast password test (in-process)...'
    $fast = Test-PasswordFast $FilePath $PasswordFile
    if ($null -ne $fast) {
        $found = $fast
        if ($found -eq '') {
            Write-Log 'OK password matched (fast): <no password>'
        } else {
            Write-Log ("OK password matched (fast): " + $found)
            Save-HotPassword $found
        }
    }
    if ($null -eq $found) {
    Write-Log 'Testing passwords (7z test)...'
    Initialize-ArchiveProbe $FilePath
    if (-not $script:ArcProbe.Ok) {
        Write-Log 'probe: header is encrypted (listing needs a password) - validating with 7z l -p'
    } elseif (-not $script:ArcProbe.AnyEncrypted) {
        Write-Log 'probe: no encrypted entries (plain archive) - no password needed'
    } else {
        Write-Log ('probe: encrypted entries present, verifying against smallest one: ' + $script:ArcProbe.MinEntry)
    }
    foreach ($pw in $attempts) {
        $tryIndex++
        if (($tryIndex % 25) -eq 0) {
            Write-Log ("... tried " + $tryIndex + "/" + $attempts.Count + " passwords")
        }
        if (Test-ArchivePassword $FilePath $pw) {
            $found = $pw
            if ($pw -eq '') { Write-Log 'OK password matched: <no password>' } else { Write-Log ("OK password matched: " + $pw) }
            Save-HotPassword $pw
            break
        }
    }
    }
    }

    if ($null -eq $found) {
        Write-Log 'Trying WinRAR fallback (no password; tolerant scanner for broken-directory zip/polyglot)...'
        if (Invoke-WinRARExtract $FilePath $temp '') {
            Write-Log 'OK extracted via WinRAR fallback (no password)'
            $found = ''
            $winrarOk = $true
        }
    }

    $repairedPath = ''
    if ($null -eq $found) {
        # Broken-directory zip polyglots (e.g. MP4 + zip with garbage CD) can't
        # be opened by 7z at all: rebuild the central directory into a copy,
        # then run the password loop + extraction against the copy.
        Write-Log 'Password loop failed; trying zip repair (broken-directory polyglot)...'
        $repairedPath = Repair-BrokenZip $FilePath
        if ($repairedPath) {
            Write-Log 'Testing passwords against repaired zip...'
            Initialize-ArchiveProbe $repairedPath
            if (-not $script:ArcProbe.Ok) {
                Write-Log 'probe (repaired): header is encrypted - validating with 7z l -p'
            } elseif (-not $script:ArcProbe.AnyEncrypted) {
                Write-Log 'probe (repaired): no encrypted entries (plain payload) - no password needed'
            } else {
                Write-Log ('probe (repaired): verifying against smallest encrypted entry: ' + $script:ArcProbe.MinEntry)
            }
            $tryIndex = 0
            foreach ($pw in $attempts) {
                $tryIndex++
                if (($tryIndex % 25) -eq 0) {
                    Write-Log ("... repaired tried " + $tryIndex + "/" + $attempts.Count + " passwords")
                }
                if (Test-ArchivePassword $repairedPath $pw) {
                    $found = $pw
                    if ($pw -eq '') { Write-Log 'OK password matched (repaired): <no password>' } else { Write-Log ("OK password matched (repaired): " + $pw) }
                    Save-HotPassword $pw
                    break
                }
            }
            if ($null -eq $found) {
                # No candidate matched. Mixed archives (plain payload + encrypted
                # decoys) can still be extracted with an empty password, so keep
                # the lenient fallback and let Invoke-7zExtract's 0-byte guard
                # reject it if that was wrong.
                $found = ''
                Write-Log 'OK repaired zip opens without password (plain payload entry)'
            }
        }
    }

    if ($null -eq $found -and $MagicFallback) {
        Write-Log '7z test did not match; trying magic-extractor fallback (SLOW, full extract per password)...'
        $tryIndex = 0
        foreach ($pw in $attempts) {
            $tryIndex++
            if (($tryIndex % 10) -eq 0) {
                Write-Log ("... fallback tried " + $tryIndex + "/" + $attempts.Count + " passwords")
            }
            if (Invoke-MagicExtract $FilePath $temp $pw) {
                $found = $pw
                Write-Log ("OK password matched: " + $pw)
                Save-HotPassword $pw
                break
            }
        }
    }

    if ($null -eq $found) {
        if (-not $MagicFallback) {
            Write-Log 'FAIL no password matched (magic-extractor fallback not enabled; tick the option in the UI to brute-force)'
        } else {
            Write-Log 'FAIL no password matched'
        }
        exit 1
    }
    if ($found -ne '' -and $found -ne '__jieyaji_no_password__') {
        Sync-Passwords
    }

    $ok = $true
    $extractTarget = $FilePath
    if ($polyglotZip) {
        # mp4 -> .zip alias -> WinRAR first (its scanner tolerates the polyglot
        # layout). Only if that fails, rebuild the central directory and let the
        # normal 7z/magic/WinRAR chain run on the repaired copy.
        if ($polyglotAlias) {
            $extractTarget = $polyglotAlias
            Write-Log ('extracting mp4 polyglot from .zip alias: ' + $extractTarget)
            if (Invoke-WinRARExtract $extractTarget $temp '') {
                Write-Log 'OK mp4 polyglot extracted via WinRAR (no password)'
                $winrarOk = $true
            } else {
                Write-Log 'WinRAR failed on mp4 polyglot; trying zip repair...'
                $repairedPath = Repair-BrokenZip $extractTarget
                if ($repairedPath) {
                    $extractTarget = $repairedPath
                    Write-Log ('extracting from repaired copy: ' + $extractTarget)
                }
            }
        } else {
            Write-Log 'WARN mp4 polyglot has no .zip alias; trying the original file'
        }
    } elseif ($repairedPath) {
        $extractTarget = $repairedPath
        Write-Log ('extracting from repaired copy: ' + $extractTarget)
    }
    if (-not $winrarOk) {
        $ok = Invoke-7zExtract $extractTarget $temp $found
        if (-not $ok) {
            Write-Log '7z extract failed; trying magic-extractor...'
            $ok = Invoke-MagicExtract $extractTarget $temp $found
            if (-not $ok) {
                Write-Log 'Magic-extractor failed; trying WinRAR fallback (known password)...'
                $ok = Invoke-WinRARExtract $extractTarget $temp $found
                if (-not $ok) {
                    Write-Log 'WinRAR with password failed; trying WinRAR without password...'
                    $ok = Invoke-WinRARExtract $extractTarget $temp ''
                    if ($ok) {
                        Write-Log 'OK extracted via WinRAR fallback (no password)'
                        $winrarOk = $true
                    }
                } else {
                    Write-Log 'OK extracted via WinRAR fallback (with password)'
                    $winrarOk = $true
                }
            }
        }
    }
    if (-not $ok) {
        Write-Log 'FAIL extraction failed'
        exit 1
    }

    $tmpChildren = @(Get-ChildItem -LiteralPath $temp -Force -ErrorAction SilentlyContinue)
    $final = ''
    $finalIsFile = $false
    if ($tmpChildren.Count -eq 0) {
        Write-Log 'FAIL extracted content empty'
        exit 1
    } elseif ($tmpChildren.Count -eq 1) {
        $single = $tmpChildren[0]
        if ($single.PSIsContainer) {
            $deepest = $single
            $depth = 0
            while ($depth -lt 20) {
                $sub = @(Get-ChildItem -LiteralPath $deepest.FullName -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
                $dirs = @($sub | Where-Object { $_.PSIsContainer })
                $files = @($sub | Where-Object { -not $_.PSIsContainer })
                if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
                    $deepest = $dirs[0]
                    $depth++
                } else { break }
            }
            $parent = Split-Path $FilePath -Parent
            $targetName = $deepest.Name
            $candidate = Join-Path $parent $targetName
            $n = 2
            while (Test-Path -LiteralPath $candidate) {
                $candidate = Join-Path $parent ($targetName + ' (' + $n + ')')
                $n++
            }
            try {
                Move-Item -LiteralPath $deepest.FullName -Destination $candidate -Force -ErrorAction Stop
            } catch {
                try {
                    Copy-Item -LiteralPath $deepest.FullName -Destination $candidate -Recurse -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $deepest.FullName -Recurse -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log ('FAIL move deepest folder: ' + $_.Exception.Message)
                    exit 1
                }
            }
            $final = $candidate
            Write-Log ('OK smart single folder -> ' + $final)
        } else {
            $parent = Split-Path $FilePath -Parent
            $fName = $single.Name
            $candidate = Join-Path $parent $fName
            if (Test-Path -LiteralPath $candidate) {
                $ext2 = [System.IO.Path]::GetExtension($fName)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($fName)
                $n = 2
                while (Test-Path -LiteralPath $candidate) {
                    $candidate = Join-Path $parent ($stem + ' (' + $n + ')' + $ext2)
                    $n++
                }
            }
            try {
                Move-Item -LiteralPath $single.FullName -Destination $candidate -Force -ErrorAction Stop
            } catch {
                try {
                    Copy-Item -LiteralPath $single.FullName -Destination $candidate -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $single.FullName -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log ('FAIL move single file: ' + $_.Exception.Message)
                    exit 1
                }
            }
            $final = $candidate
            $finalIsFile = $true
            Write-Log ('OK smart single file -> ' + $final)
        }
    } else {
        $final = Resolve-OutputDir $FilePath
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        Write-Log ('moving extracted files to output (may take a while): ' + $final)
        Move-Contents $temp $final
        Write-Log ('OK moved to ' + $final)
        if ($Collapse) {
            Write-Log 'collapsing nested folder...'
            Collapse-Nested $final $base
            Write-Log 'OK collapse done'
        }
    }

    if ($finalIsFile -and ($ArchiveExts -contains ([System.IO.Path]::GetExtension($final).ToLowerInvariant()))) {
        $nFile2 = $final
        $nParent2 = Split-Path $nFile2 -Parent
        $nTemp2 = New-SiblingTempDir $nFile2 'nested'
        if (-not $nTemp2) { $nTemp2 = New-SiblingTempDir $nParent2 'nested' }
        if (-not $nTemp2) { Write-Log 'FAIL nested staging dir unavailable'; exit 1 }
        $nPw2 = ''
        Initialize-ArchiveProbe $nFile2
        foreach ($pw in $attempts) {
            if (Test-ArchivePassword $nFile2 $pw) {
                $nPw2 = $pw
                if ($pw -eq '') { Write-Log 'OK nested single file needs no password' } else { Write-Log ("OK nested password matched: " + $pw); Save-HotPassword $pw }
                break
            }
        }
        $nOk2 = Invoke-7zExtract $nFile2 $nTemp2 $nPw2
        if ($nOk2) {
            $nFinal2 = Resolve-OutputDir $nFile2
            New-Item -ItemType Directory -Path $nFinal2 -Force | Out-Null
            Move-Contents $nTemp2 $nFinal2
            if (-not (Remove-File $nFile2)) { Write-Log ('WARN could not delete nested archive: ' + $nFile2) }
            $final = $nFinal2
            $finalIsFile = $false
            Write-Log ('OK nested single-file extracted -> ' + $final)
        }
        try { Remove-Item -LiteralPath $nTemp2 -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Recursively expand nested archives found inside the extracted output
    # (e.g. the repaired polyglot yields 课件2815.zip, which itself is an
    # archive that must be extracted again). Keeps going until no archives
    # remain or depth limit is hit.
    $nestDepth = 0
    while (-not $finalIsFile -and $nestDepth -lt 5) {
        $nested = @(Get-ChildItem -LiteralPath $final -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $ArchiveExts -contains $_.Extension.ToLowerInvariant() })
        if ($nested.Count -eq 0) { break }
        $nestDepth++
        Write-Log ("nested archives found: " + ((@($nested | ForEach-Object { $_.Name })) -join ', '))
        foreach ($n in $nested) {
            $nFile = $n.FullName
            Write-Log ('extracting nested: ' + $nFile)
            $nTemp = New-SiblingTempDir $nFile 'nested'
            if (-not $nTemp) { Write-Log ('WARN nested staging dir unavailable, skipped: ' + $nFile); continue }
            $nOk = $false
            $nPw = ''
            # 'l' answers exit 0 to every password on plaintext-header archives,
            # so probe once and verify candidates against the smallest encrypted
            # entry. Plain archives match on '' (the first candidate) at once.
            Initialize-ArchiveProbe $nFile
            foreach ($pw in $attempts) {
                if (Test-ArchivePassword $nFile $pw) {
                    $nPw = $pw
                    if ($pw -eq '') {
                        Write-Log 'OK nested needs no password'
                    } else {
                        Write-Log ("OK nested password matched: " + $pw)
                        Save-HotPassword $pw
                    }
                    break
                }
            }
            $nOk = Invoke-7zExtract $nFile $nTemp $nPw
            if ($nOk) {
                # encrypted entries failing leave 0-byte artifacts - treat as failure
                $zeroBytes = @(Get-ChildItem -LiteralPath $nTemp -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer -and $_.Length -eq 0 })
                if ($zeroBytes.Count -gt 0) {
                    Write-Log ("WARN nested extract produced " + $zeroBytes.Count + " empty file(s), password may be wrong")
                    $nOk = $false
                }
            }
            if ($nOk) {
                Move-Contents $nTemp $final
                if ($Collapse) {
                    Collapse-Nested $final ([System.IO.Path]::GetFileNameWithoutExtension($n.Name))
                }
                # Permanent delete, not a recycle-bin move: a multi-GB nested
                # archive would otherwise be copied to C:\$Recycle.Bin first.
                if (-not (Remove-File $nFile)) { Write-Log ('WARN could not delete nested archive: ' + $nFile) }
                Write-Log ('OK nested extracted and removed: ' + $nFile)
            } else {
                Write-Log ('WARN nested extract failed, kept as-is: ' + $nFile)
            }
            try { Remove-Item -LiteralPath $nTemp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    if ($nestDepth -ge 5) {
        Write-Log 'WARN nested extraction depth limit reached'
    }
    if ($found -ne '' -or $nestDepth -gt 0) { Sync-Passwords -Force }
    Write-Log ("DONE " + $final)
    if ($DeleteSource -and (Test-Path -LiteralPath $FilePath)) {
        # Confirm the output before touching the source: an empty / all-zero-byte
        # result means the extraction did not really succeed (wrong password left
        # 0-byte decoys, or the archive was a decoy container).
        $outStat = Get-OutputStat $final
        if ($outStat.Files -le 0 -or $outStat.Bytes -le 0) {
            Write-Log ('WARN output check failed (' + $outStat.Files + ' file(s), ' + $outStat.Bytes + ' byte(s)) - source kept: ' + $FilePath)
        } else {
            Write-Log ('OK confirmed output: ' + $outStat.Files + ' file(s), ' + $outStat.Bytes + ' byte(s)')
            if (Remove-File $FilePath) {
                Write-Log ('OK deleted source: ' + $FilePath)
                foreach ($sib in (Get-VolumeSiblings $FilePath)) {
                    if (Remove-File $sib) {
                        Write-Log ('OK deleted sibling volume: ' + $sib)
                    } else {
                        Write-Log ('WARN delete sibling volume failed: ' + $sib)
                    }
                }
            } else {
                Write-Log ('WARN delete source failed after retries: ' + $FilePath)
            }
        }
    }
    exit 0
} finally {
    Remove-AllTempDirs
}
