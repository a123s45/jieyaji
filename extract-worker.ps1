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
        Write-Output $m
    }
}

function Quote-Arg([string]$s) {
    return '"' + $s.Replace('"', '\"') + '"'
}

function Invoke-MagicExtract([string]$file, [string]$outDir, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MagicExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Arguments = 'extract ' + (Quote-Arg $file) + ' ' + (Quote-Arg $outDir)
    $psi.Arguments += ' --create-log-files false'
    if ($pw -ne '') {
        $psi.Arguments += ' --password ' + (Quote-Arg $pw)
    }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(300000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            return $false
        }
        return $p.ExitCode -eq 0
    } catch {
        Write-Log ("WARN magic-extractor start failed: " + $_.Exception.Message)
        return $false
    }
}

function Test-Password7z([string]$file, [string]$pw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Arguments = 't ' + (Quote-Arg ('-p' + $pw)) + ' -y ' + (Quote-Arg $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(60000)) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            return $false
        }
        return $p.ExitCode -eq 0
    } catch {
        Write-Log ("WARN 7z start failed (" + $SevenZip + "): " + $_.Exception.Message)
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
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = (Quote-Arg $script) + ' ' + (Quote-Arg $file) + ' ' + (Quote-Arg $pwFile)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
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
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($path)
    $attempts = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $lines) {
        if ($null -eq $l) { continue }
        if ($l -ne '' -and $seen.Add($l)) { $attempts.Add($l) }
        $t = $l.Trim()
        if ($t -ne '' -and $t -ne $l -and $seen.Add($t)) { $attempts.Add($t) }
    }
    return $attempts
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
    $psi.Arguments = 'l ' + (Quote-Arg $file)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit(30000)
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line -match '^\s*Type\s*=\s*(\S+)') {
                $t = $matches[1].ToLowerInvariant()
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

$base = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
$temp = Join-Path $env:TEMP ('zh_extract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

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

    $ok = Invoke-MagicExtract $FilePath $temp $found
    if (-not $ok) {
        Write-Log 'FAIL extraction failed'
        exit 1
    }

    $final = Resolve-OutputDir $FilePath
    New-Item -ItemType Directory -Path $final -Force | Out-Null
    Move-Contents $temp $final
    if ($Collapse) {
        Collapse-Nested $final $base
    }
    Write-Log ("DONE " + $final)
    if ($DeleteSource -and (Test-Path -LiteralPath $FilePath)) {
        $deleted = $false
        $lastErr = ''
        for ($i = 1; $i -le 6; $i++) {
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $FilePath,
                    'OnlyErrorDialogs',
                    'SendToRecycleBin'
                )
                $deleted = $true
                break
            } catch {
                $lastErr = $_.Exception.Message
                if (-not (Test-Path -LiteralPath $FilePath)) {
                    # file is gone despite the exception (recycle-bin move quirks) - treat as success
                    $deleted = $true
                    break
                }
                Start-Sleep -Seconds 1
            }
        }
        if ($deleted) {
            Write-Log ('OK deleted source: ' + $FilePath)
        } else {
            Write-Log ('WARN delete source failed after retries: ' + $lastErr)
        }
    }
    exit 0
} finally {
    if (Test-Path -LiteralPath $temp) {
        [System.IO.Directory]::Delete($temp, $true)
    }
}
