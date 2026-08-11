param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$PasswordFile = 'D:\解压姬\passwords.txt',
    [string]$MagicExe = 'D:\解压姬\magic-extractor.exe',
    [switch]$Collapse,
    [switch]$DeleteSource,
    [switch]$MagicFallback,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'
$SevenZip = 'D:\解压姬\bin\extractors\7z\7z.exe'

function Write-Log([string]$m) {
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value $m -Encoding UTF8
    } else {
        [System.Console]::Out.WriteLine($m)
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
    $psi.Arguments = 'e -y -o+ ' + (Quote-Arg $file) + ' ' + (Quote-Arg $outDir)
    if ($pw -ne '') {
        $psi.Arguments += ' -p' + (Quote-Arg $pw)
    } else {
        # -p- : never prompt for a password (no GUI dialog, fail fast on encrypted archives)
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
        if ($p.ExitCode -eq 0) {
            $n = @(Get-ChildItem -LiteralPath $outDir -Force -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) {
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
    $py = 'C:\Python314\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { $py = 'python' }
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

function Save-HotPassword([string]$pw) {
    if ($pw -eq '') { return }
    $hot = Join-Path $PSScriptRoot 'data\hot_passwords.txt'
    $lines = @($pw) + @(Get-HotPasswords | Where-Object { $_ -ne $pw })
    if ($lines.Count -gt 50) { $lines = $lines[0..49] }
    try {
        $dir = Split-Path $hot -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($hot, ($lines -join "`n") + "`n", $enc)
    } catch {}
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
            $innerName = $dirs[0].Name
            $leaf = Split-Path $dir -Leaf
            if ($innerName -eq $baseName -or $innerName -eq $leaf) {
                $inner = $dirs[0].FullName
                Move-Contents $inner $dir
                [System.IO.Directory]::Delete($inner, $true)
                continue
            }
        }
        break
    }
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
    $base = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $pat = ''
    if ($leaf -match '\.\d{3}$') { $pat = '^' + [regex]::Escape($base) + '\.\d{3}$' }
    elseif ($leaf -match '\.part(\d+)\.rar$') { $pat = '^' + [regex]::Escape($base) + '\.part\d+\.rar$' }
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

$ArchiveExts = @('.rar', '.zip', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.tbz2', '.xz', '.zst', '.lz', '.lzh', '.lha', '.arj', '.cab', '.iso', '.wim', '.001', '.zpaq', '.ace', '.alz', '.egg', '.kgb', '.uha', '.arc', '.bcm', '.pea', '.dgc', '.msi', '.img')

$ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

# Multi-volume non-first parts (.002~.999 / .part2+.rar / .r00+ / .z01+) can't
# be extracted alone. Users drop them only so the group gets cleaned up after the
# first volume finishes (the first-volume worker deletes the whole group).
# NOTE: must run BEFORE creating $temp - exiting here bypasses the try/finally.
$name = Split-Path $FilePath -Leaf
$isVol = $false
$isFirstVol = $false
if ($ext -match '^\.\d{3}$') { $isVol = $true; $isFirstVol = ($ext -eq '.001') }
elseif ($name -match '\.part(\d+)\.rar$') { $isVol = $true; $isFirstVol = ($matches[1] -eq '1') }
elseif ($name -match '\.r\d\d$') { $isVol = $true }
elseif ($name -match '\.z\d\d$') { $isVol = $true }
if ($isVol -and -not $isFirstVol) {
    Write-Log ('SKIP non-first volume (cannot extract alone): ' + $FilePath)
    Write-Log 'SKIP the first volume (.001/.part1.rar) does the extraction and deletes the whole group'
    exit 0
}

$base = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
$temp = Join-Path $env:TEMP ('zh_extract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

if (-not ($ArchiveExts -contains $ext)) {
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

if ($ArchiveExts -contains $ext) {
    Write-Log ("OK normal archive ($ext): start password loop")
} else {
    Write-Log ("OK non-archive extension ($ext): detect content")
}

try {
    if (-not (Test-Path -LiteralPath $SevenZip)) {
        Write-Log ("WARN 7z not found: " + $SevenZip + " (7z fast path disabled)")
    }
    $attempts = Read-PasswordList $PasswordFile
    if ($attempts.Count -eq 0) {
        $attempts.Add('__jieyaji_no_password__')
    }
    $hotPws = Get-HotPasswords
    if ($hotPws.Count -gt 0) {
        $merged = [System.Collections.Generic.List[string]]::new()
        $seenM = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $hotPws) { if ($seenM.Add($p)) { $merged.Add($p) } }
        foreach ($p in $attempts) { if ($seenM.Add($p)) { $merged.Add($p) } }
        $attempts = $merged
    }
    Write-Log ("OK loaded " + $attempts.Count + " password candidates (" + $hotPws.Count + " hot)")

    $found = $null
    $winrarOk = $false
    $tryIndex = 0
    Write-Log 'Fast password test (in-process)...'
    $fast = Test-PasswordFast $FilePath $PasswordFile
    if ($null -ne $fast) {
        $found = $fast
        if ($found -eq '') {
            Write-Log 'OK password matched (fast): <no password>'
        } else {
            Write-Log ("OK password matched (fast): " + $found)
        }
    }
    if ($null -eq $found) {
    Write-Log 'Testing passwords (7z test)...'
    foreach ($pw in $attempts) {
        $tryIndex++
        if (($tryIndex % 25) -eq 0) {
            Write-Log ("... tried " + $tryIndex + "/" + $attempts.Count + " passwords")
        }
        if (Test-Password7z $FilePath $pw) {
            $found = $pw
            Write-Log ("OK password matched: " + $pw)
            Save-HotPassword $pw
            break
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

    $ok = $true
    if (-not $winrarOk) {
        $ok = Invoke-7zExtract $FilePath $temp $found
        if (-not $ok) {
            Write-Log '7z extract failed; trying magic-extractor...'
            $ok = Invoke-MagicExtract $FilePath $temp $found
            if (-not $ok) {
                Write-Log 'Magic-extractor failed; trying WinRAR fallback (known password)...'
                $ok = Invoke-WinRARExtract $FilePath $temp $found
                if (-not $ok) {
                    Write-Log 'WinRAR with password failed; trying WinRAR without password...'
                    $ok = Invoke-WinRARExtract $FilePath $temp ''
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
    Write-Log ("DONE " + $final)
    if ($DeleteSource -and (Test-Path -LiteralPath $FilePath)) {
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
    exit 0
} finally {
    if (Test-Path -LiteralPath $temp) {
        [System.IO.Directory]::Delete($temp, $true)
    }
}
