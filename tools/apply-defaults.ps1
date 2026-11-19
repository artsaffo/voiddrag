<#
.SYNOPSIS
    Make values you found in the VoidDrag lab the defaults for everyone.

.DESCRIPTION
    From the PC:
      1. In VoidDrag press L (or tune -> lab), change values, press "copy changes".
      2. Double-click tools\apply-defaults.cmd.

    From the phone (or anywhere):
      1. In the lab press "send to web" and submit the GitHub issue it opens.
         A GitHub Action in the site repository applies the values to the web
         build, comments with what changed and closes the issue.
      2. Later, on the PC, double-click tools\apply-defaults.cmd. It pulls the
         site repository first and brings those values into VoidDrag.html.

    Either way it finds each declaration in VoidDrag.html by name (not by line
    number, which moves as the file changes), shows what will change and asks
    before writing. It backs the old file up to archive\ first. Then it offers
    to publish the web build (site\ -> GitHub Pages) and to install on the
    phone (android\deploy.ps1), and keeps SHA256SUMS.txt and the README hash
    table in step.

    Lines it understands (exactly what the lab writes):
        var GUST_TOP = 2.1;   // was 1.45 (line 3382)
        FLY_EVERY[0] = 60;    // was 110 ...
        var TUNE_DEFAULTS = { brush: 1.20, trail: 2.0, ... };   // ...
    Lines starting with // are ignored. Anything else stops the script
    before it writes anything.

    The same script runs in the site repository's GitHub Action, with
    -File and -Target index.html.

.PARAMETER File
    Read the lines from this file instead of the clipboard.
.PARAMETER Target
    The HTML file to change. Default: VoidDrag.html in the project folder.
.PARAMETER Yes
    Do not ask. Writes the values; publishes or installs only with -Publish / -Phone.
.PARAMETER Publish
    Copy to site\index.html, commit and push (the public web build).
.PARAMETER Phone
    Build the APK and install it on the phone (android\deploy.ps1 -Launch).
.PARAMETER NoPull
    Do not look for values sent from the phone (skip pulling site\).
.PARAMETER Toolchain
    Folder with jdk\ and sdk\ for the phone build. Default: VOIDDRAG_TOOLCHAIN,
    else %USERPROFILE%\opal-android-toolchain if it exists.

.EXAMPLE
    .\apply-defaults.ps1
.EXAMPLE
    .\apply-defaults.ps1 -File changes.txt -Yes -Publish -Phone
#>
param(
    [string]$File,
    [string]$Target,
    [switch]$Yes,
    [switch]$Publish,
    [switch]$Phone,
    [switch]$NoPull,
    [string]$Toolchain = $env:VOIDDRAG_TOOLCHAIN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$projectHtml = Join-Path $root 'VoidDrag.html'
if (-not $Target) { $Target = $projectHtml }
$Target = (Resolve-Path $Target).Path
$isProject = (Test-Path $projectHtml) -and ($Target -eq (Resolve-Path $projectHtml).Path)
$site = Join-Path $root 'site'
$appliedLog = Join-Path $PSScriptRoot 'applied-defaults.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$labHeader = '// VoidDrag lab:'

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Stop-With([string]$text) { Say $text 'Red'; exit 1 }
function Ask([string]$question) {
    $a = Read-Host "$question [y/N]"
    return ($a -match '^\s*(y|yes)\s*$')
}
function Get-Sha([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower()
}

# --- Gather the lines: values sent from the phone, then the clipboard/file ----
$sources = New-Object System.Collections.ArrayList   # @{ Label; Text; Log }
$canPublish = $true

if ($isProject -and -not $NoPull -and (Test-Path (Join-Path $site '.git'))) {
    Say 'Checking GitHub for values sent from the lab ("send to web")...'
    git -C $site pull --ff-only -q
    if ($LASTEXITCODE -ne 0) {
        Say 'Could not update site\ from GitHub (offline, or it has diverged). Carrying on without it; publishing is off for this run.' 'Yellow'
        $canPublish = $false
    }
    $done = @{}
    if (Test-Path $appliedLog) { foreach ($l in [IO.File]::ReadAllLines($appliedLog, $utf8)) { if ($l.Trim()) { $done[$l.Trim()] = 1 } } }
    $inbox = Join-Path $site 'lab-defaults'
    if (Test-Path $inbox) {
        foreach ($f in (Get-ChildItem $inbox -Filter '*.txt' | Sort-Object Name)) {
            if ($done.ContainsKey($f.Name)) { continue }
            [void]$sources.Add(@{ Label = "sent to the web ($($f.BaseName))"; Text = [IO.File]::ReadAllText($f.FullName, $utf8); Log = $f.Name })
        }
    }
}

if ($File) {
    [void]$sources.Add(@{ Label = (Split-Path -Leaf $File); Text = [IO.File]::ReadAllText((Resolve-Path $File).Path, $utf8); Log = $null })
} elseif (Get-Command Get-Clipboard -ErrorAction SilentlyContinue) {
    $clip = Get-Clipboard -Raw
    if ($clip -and $clip.TrimStart().StartsWith($labHeader)) {
        [void]$sources.Add(@{ Label = 'the clipboard'; Text = $clip; Log = $null })
    } elseif ($sources.Count -eq 0) {
        Say 'No lab values on the clipboard and none sent to the web.' 'Yellow'
        Say 'In VoidDrag press L, change values, press "copy changes" (or "send to web"), then run this again.'
        exit 0
    }
}
if ($sources.Count -eq 0) { Say 'Nothing to apply.' 'Yellow'; exit 0 }

$html = [IO.File]::ReadAllText($Target, $utf8)
$num = '-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
$changes = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$currentSource = ''

# Find exactly one match of $pattern in $html, or stop.
function Find-One([string]$pattern, [string]$what) {
    $m = [regex]::Matches($script:html, $pattern, 'Multiline')
    if ($m.Count -eq 0) { Stop-With "Could not find $what in $(Split-Path -Leaf $Target). Nothing was written." }
    if ($m.Count -gt 1) { Stop-With "Found $what $($m.Count) times; expected once. Nothing was written." }
    return $m[0]
}

# Replace group 2 of a match (the value) with $new.
function Set-Group([System.Text.RegularExpressions.Match]$m, [string]$new) {
    $g = $m.Groups[2]
    $script:html = $script:html.Substring(0, $g.Index) + $new + $script:html.Substring($g.Index + $g.Length)
}

function Add-Change([string]$name, [string]$old, [string]$new) {
    if ($old -ne $new) { [void]$changes.Add([pscustomobject]@{ Name = $name; Was = $old; Now = $new; From = $script:currentSource }) }
}

function Add-Warning([string]$text) { if (-not $warnings.Contains($text)) { [void]$warnings.Add($text) } }

# Tune values also appear as the panel sliders' starting values in the HTML.
# The script sets them on load, but keep the markup honest too.
function Set-PanelValue([string]$key, [string]$value) {
    $plain = $value.Trim("'")
    $m = [regex]::Match($script:html, '(<input id="' + $key + '"[^>]*?\bvalue=")([^"]*)(")')
    if ($m.Success) { Set-Group $m $plain }
    $m = [regex]::Match($script:html, '(<output id="' + $key + 'Out">)([^<]*)(<)')
    if ($m.Success) { Set-Group $m $plain }
}

function Split-Pairs([string]$body) {
    $pairs = [ordered]@{}
    foreach ($part in ($body -split ',')) {
        if (-not $part.Trim()) { continue }
        $kv = $part -split ':', 2
        if ($kv.Count -ne 2) { Stop-With "Could not read '$part' in TUNE_DEFAULTS. Nothing was written." }
        $pairs[$kv[0].Trim()] = $kv[1].Trim()
    }
    return $pairs
}

function Apply-Line([string]$line) {
    $code = ($line -replace '\s*//.*$', '').Trim()

    if ($code -match '^var\s+TUNE_DEFAULTS\s*=\s*\{(.*)\}\s*;$') {
        $want = Split-Pairs $Matches[1]
        $m = Find-One '^([ \t]*var[ \t]+TUNE_DEFAULTS[ \t]*=[ \t]*\{)([^}\r\n]*)(\}[ \t]*;)' 'var TUNE_DEFAULTS'
        $have = Split-Pairs $m.Groups[2].Value
        foreach ($k in $want.Keys) {
            if (-not $have.Contains($k)) { Stop-With "TUNE_DEFAULTS has no key '$k'. Nothing was written." }
            $v = $want[$k]
            if ($v -notmatch "^$num$" -and $v -notmatch "^'#[0-9a-fA-F]{6}'$") { Stop-With "TUNE_DEFAULTS.$k = $v is not a number or a '#rrggbb' colour. Nothing was written." }
        }
        $new = New-Object System.Collections.ArrayList
        $set = New-Object System.Collections.ArrayList
        foreach ($k in $have.Keys) {
            $v = $have[$k]
            # 1.00 and 1.0 are the same default: keep the file's spelling.
            $same = ($want.Contains($k) -and $want[$k] -match "^$num$" -and $v -match "^$num$" -and [double]$want[$k] -eq [double]$v)
            if ($want.Contains($k) -and -not $same -and $want[$k] -ne $v) {
                Add-Change "tune $k" $v $want[$k]
                $v = $want[$k]
                [void]$set.Add($k)
            }
            [void]$new.Add("${k}: $v")
        }
        Set-Group $m (' ' + ($new -join ', ') + ' ')
        foreach ($k in $set) { Set-PanelValue $k $want[$k] }
        if ($set.Count) { Add-Warning 'Tune defaults reach new visitors and anyone who presses reset; people who already saved their own tune settings keep theirs.' }
    }
    elseif ($code -match "^var\s+([A-Z][A-Z0-9_]*)\s*=\s*($num)\s*;$") {
        $name = $Matches[1]; $value = $Matches[2]
        $m = Find-One ('^([ \t]*var[ \t]+' + $name + '[ \t]*=[ \t]*)(' + $num + ')([ \t]*;)') "var $name"
        Add-Change $name $m.Groups[2].Value $value
        Set-Group $m $value
        if ($name -eq 'MOON_R') { Add-Warning 'MOON_R: only the JS copy changes. The shader''s #define MOON_R still draws the disc at its old size; edit that line by hand to match.' }
    }
    elseif ($code -match "^([A-Z][A-Z0-9_]*)\[(\d+)\]\s*=\s*($num)\s*;$") {
        $name = $Matches[1]; $index = [int]$Matches[2]; $value = $Matches[3]
        $m = Find-One ('^([ \t]*var[ \t]+' + $name + '[ \t]*=[ \t]*\[)([^\]\r\n]*)(\])') "var $name = [...]"
        $items = @($m.Groups[2].Value -split ',' | ForEach-Object { $_.Trim() })
        if ($index -ge $items.Count) { Stop-With "$name has $($items.Count) items; there is no [$index]. Nothing was written." }
        Add-Change "$name[$index]" $items[$index] $value
        $items[$index] = $value
        Set-Group $m ($items -join ', ')
    }
    else {
        Stop-With "This line from $($script:currentSource) is not one the lab writes, so nothing was written:`n  $line"
    }
}

# Apply every source, in order, to the text in memory. Nothing touches the
# disk until every line has been understood.
foreach ($src in $sources) {
    $currentSource = $src.Label
    foreach ($raw in ($src.Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('//') -or $line.StartsWith('`')) { continue }
        Apply-Line $line
    }
}

$logNames = @($sources | Where-Object { $_.Log } | ForEach-Object { $_.Log })
function Write-Log {
    if ($logNames.Count -eq 0) { return }
    $existing = ''
    if (Test-Path $appliedLog) { $existing = [IO.File]::ReadAllText($appliedLog, $utf8) }
    [IO.File]::WriteAllText($appliedLog, $existing + (($logNames -join "`n") + "`n"), $utf8)
}

if ($changes.Count -eq 0) {
    Say 'Every value is already the default in the file. Nothing to do.' 'Yellow'
    Write-Log
    exit 0
}

# --- Show and confirm ---------------------------------------------------------
Say ''
Say "New defaults for $(Split-Path -Leaf $Target):" 'Cyan'
$changes | Format-Table -AutoSize | Out-String | Write-Host
foreach ($w in $warnings) { Say "note: $w" 'Yellow' }
if (-not $Yes -and -not (Ask 'Write these into the file?')) { Say 'Nothing was written.'; exit 0 }

# --- Write ------------------------------------------------------------------
$oldHtmlHash = Get-Sha $Target
$archive = Join-Path (Split-Path -Parent $Target) 'archive'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = [IO.Path]::GetFileNameWithoutExtension($Target)
if (Test-Path $archive) { $backup = Join-Path $archive "$base.$stamp.html" }
else { $backup = "$Target.$stamp.bak" }
Copy-Item $Target $backup
[IO.File]::WriteAllText($Target, $html, $utf8)
Write-Log
Say "Written. The previous file is at $backup" 'Green'

$names = ($changes | ForEach-Object { "$($_.Name) $($_.Now)" }) -join ', '

if (-not $isProject) {
    Say 'That was not the project''s VoidDrag.html, so nothing is published or installed.'
    exit 0
}

# --- Publish the web build ----------------------------------------------------
if ($canPublish -and -not $Publish -and -not $Yes) { $Publish = Ask 'Publish to the web build now (site\ -> GitHub Pages)?' }
if ($Publish -and -not $canPublish) { Say 'Not publishing: site\ could not be updated from GitHub first, and pushing now could overwrite values sent from the phone.' 'Yellow'; $Publish = $false }
if ($Publish) {
    Copy-Item $Target (Join-Path $site 'index.html') -Force
    $siteTools = Join-Path $site 'tools'
    if (-not (Test-Path $siteTools)) { New-Item -ItemType Directory $siteTools | Out-Null }
    Copy-Item $PSCommandPath (Join-Path $siteTools 'apply-defaults.ps1') -Force
    git -C $site add index.html tools/apply-defaults.ps1
    if ($LASTEXITCODE -ne 0) { Stop-With 'git add failed in site\.' }
    git -C $site diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Say 'The web build already has these values. Nothing to publish.' 'Green'
    } else {
        git -C $site commit -q -m "New defaults from the lab: $names"
        if ($LASTEXITCODE -ne 0) { Stop-With 'git commit failed in site\.' }
        git -C $site push -q origin main
        if ($LASTEXITCODE -ne 0) { Stop-With 'git push failed. The commit is in site\; push it by hand once the problem is fixed.' }
        Say 'Published. GitHub Pages usually updates within a minute.' 'Green'
    }
}

# --- Install on the phone -----------------------------------------------------
if (-not $Phone -and -not $Yes) { $Phone = Ask 'Build and install on the phone now?' }
if ($Phone) {
    if (-not $Toolchain) {
        $guess = Join-Path $env:USERPROFILE 'opal-android-toolchain'
        if (Test-Path $guess) { $Toolchain = $guess }
    }
    if ($Toolchain) { $env:VOIDDRAG_TOOLCHAIN = $Toolchain }
    $apk = Join-Path $root 'android\voiddrag-debug.apk'
    $oldApkHash = Get-Sha $apk
    & (Join-Path $root 'android\deploy.ps1') -Launch
    $newApkHash = Get-Sha $apk

    # The README's hash table describes the build on the phone, so it only
    # changes when there is a new one: HTML (also the APK's asset) and APK.
    $readme = Join-Path $root 'README.md'
    if ((Test-Path $readme) -and $oldApkHash -and $newApkHash -and $oldApkHash -ne $newApkHash) {
        $t = [IO.File]::ReadAllText($readme, $utf8)
        $t = $t.Replace($oldHtmlHash, (Get-Sha $Target)).Replace($oldApkHash, $newApkHash)
        [IO.File]::WriteAllText($readme, $t, $utf8)
        Say 'README hash table updated for the new phone build.' 'Green'
    }
}

# --- Keep SHA256SUMS.txt true to the files as they are now -----------------------
$sums = Join-Path $root 'SHA256SUMS.txt'
if (Test-Path $sums) {
    $out = foreach ($l in [IO.File]::ReadAllLines($sums, $utf8)) {
        if ($l -match '^([0-9a-f]{64})  (.+)$') {
            $h = Get-Sha (Join-Path $root $Matches[2])
            if ($h) { "$h  $($Matches[2])" } else { $l }
        } else { $l }
    }
    [IO.File]::WriteAllText($sums, (($out -join "`n") + "`n"), $utf8)
    Say 'SHA256SUMS.txt updated.' 'Green'
}
