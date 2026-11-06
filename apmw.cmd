@rem
@rem apmw - wrapper for Microsoft APM (Agent Package Manager), in the spirit of gradlew.
@rem https://github.com/skerkewitz/apmw
@rem
@rem Windows counterpart of ./apmw. The cmd part below only finds the cached apm.exe
@rem and runs it; downloading and the --apmw-* commands are done by the PowerShell
@rem part at the end of this file. Run "apmw --apmw-help" for details.
@rem
@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "APMW_SELF=%~f0"
set "APMW_PROPS=%~dp0apm\wrapper\apmw.properties"
rem Runs the PowerShell part of this file (everything after the #apmw-powershell line).
set APMW_PS=powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$s=[IO.File]::ReadAllText($env:APMW_SELF); $i=$s.IndexOf([char]10+'#apmw-powershell'); if ($i -lt 0) { exit 1 }; & ([ScriptBlock]::Create($s.Substring($i)))"

set "APMW_ACTION=%~1"
if /i "%APMW_ACTION:~0,7%"=="--apmw-" goto :wrapper_command

if /i "%~1"=="self-update" (
    echo apmw: error: apm is managed by apmw; use "apmw --apmw-upgrade-apm [VERSION]" to change the pinned version 1>&2
    exit /b 1
)

rem Fast path: run the pinned apm from the cache without starting PowerShell.
call :resolve_exe
if defined APMW_VER if exist "%APMW_EXE%" goto :run_apm

rem Slow path: PowerShell pins the latest apm if none is pinned yet, then installs it.
set "APMW_ACTION=--apmw-ensure"
%APMW_PS%
if errorlevel 1 exit /b 1
call :resolve_exe
if not exist "%APMW_EXE%" exit /b 1

:run_apm
"%APMW_EXE%" %*
exit /b %ERRORLEVEL%

:resolve_exe
set "APMW_VER=%APMW_APM_VERSION%"
if not defined APMW_VER if exist "%APMW_PROPS%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%APMW_PROPS%") do (
        if "%%a"=="apmVersion" set "APMW_VER=%%b"
    )
)
if defined APMW_HOME (set "APMW_DIR=%APMW_HOME%") else set "APMW_DIR=%LOCALAPPDATA%\apmw"
set "APMW_EXE=%APMW_DIR%\dists\%APMW_VER%\windows-x86_64\apm.exe"
exit /b 0

:wrapper_command
rem Kept on one line: --apmw-upgrade replaces this file while it runs, and cmd
rem reads a batch file line by line. The exit codes must be explicit: a bare
rem "exit /b" returns 0 when the file was started with "cmd /c".
set "APMW_ARG=%~2" & (%APMW_PS% && exit /b 0 || exit /b 1)

#apmw-powershell
# ---------------------------------------------------------------------------------
# PowerShell part (Windows PowerShell 5.1+). Started by the cmd part above with:
#   APMW_SELF   path of this file
#   APMW_ACTION --apmw-ensure | --apmw-help | --apmw-version | --apmw-upgrade-apm | --apmw-upgrade
#   APMW_ARG    optional version argument
# ---------------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with a progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Set to the release tag by the release workflow; 'dev' in a source checkout.
$ApmwVersion = 'dev'

$DefaultApmReleasesUrl = 'https://github.com/microsoft/apm/releases'
$DefaultWrapperReleasesUrl = 'https://github.com/skerkewitz/apmw/releases'
$AllPlatforms = 'linux-x86_64', 'linux-arm64', 'darwin-x86_64', 'darwin-arm64', 'windows-x86_64'
$Platform = 'windows-x86_64'   # also used on Windows on ARM (x64 emulation)

$Self = $env:APMW_SELF
$AppHome = Split-Path -Parent $Self
$PropsFile = Join-Path $AppHome 'apm\wrapper\apmw.properties'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Info([string]$m) { [Console]::Error.WriteLine("apmw: $m") }
function Fail([string]$m) { [Console]::Error.WriteLine("apmw: error: $m"); exit 1 }

function Read-Props {
    $h = @{}
    if (Test-Path -LiteralPath $PropsFile) {
        foreach ($line in [IO.File]::ReadAllLines($PropsFile)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith('!')) { continue }
            $i = $t.IndexOf('=')
            if ($i -lt 1) { continue }
            $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
        }
    }
    $h
}

# Update or append keys, keep everything else (comments, order, line endings).
function Set-Props($kv) {
    $dir = Split-Path -Parent $PropsFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $text = if (Test-Path -LiteralPath $PropsFile) { [IO.File]::ReadAllText($PropsFile) } else { '' }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $done = @{}
    if ($text -ne '') {
        foreach ($line in ($text.TrimEnd("`r", "`n") -split "`r?`n")) {
            $t = $line.Trim()
            $i = $t.IndexOf('=')
            if (-not ($t.StartsWith('#') -or $t.StartsWith('!')) -and $i -gt 0) {
                $key = $t.Substring(0, $i).Trim()
                if ($kv.Contains($key)) {
                    if (-not $done.ContainsKey($key)) { $lines.Add("$key=$($kv[$key])") }
                    $done[$key] = $true
                    continue
                }
            }
            $lines.Add($line)
        }
    }
    foreach ($key in $kv.Keys) { if (-not $done.ContainsKey($key)) { $lines.Add("$key=$($kv[$key])") } }
    $tmp = "$PropsFile.tmp"
    [IO.File]::WriteAllText($tmp, (($lines -join $nl) + $nl), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $PropsFile -Force
}

function Get-Setting([string]$envName, [string]$key, [string]$default) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if ($Props[$key]) { return $Props[$key] }
    $default
}

function Download([string]$url, [string]$dest) {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
}

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }

function Normalize-Version([string]$v) { if ($v -match '^[0-9]') { "v$v" } else { $v } }

# Tag name that <releasesUrl>/latest redirects to.
function Get-LatestTag([string]$releasesUrl) {
    try {
        $req = [Net.HttpWebRequest]::Create("$releasesUrl/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'apmw'
        $resp = $req.GetResponse()
        $location = $resp.Headers['Location']
        $resp.Close()
    } catch { return $null }
    if ($location -match '/releases/tag/([^/?#]+)$') { return $Matches[1] }
    $null
}

function New-TempDir([string]$parent) {
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $d = Join-Path $parent (".apmw-tmp." + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function Remove-Dir([string]$d) {
    if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-Apm {
    if (-not $ApmVersion) {
        # Like a fresh gradle wrapper: nothing pinned yet, so pin the latest release.
        Info "no apm version pinned yet, pinning the latest release"
        Upgrade-Apm ''
        $Props = Read-Props
        $PinnedVersion = $Props['apmVersion']
        $ApmVersion = $PinnedVersion
        Complete-Wrapper
    }
    $verDir = Join-Path $ApmwHome "dists\$ApmVersion"
    $apmDir = Join-Path $verDir $Platform
    if (Test-Path -LiteralPath (Join-Path $apmDir 'apm.exe')) { return }

    $asset = "apm-$Platform.zip"
    $url = "$ApmReleasesUrl/download/$ApmVersion/$asset"
    # The temp dir lives next to the final location: AppLocker often blocks running
    # programs from %TEMP%, and a rename on the same volume is atomic.
    $tmp = New-TempDir $verDir
    try {
        Info "downloading apm $ApmVersion for $Platform ..."
        try { Download $url (Join-Path $tmp $asset) }
        catch { Fail "could not download $url (offline? apm $ApmVersion is not in the cache yet): $($_.Exception.Message)" }

        $expected = $null
        if ($ApmVersion -eq $PinnedVersion) { $expected = $Props["apmSha256.$Platform"] }
        if (-not $expected) {
            Info "warning: no apmSha256.$Platform for $ApmVersion in apmw.properties, using the published checksum"
            try { Download "$url.sha256" (Join-Path $tmp "$asset.sha256") }
            catch { Fail "could not download $url.sha256: $($_.Exception.Message)" }
            $expected = ([IO.File]::ReadAllText((Join-Path $tmp "$asset.sha256")).Trim() -split '\s+')[0]
        }
        $expected = $expected.ToLowerInvariant()
        $actual = Get-Sha256 (Join-Path $tmp $asset)
        if ($actual -ne $expected) { Fail "checksum mismatch for $asset (expected $expected, got $actual)" }

        Expand-Archive -LiteralPath (Join-Path $tmp $asset) -DestinationPath $tmp -Force
        $staged = Join-Path $tmp "apm-$Platform"
        $stagedExe = Join-Path $staged 'apm.exe'
        if (-not (Test-Path -LiteralPath $stagedExe)) { Fail "$asset does not contain apm-$Platform\apm.exe" }

        $out = & $stagedExe --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine(($out | Out-String))
            Fail "the downloaded apm does not run on this system (blocked by antivirus or application control?)"
        }

        # The folder cannot be renamed while a virus scanner still holds the just-run
        # apm.exe open, so retry for a while.
        for ($try = 1; -not (Test-Path -LiteralPath $apmDir); $try++) {
            try { Move-Item -LiteralPath $staged -Destination $apmDir; break }
            catch {
                if (Test-Path -LiteralPath (Join-Path $apmDir 'apm.exe')) { break }
                if ($try -ge 30) { Fail "cannot move apm to ${apmDir}: $($_.Exception.Message)" }
                Start-Sleep -Seconds 1
            }
        }
        Info "installed apm $ApmVersion in $apmDir"
    } finally {
        Remove-Dir $tmp
    }
}

function Upgrade-Apm([string]$version) {
    if ($version) { $ver = Normalize-Version $version }
    else {
        $ver = Get-LatestTag $ApmReleasesUrl
        if (-not $ver) { Fail "cannot determine the latest apm release from $ApmReleasesUrl/latest; pass a version" }
    }
    $tmp = New-TempDir $ApmwHome
    try {
        Info "fetching checksums for apm $ver ..."
        $kv = [ordered]@{ apmVersion = $ver }
        foreach ($p in $AllPlatforms) {
            $asset = if ($p -like 'windows-*') { "apm-$p.zip" } else { "apm-$p.tar.gz" }
            $url = "$ApmReleasesUrl/download/$ver/$asset.sha256"
            try { Download $url (Join-Path $tmp 'sum') }
            catch { Fail "could not download $url (does apm $ver exist?)" }
            $h = ([IO.File]::ReadAllText((Join-Path $tmp 'sum')).Trim() -split '\s+')[0].ToLowerInvariant()
            if ($h -notmatch '^[0-9a-f]{64}$') { Fail "$url does not contain a sha256 checksum" }
            $kv["apmSha256.$p"] = $h
        }
    } finally {
        Remove-Dir $tmp
    }
    Set-Props $kv
    if ($ver -eq $PinnedVersion) { Info "apm $ver was already pinned; checksums refreshed" }
    else {
        $was = if ($PinnedVersion) { $PinnedVersion } else { 'none' }
        Info "pinned apm $ver (was: $was) in apm\wrapper\apmw.properties - review and commit it"
    }
}

# Download files of an apmw release, verify them against its apmw.sha256 and move them
# into the project. Throws on failure.
function Fetch-WrapperFiles([string]$ver, [string[]]$files) {
    $tmp = New-TempDir $AppHome
    try {
        foreach ($f in @('apmw.sha256') + $files) {
            try { Download "$WrapperReleasesUrl/download/$ver/$f" (Join-Path $tmp $f) }
            catch { throw "could not download $WrapperReleasesUrl/download/$ver/$f" }
        }
        $sums = @{}
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $tmp 'apmw.sha256'))) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ge 2) { $sums[$parts[1].TrimStart('*')] = $parts[0].ToLowerInvariant() }
        }
        foreach ($f in $files) {
            if ((Get-Sha256 (Join-Path $tmp $f)) -ne $sums[$f]) { throw "checksum mismatch for $f in apmw $ver" }
        }
        foreach ($f in $files) {
            Move-Item -LiteralPath (Join-Path $tmp $f) -Destination (Join-Path $AppHome $f) -Force
        }
    } finally {
        Remove-Dir $tmp
    }
}

# First run in a project: add the apmw shell script from the same apmw release,
# like "gradle wrapper" creates both scripts. Never fatal.
function Complete-Wrapper {
    $ver = $ApmwVersion
    if ($ver -eq 'dev') {
        $ver = Get-LatestTag $WrapperReleasesUrl
        if (-not $ver) { Info "warning: cannot determine the latest apmw release; run 'apmw --apmw-upgrade' later to add apmw"; return }
    }
    if (Test-Path -LiteralPath (Join-Path $AppHome 'apmw')) {
        Set-Props ([ordered]@{ wrapperVersion = $ver })
        return
    }
    try {
        Fetch-WrapperFiles $ver @('apmw')
        Set-Props ([ordered]@{ wrapperVersion = $ver })
        Info "added apmw ($ver) for Linux, macOS and Git Bash users - commit apmw, apmw.cmd and apm\wrapper\apmw.properties"
    } catch {
        Info "warning: could not add apmw ($($_.Exception.Message)); run 'apmw --apmw-upgrade' later"
    }
}

function Upgrade-Wrapper([string]$version) {
    if ($version) { $ver = Normalize-Version $version }
    else {
        $ver = Get-LatestTag $WrapperReleasesUrl
        if (-not $ver) { Fail "cannot determine the latest apmw release from $WrapperReleasesUrl/latest; pass a version" }
    }
    Info "downloading apmw $ver ..."
    try { Fetch-WrapperFiles $ver @('apmw', 'apmw.cmd') }
    catch { Fail "could not update apmw to ${ver}: $($_.Exception.Message)" }
    Set-Props ([ordered]@{ wrapperVersion = $ver })
    Info "updated apmw to $ver - review and commit apmw, apmw.cmd and apm\wrapper\apmw.properties"
    if (-not $PinnedVersion) { Upgrade-Apm '' }
}

function Show-Help {
    @'
Usage: apmw [apm arguments]   run the pinned apm version

Wrapper commands:
  apmw --apmw-help                  show this help
  apmw --apmw-version               show wrapper and apm versions
  apmw --apmw-upgrade-apm [VERSION] pin another apm version (default: latest)
  apmw --apmw-upgrade [VERSION]     update the apmw scripts (default: latest)

Environment overrides (take precedence over apm\wrapper\apmw.properties):
  APMW_HOME                  cache directory (default: %LOCALAPPDATA%\apmw)
  APMW_APM_VERSION           apm version to run
  APMW_APM_RELEASES_URL      where apm releases are downloaded from
  APMW_WRAPPER_RELEASES_URL  where apmw releases are downloaded from
'@
}

$Props = Read-Props
$ApmwHome = if ($env:APMW_HOME) { $env:APMW_HOME } else { Join-Path $env:LOCALAPPDATA 'apmw' }
$PinnedVersion = $Props['apmVersion']
$ApmVersion = if ($env:APMW_APM_VERSION) { $env:APMW_APM_VERSION } else { $PinnedVersion }
$ApmReleasesUrl = (Get-Setting 'APMW_APM_RELEASES_URL' 'apmReleasesUrl' $DefaultApmReleasesUrl).TrimEnd('/')
$WrapperReleasesUrl = (Get-Setting 'APMW_WRAPPER_RELEASES_URL' 'wrapperReleasesUrl' $DefaultWrapperReleasesUrl).TrimEnd('/')

try {
    switch ($env:APMW_ACTION) {
        '--apmw-ensure' { Install-Apm }
        '--apmw-help' { Show-Help }
        '--apmw-version' {
            $wv = if ($Props['wrapperVersion']) { $Props['wrapperVersion'] } else { 'unknown' }
            $av = if ($ApmVersion) { $ApmVersion } else { '<not configured>' }
            if ($env:APMW_APM_VERSION) { $av += ' (from APMW_APM_VERSION)' }
            "apmw $wv (this script: $ApmwVersion)"
            "apm  $av"
        }
        '--apmw-upgrade-apm' { Upgrade-Apm $env:APMW_ARG }
        '--apmw-upgrade' { Upgrade-Wrapper $env:APMW_ARG }
        default { Fail "unknown wrapper option: $($env:APMW_ACTION) (see apmw --apmw-help)" }
    }
} catch {
    Fail $_.Exception.Message
}
exit 0
