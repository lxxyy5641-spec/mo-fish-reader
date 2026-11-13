[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [ValidateRange(20, 55)]
    [int]$ReaderPercent = 32,

    [ValidateRange(0, 100000)]
    [int]$Chapter = 0,

    [ValidateRange(0, 30)]
    [int]$ReaderLines = 0,

    [string]$StateFile,

    [string]$LibraryFile,

    [string]$SettingsFile,

    [string]$BookmarkFile,

    [string]$CacheFile,

    [string]$WorkRoot,

    [string]$WorkLog,

    [ValidateSet('Activity', 'Git', 'Process', 'Log', 'Codex')]
    [string]$WorkView = 'Codex',

    [Alias('CodexSession')]
    [string]$CodexSessionId = '',

    [ValidateSet('Auto', 'Dark', 'Light')]
    [string]$ColorMode = 'Auto',

    [ValidateSet('Auto', 'Compact', 'Paragraph', 'Relaxed')]
    [string]$SpacingMode = 'Auto',

    [Alias('TextWidth')]
    [ValidateSet(0, 72, 88, 104)]
    [int]$MaxTextWidth = 0,

    [switch]$Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Escape = [char]27
$script:Ansi = @{}
$script:ActiveColorMode = 'Dark'
$script:ActiveSpacingMode = 'Paragraph'
$script:ActiveTextWidth = 88

function Set-ReaderColorMode {
    param([Parameter(Mandatory)][ValidateSet('Dark', 'Light')][string]$Mode)

    $script:ActiveColorMode = $Mode
    if ($Mode -eq 'Light') {
        # Solarized Light semantic palette. Base03 is a near-black body color.
        $script:Ansi = @{
            Reset        = "$script:Escape[0m"
            Green        = "$script:Escape[38;2;92;124;0m"
            Gray         = "$script:Escape[38;2;0;43;54m"
            Dim          = "$script:Escape[38;2;88;110;117m"
            Cyan         = "$script:Escape[38;2;42;161;152m"
            Yellow       = "$script:Escape[38;2;181;137;0m"
            White        = "$script:Escape[38;2;7;54;66m"
            Blue         = "$script:Escape[38;2;38;139;210m"
            Command      = "$script:Escape[38;2;181;137;0m"
            Parameter    = "$script:Escape[38;2;38;139;210m"
            String       = "$script:Escape[38;2;211;54;130m"
            Path         = "$script:Escape[38;2;42;161;152m"
            Search       = "$script:Escape[38;2;0;43;54;48;2;238;232;213m"
            SearchActive = "$script:Escape[38;2;253;246;227;48;2;38;139;210m"
        }
        return
    }

    $script:Ansi = @{
        Reset        = "$script:Escape[0m"
        Green        = "$script:Escape[38;5;40m"
        Gray         = "$script:Escape[38;5;250m"
        Dim          = "$script:Escape[38;5;242m"
        Cyan         = "$script:Escape[38;5;45m"
        Yellow       = "$script:Escape[38;5;214m"
        White        = "$script:Escape[38;5;255m"
        Blue         = "$script:Escape[38;5;75m"
        Command      = "$script:Escape[38;5;220m"
        Parameter    = "$script:Escape[38;5;81m"
        String       = "$script:Escape[38;5;213m"
        Path         = "$script:Escape[38;5;117m"
        Search       = "$script:Escape[30;48;5;220m"
        SearchActive = "$script:Escape[30;48;5;45m"
    }
}
Set-ReaderColorMode -Mode Dark
$script:UnknownAuthor = -join ([char[]]@(0x672A, 0x77E5, 0x4F5C, 0x8005))

if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localData)) {
        $localData = $PSScriptRoot
    }
    $script:ProgressStatePath = Join-Path (Join-Path $localData 'FishReader') 'progress.json'
}
else {
    $script:ProgressStatePath = [IO.Path]::GetFullPath($StateFile)
}

if ([string]::IsNullOrWhiteSpace($LibraryFile)) {
    $libraryBase = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($libraryBase)) {
        $libraryBase = $PSScriptRoot
    }
    $script:LibraryStatePath = Join-Path (Join-Path $libraryBase 'FishReader') 'library.json'
}
else {
    $script:LibraryStatePath = [IO.Path]::GetFullPath($LibraryFile)
}

$script:ShelfRoot = Join-Path $PSScriptRoot 'shelf'
$script:ProgressEnabled = -not $Preview
$script:RequestedCodexSessionId = $CodexSessionId.Trim()
$script:CodexSessionId = ''

if ([string]::IsNullOrWhiteSpace($SettingsFile)) {
    $settingsBase = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($settingsBase)) {
        $settingsBase = $PSScriptRoot
    }
    $script:SettingsPath = Join-Path (Join-Path $settingsBase 'FishReader') 'settings.json'
}
else {
    $script:SettingsPath = [IO.Path]::GetFullPath($SettingsFile)
}

$initialColorMode = if ($ColorMode -in @('Dark', 'Light')) { $ColorMode } else { 'Dark' }
if ($ColorMode -eq 'Auto' -and (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
    try {
        $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedColorProperty = $savedSettings.PSObject.Properties['ColorMode']
        if ($null -ne $savedColorProperty -and [string]$savedColorProperty.Value -in @('Dark', 'Light')) {
            $initialColorMode = [string]$savedColorProperty.Value
        }
    }
    catch { }
}
Set-ReaderColorMode -Mode $initialColorMode

$initialSpacingMode = if ($SpacingMode -in @('Compact', 'Paragraph', 'Relaxed')) { $SpacingMode } else { 'Paragraph' }
if ($SpacingMode -eq 'Auto' -and (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
    try {
        $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedSpacingProperty = $savedSettings.PSObject.Properties['SpacingMode']
        if ($null -ne $savedSpacingProperty -and [string]$savedSpacingProperty.Value -in @('Compact', 'Paragraph', 'Relaxed')) {
            $initialSpacingMode = [string]$savedSpacingProperty.Value
        }
    }
    catch { }
}
$script:ActiveSpacingMode = $initialSpacingMode

$initialTextWidth = 88
if ($PSBoundParameters.ContainsKey('MaxTextWidth')) {
    $initialTextWidth = $MaxTextWidth
}
elseif (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
    try {
        $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedWidthProperty = $savedSettings.PSObject.Properties['TextWidth']
        if ($null -ne $savedWidthProperty) {
            $savedWidth = [int]$savedWidthProperty.Value
            if ($savedWidth -in @(0, 72, 88, 104)) { $initialTextWidth = $savedWidth }
        }
    }
    catch { }
}
$script:ActiveTextWidth = $initialTextWidth

if ([string]::IsNullOrWhiteSpace($BookmarkFile)) {
    $bookmarkBase = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($bookmarkBase)) { $bookmarkBase = $PSScriptRoot }
    $script:BookmarkStatePath = Join-Path (Join-Path $bookmarkBase 'FishReader') 'bookmarks.json'
}
else {
    $script:BookmarkStatePath = [IO.Path]::GetFullPath($BookmarkFile)
}

if ([string]::IsNullOrWhiteSpace($CacheFile)) {
    $cacheBase = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($cacheBase)) { $cacheBase = $PSScriptRoot }
    $script:CacheStatePath = Join-Path (Join-Path $cacheBase 'FishReader') 'cache.json'
}
else {
    $script:CacheStatePath = [IO.Path]::GetFullPath($CacheFile)
}
$script:LayoutCache = @{}
$script:LayoutCacheOrder = [System.Collections.Generic.List[string]]::new()

$script:CodexFeedState = [ordered]@{
    SessionId = ''
    Path      = $null
    Offset    = [long]0
    Pending   = ''
    Messages  = [System.Collections.Generic.List[object]]::new()
    Error     = $null
    UpdatedAt = $null
}

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = $PSScriptRoot
}

try {
    $script:WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path
}
catch {
    $script:WorkRoot = $PSScriptRoot
}

if (-not [string]::IsNullOrWhiteSpace($WorkLog)) {
    try {
        $script:WorkLog = (Resolve-Path -LiteralPath $WorkLog).Path
    }
    catch {
        $script:WorkLog = $null
    }
}
else {
    $script:WorkLog = $null
}

if (-not ('FishReader.TextWrapper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

namespace FishReader
{
    public static class TextWrapper
    {
        public static string[] Wrap(string text, int width)
        {
            var result = new List<string>();
            var line = new StringBuilder();
            var lineWidth = 0;

            for (var index = 0; index < text.Length; index++)
            {
                var character = text[index];
                if (character == '\r')
                    continue;

                if (character == '\n')
                {
                    result.Add(line.ToString());
                    line.Clear();
                    lineWidth = 0;
                    continue;
                }

                if (character == '\t')
                    character = ' ';

                var characterWidth = CellWidth(character);
                if (lineWidth + characterWidth > width && line.Length > 0)
                {
                    result.Add(line.ToString());
                    line.Clear();
                    lineWidth = 0;
                }

                line.Append(character);
                lineWidth += characterWidth;
            }

            if (line.Length > 0 || text.EndsWith("\n", StringComparison.Ordinal))
                result.Add(line.ToString());

            return result.ToArray();
        }

        private static int CellWidth(char character)
        {
            var code = (int)character;
            return
                (code >= 0x1100 && code <= 0x115F) ||
                (code >= 0x2E80 && code <= 0xA4CF) ||
                (code >= 0xAC00 && code <= 0xD7A3) ||
                (code >= 0xF900 && code <= 0xFAFF) ||
                (code >= 0xFE10 && code <= 0xFE6F) ||
                (code >= 0xFF00 && code <= 0xFF60) ||
                (code >= 0xFFE0 && code <= 0xFFE6)
                    ? 2
                    : 1;
        }
    }
}
'@
}

function Get-SafeConsoleSize {
    $width = 120
    $height = 36

    try {
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
    }
    catch {
        # Redirected hosts may not expose a console window.
    }

    [pscustomobject]@{
        Width  = [Math]::Max(40, $width)
        Height = [Math]::Max(24, $height)
    }
}

function Get-CharacterWidth {
    param([char]$Character)

    $code = [int]$Character
    if (
        ($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)
    ) {
        return 2
    }

    return 1
}

function Get-TextCellWidth {
    param([AllowEmptyString()][string]$Text)

    $width = 0
    foreach ($character in $Text.ToCharArray()) {
        $width += Get-CharacterWidth -Character $character
    }
    return $width
}

function Format-FixedCellText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    $builder = [Text.StringBuilder]::new()
    $used = 0
    $clipped = $false
    foreach ($character in $Text.ToCharArray()) {
        $characterWidth = Get-CharacterWidth -Character $character
        if ($used + $characterWidth -gt $Width) {
            $clipped = $true
            break
        }
        [void]$builder.Append($character)
        $used += $characterWidth
    }
    if ($clipped -and $Width -ge 1) {
        while ($builder.Length -gt 0 -and $used -ge $Width) {
            $last = $builder[$builder.Length - 1]
            $used -= Get-CharacterWidth -Character $last
            $builder.Length--
        }
        [void]$builder.Append([char]0x2026)
        $used++
    }
    if ($used -lt $Width) { [void]$builder.Append(' ' * ($Width - $used)) }
    return $builder.ToString()
}

function Get-ReaderShortcutRows {
    param([Parameter(Mandatory)][int]$Width)

    $items = @(
        @{ Key = 'Space/PgDn/Down/Right'; Label = 'next' },
        @{ Key = 'B/PgUp/Up/Left'; Label = 'prev' },
        @{ Key = 'C'; Label = 'contents' },
        @{ Key = '[/]'; Label = 'chapter' },
        @{ Key = '/'; Label = 'find' },
        @{ Key = 'N/P'; Label = 'hit' },
        @{ Key = 'K'; Label = 'marks' },
        @{ Key = 'S'; Label = 'session' },
        @{ Key = 'W'; Label = 'view' },
        @{ Key = 'R'; Label = 'refresh' },
        @{ Key = 'T'; Label = 'theme' },
        @{ Key = 'I'; Label = 'spacing' },
        @{ Key = 'Z'; Label = 'width' },
        @{ Key = '+/-'; Label = 'lines' },
        @{ Key = 'Home/End'; Label = 'book' },
        @{ Key = 'L'; Label = 'shelf' },
        @{ Key = 'O'; Label = 'open' },
        @{ Key = 'Esc'; Label = 'hide' },
        @{ Key = 'Q'; Label = 'quit' }
    )

    $availableWidth = [Math]::Max(24, $Width - 2)
    $rows = [System.Collections.Generic.List[string]]::new()
    $styled = [Text.StringBuilder]::new()
    $currentWidth = 0

    foreach ($item in $items) {
        $plainItem = "$($item.Key) $($item.Label)"
        $itemWidth = Get-TextCellWidth -Text $plainItem
        $separatorWidth = if ($currentWidth -gt 0) { 3 } else { 0 }

        if ($currentWidth -gt 0 -and ($currentWidth + $separatorWidth + $itemWidth) -gt $availableWidth) {
            $rows.Add($styled.ToString())
            [void]$styled.Clear()
            $currentWidth = 0
            $separatorWidth = 0
        }

        if ($separatorWidth -gt 0) {
            [void]$styled.Append("$($script:Ansi.Dim) | $($script:Ansi.Reset)")
            $currentWidth += $separatorWidth
        }
        [void]$styled.Append($script:Ansi.Command)
        [void]$styled.Append([string]$item.Key)
        [void]$styled.Append($script:Ansi.Reset)
        [void]$styled.Append(' ')
        [void]$styled.Append($script:Ansi.Dim)
        [void]$styled.Append([string]$item.Label)
        [void]$styled.Append($script:Ansi.Reset)
        $currentWidth += $itemWidth
    }

    if ($styled.Length -gt 0) {
        $rows.Add($styled.ToString())
    }
    return $rows.ToArray()
}

function ConvertTo-WrappedLines {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    return [FishReader.TextWrapper]::Wrap($Text, $Width)
}

function Test-ReaderParagraphStart {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return $Text.StartsWith(([string][char]0x3000)) -or $Text.StartsWith('  ')
}

function New-ReaderDisplayLayout {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][ValidateSet('Compact', 'Paragraph', 'Relaxed')][string]$Mode
    )

    $rows = [System.Collections.Generic.List[int]]::new()
    $lineRows = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $WrappedLines.Count; $index++) {
        $lineRows.Add($rows.Count)
        $rows.Add($index)

        if ($index -ge $WrappedLines.Count - 1) { continue }
        $current = [string]$WrappedLines[$index]
        $next = [string]$WrappedLines[$index + 1]
        if ([string]::IsNullOrWhiteSpace($current) -or [string]::IsNullOrWhiteSpace($next)) { continue }

        $addGap = $Mode -eq 'Relaxed' -or ($Mode -eq 'Paragraph' -and (Test-ReaderParagraphStart -Text $next))
        if ($addGap) { $rows.Add(-1) }
    }

    return [pscustomobject]@{
        Rows     = $rows.ToArray()
        LineRows = $lineRows.ToArray()
    }
}

function Get-DisplayPageForSourceLine {
    param(
        [Parameter(Mandatory)][int[]]$LineRows,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][int]$PageSize
    )

    if ($LineRows.Count -eq 0) { return 0 }
    $safeLineIndex = [Math]::Max(0, [Math]::Min($LineRows.Count - 1, $LineIndex))
    return [Math]::Floor($LineRows[$safeLineIndex] / [double][Math]::Max(1, $PageSize))
}

function Get-PageSourceLine {
    param(
        [Parameter(Mandatory)][int[]]$DisplayRows,
        [Parameter(Mandatory)][int]$Page,
        [Parameter(Mandatory)][int]$PageSize,
        [switch]$AtEnd
    )

    if ($DisplayRows.Count -eq 0) { return 0 }
    $start = [Math]::Min($DisplayRows.Count - 1, [Math]::Max(0, $Page * $PageSize))
    $end = [Math]::Min($DisplayRows.Count - 1, $start + [Math]::Max(1, $PageSize) - 1)
    if ($AtEnd) {
        for ($row = $end; $row -ge $start; $row--) {
            if ($DisplayRows[$row] -ge 0) { return $DisplayRows[$row] }
        }
    }
    else {
        for ($row = $start; $row -le $end; $row++) {
            if ($DisplayRows[$row] -ge 0) { return $DisplayRows[$row] }
        }
    }
    return 0
}

function Get-LibraryEntryValue {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-BookIdentity {
    param([Parameter(Mandatory)][string]$BookPath)

    $resolved = [IO.Path]::GetFullPath($BookPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($resolved).Trim()
    $title = $baseName
    $author = ''

    $authorMatch = [regex]::Match($baseName, '(?:\u4F5C\s*\u8005)\s*[:\uFF1A]\s*(?<author>.+?)\s*$')
    if ($authorMatch.Success) {
        $authorTrimCharacters = [char[]]@(32, 45, 95, 40, 41, 0x2013, 0x2014, 0xFF08, 0xFF09)
        $titleTrimCharacters = [char[]]@(32, 45, 95, 0x2013, 0x2014)
        $author = $authorMatch.Groups['author'].Value.Trim($authorTrimCharacters)
        $title = $baseName.Substring(0, $authorMatch.Index).Trim($titleTrimCharacters)
    }

    if ([string]::IsNullOrWhiteSpace($author)) {
        $parentDirectory = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($resolved))
        while ($null -ne $parentDirectory) {
            if ($parentDirectory.Name -match '^\s*\d{3}\s*(?:-|\u2013|\u2014)\s*(?<author>.+?)\s*$') {
                $author = $Matches['author'].Trim()
                break
            }
            $parentDirectory = $parentDirectory.Parent
        }
    }

    $shelfPrefix = [IO.Path]::GetFullPath($script:ShelfRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ([string]::IsNullOrWhiteSpace($author) -and $resolved.StartsWith($shelfPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $resolved.Substring($shelfPrefix.Length)
        $parts = @($relative -split '[\\/]')
        if ($parts.Count -gt 1) {
            $author = $parts[0].Trim()
        }
    }

    $title = ($title -replace '^\s*\[[^\]]+\]\s*', '').Trim()
    if ($title.StartsWith([string][char]0x300A)) {
        $title = $title.Substring(1)
        $closingMark = $title.IndexOf([char]0x300B)
        if ($closingMark -ge 0) {
            $title = $title.Remove($closingMark, 1)
        }
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $baseName
    }
    if ([string]::IsNullOrWhiteSpace($author)) {
        $author = $script:UnknownAuthor
    }

    [pscustomobject]@{
        Title  = $title
        Author = $author
    }
}

function Get-LibraryEntries {
    if (-not (Test-Path -LiteralPath $script:LibraryStatePath)) {
        return @()
    }

    try {
        $state = Get-Content -LiteralPath $script:LibraryStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($state.Entries)
    }
    catch {
        return @()
    }
}

function Save-LibraryEntries {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)

    try {
        $directory = Split-Path -Parent $script:LibraryStatePath
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }

        $payload = [pscustomobject]@{
            Version = 2
            Entries = @($Entries)
        }
        $json = $payload | ConvertTo-Json -Depth 5
        $temporaryPath = "$($script:LibraryStatePath).tmp"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:LibraryStatePath -Force
    }
    catch {
        # The reader still works when the optional library cannot be written.
    }
}

function Update-LibraryEntry {
    param(
        [Parameter(Mandatory)]$Book,
        [double]$Progress = -1,
        [int]$LineCount = -1,
        [switch]$Touch
    )

    if (-not $script:ProgressEnabled) {
        return
    }

    $entries = @(Get-LibraryEntries)
    $existing = $null
    $remaining = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $entries) {
        if ([string]::Equals([string]$entry.Path, [string]$Book.Path, [StringComparison]::OrdinalIgnoreCase)) {
            $existing = $entry
        }
        else {
            $remaining.Add($entry)
        }
    }

    $hasProgress = $null -ne $existing -and $null -ne $existing.PSObject.Properties['Progress']
    $hasReaderLines = $null -ne $existing -and $null -ne $existing.PSObject.Properties['ReaderLines']
    $hasLastOpened = $null -ne $existing -and $null -ne $existing.PSObject.Properties['LastOpened']
    $hasAuthor = $null -ne $existing -and $null -ne $existing.PSObject.Properties['Author'] -and -not [string]::IsNullOrWhiteSpace([string]$existing.Author)
    $savedProgress = if ($Progress -ge 0) { $Progress } elseif ($hasProgress) { [double]$existing.Progress } else { 0.0 }
    $savedLines = if ($LineCount -gt 0) { $LineCount } elseif ($hasReaderLines) { [int]$existing.ReaderLines } else { 8 }
    $lastOpened = if ($Touch -or -not $hasLastOpened) { [DateTime]::UtcNow.ToString('o') } else { [string]$existing.LastOpened }
    $identity = Get-BookIdentity -BookPath $Book.Path
    $savedAuthor = if ($identity.Author -ne $script:UnknownAuthor -or -not $hasAuthor) { $identity.Author } else { [string]$existing.Author }

    $remaining.Add([pscustomobject]@{
        Path        = $Book.Path
        Title       = $identity.Title
        Author      = $savedAuthor
        Length      = $Book.Length
        Modified    = $Book.Modified
        Progress    = $savedProgress
        ReaderLines = $savedLines
        LastOpened  = $lastOpened
        Favorite    = if ($null -ne $existing) { [bool](Get-LibraryEntryValue -Entry $existing -Name 'Favorite' -DefaultValue $false) } else { $false }
        Status      = if ($null -ne $existing) { [string](Get-LibraryEntryValue -Entry $existing -Name 'Status' -DefaultValue 'Auto') } else { 'Auto' }
    })

    Save-LibraryEntries -Entries $remaining.ToArray()
}

function Sync-LibraryFiles {
    param([Parameter(Mandatory)][AllowEmptyCollection()][IO.FileInfo[]]$Files)

    if (-not $script:ProgressEnabled) {
        return
    }

    $entries = @(Get-LibraryEntries)
    $entryByPath = @{}
    foreach ($entry in $entries) {
        $entryPath = [string](Get-LibraryEntryValue -Entry $entry -Name 'Path' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($entryPath)) {
            $entryByPath[$entryPath] = $entry
        }
    }

    foreach ($file in $Files) {
        $entryByPath[$file.FullName] = if ($entryByPath.ContainsKey($file.FullName)) { $entryByPath[$file.FullName] } else { $null }
    }

    $normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($entryByPath.Keys)) {
        $existing = $entryByPath[$path]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $file -or $file.Extension -notin @('.txt', '.log', '.md')) {
            continue
        }

        $identity = Get-BookIdentity -BookPath $file.FullName
        $existingAuthor = if ($null -ne $existing) { [string](Get-LibraryEntryValue -Entry $existing -Name 'Author' -DefaultValue '') } else { '' }
        $author = if ($identity.Author -ne $script:UnknownAuthor -or [string]::IsNullOrWhiteSpace($existingAuthor)) { $identity.Author } else { $existingAuthor }

        $normalized.Add([pscustomobject]@{
            Path        = $file.FullName
            Title       = $identity.Title
            Author      = $author
            Length      = $file.Length
            Modified    = $file.LastWriteTimeUtc.ToString('o')
            Progress    = if ($null -ne $existing) { [double](Get-LibraryEntryValue -Entry $existing -Name 'Progress' -DefaultValue 0.0) } else { 0.0 }
            ReaderLines = if ($null -ne $existing) { [int](Get-LibraryEntryValue -Entry $existing -Name 'ReaderLines' -DefaultValue 8) } else { 8 }
            LastOpened  = if ($null -ne $existing) { [string](Get-LibraryEntryValue -Entry $existing -Name 'LastOpened' -DefaultValue '') } else { '' }
            Favorite    = if ($null -ne $existing) { [bool](Get-LibraryEntryValue -Entry $existing -Name 'Favorite' -DefaultValue $false) } else { $false }
            Status      = if ($null -ne $existing) { [string](Get-LibraryEntryValue -Entry $existing -Name 'Status' -DefaultValue 'Auto') } else { 'Auto' }
        })
    }

    Save-LibraryEntries -Entries $normalized.ToArray()
}

function Sync-ShelfLibrary {
    if (-not (Test-Path -LiteralPath $script:ShelfRoot -PathType Container)) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $script:ShelfRoot -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue)
    Sync-LibraryFiles -Files $files
}

function Remove-LibraryEntry {
    param([Parameter(Mandatory)][string]$BookPath)

    $remaining = @(Get-LibraryEntries | Where-Object {
        -not [string]::Equals([string]$_.Path, $BookPath, [StringComparison]::OrdinalIgnoreCase)
    })
    Save-LibraryEntries -Entries $remaining
}

function Get-LibraryBookStatus {
    param([Parameter(Mandatory)]$Entry)
    $override = [string](Get-LibraryEntryValue -Entry $Entry -Name 'Status' -DefaultValue 'Auto')
    if ($override -eq 'Unread') { return 'UNREAD' }
    if ($override -eq 'Finished') { return 'FINISHED' }
    $progress = [double](Get-LibraryEntryValue -Entry $Entry -Name 'Progress' -DefaultValue 0.0)
    if ($progress -le 0.0001) { return 'UNREAD' }
    if ($progress -ge 0.995) { return 'FINISHED' }
    return 'READING'
}

function Update-LibraryBookFlags {
    param(
        [Parameter(Mandatory)][string]$BookPath,
        [switch]$ToggleFavorite,
        [switch]$CycleStatus
    )
    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-LibraryEntries)) {
        $favorite = [bool](Get-LibraryEntryValue -Entry $entry -Name 'Favorite' -DefaultValue $false)
        $status = [string](Get-LibraryEntryValue -Entry $entry -Name 'Status' -DefaultValue 'Auto')
        if ([string]::Equals([string]$entry.Path, $BookPath, [StringComparison]::OrdinalIgnoreCase)) {
            if ($ToggleFavorite) { $favorite = -not $favorite }
            if ($CycleStatus) {
                $status = switch ($status) { 'Auto' { 'Unread' }; 'Unread' { 'Finished' }; default { 'Auto' } }
            }
        }
        $updated.Add([pscustomobject]@{
            Path=$entry.Path; Title=$entry.Title; Author=$entry.Author; Length=$entry.Length; Modified=$entry.Modified
            Progress=[double](Get-LibraryEntryValue -Entry $entry -Name 'Progress' -DefaultValue 0.0)
            ReaderLines=[int](Get-LibraryEntryValue -Entry $entry -Name 'ReaderLines' -DefaultValue 8)
            LastOpened=[string](Get-LibraryEntryValue -Entry $entry -Name 'LastOpened' -DefaultValue '')
            Favorite=$favorite; Status=$status
        })
    }
    Save-LibraryEntries -Entries $updated.ToArray()
}

function Read-LibraryKey {
    if ([Console]::IsInputRedirected) {
        $line = [Console]::ReadLine()
        if ($null -eq $line) {
            return [pscustomobject]@{ Key = [ConsoleKey]::Q; KeyChar = [char]'q'; Text = 'q' }
        }

        $text = $line.Trim()
        $mappedKey = switch ($text.ToUpperInvariant()) {
            ''       { [ConsoleKey]::Enter }
            'UP'     { [ConsoleKey]::UpArrow }
            'DOWN'   { [ConsoleKey]::DownArrow }
            'LEFT'   { [ConsoleKey]::LeftArrow }
            'RIGHT'  { [ConsoleKey]::RightArrow }
            'ENTER'  { [ConsoleKey]::Enter }
            'PGUP'   { [ConsoleKey]::PageUp }
            'PGDN'   { [ConsoleKey]::PageDown }
            'ESC'    { [ConsoleKey]::Escape }
            default  { [ConsoleKey]::NoName }
        }
        $character = if ($text.Length -gt 0) { [char]$text[0] } else { [char]0 }
        return [pscustomobject]@{ Key = $mappedKey; KeyChar = $character; Text = $text }
    }

    $key = [Console]::ReadKey($true)
    return [pscustomobject]@{ Key = $key.Key; KeyChar = $key.KeyChar; Text = [string]$key.KeyChar }
}

function Select-BookFromLibrary {
    Sync-ShelfLibrary

    $filter = ''
    $mode = 'Books'
    $selectedAuthor = ''
    $page = 0
    $pageSize = 20
    $cursor = 0
    $categories = @('ALL', 'RECENT', 'READING', 'FAVORITES', 'UNREAD', 'FINISHED')
    $categoryIndex = 0

    while ($true) {
        $librarySize = Get-SafeConsoleSize
        $pageSize = [Math]::Max(5, $librarySize.Height - 9)
        [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25l")
        $allEntries = @(Get-LibraryEntries | Sort-Object -Property LastOpened -Descending)
        $category = $categories[$categoryIndex]
        $allEntries = @(switch ($category) {
            'RECENT'    { $allEntries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.LastOpened) } | Select-Object -First 20 }
            'READING'   { $allEntries | Where-Object { (Get-LibraryBookStatus -Entry $_) -eq 'READING' } }
            'FAVORITES' { $allEntries | Where-Object { [bool](Get-LibraryEntryValue -Entry $_ -Name 'Favorite' -DefaultValue $false) } }
            'UNREAD'    { $allEntries | Where-Object { (Get-LibraryBookStatus -Entry $_) -eq 'UNREAD' } }
            'FINISHED'  { $allEntries | Where-Object { (Get-LibraryBookStatus -Entry $_) -eq 'FINISHED' } }
            default     { $allEntries }
        })
        $entries = $allEntries
        $authors = @()

        if ($mode -eq 'Authors') {
            $authors = @($allEntries | Group-Object -Property Author | Sort-Object -Property Name)
            if (-not [string]::IsNullOrWhiteSpace($filter)) {
                $authors = @($authors | Where-Object { $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            }
        }
        else {
            if ($mode -eq 'AuthorBooks') {
                $entries = @($entries | Where-Object { [string]::Equals([string]$_.Author, $selectedAuthor, [StringComparison]::OrdinalIgnoreCase) })
            }
            if (-not [string]::IsNullOrWhiteSpace($filter)) {
                $entries = @($entries | Where-Object {
                    ([string]$_.Title).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$_.Author).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
                })
            }
        }

        $viewLabel = switch ($mode) {
            'Authors' { 'AUTHORS' }
            'AuthorBooks' { "AUTHOR: $selectedAuthor" }
            default { "BOOKS: $category" }
        }
        $items = @(if ($mode -eq 'Authors') { $authors } else { $entries })
        $pageCount = [Math]::Max(1, [Math]::Ceiling($items.Count / [double]$pageSize))
        if ($items.Count -gt 0) {
            $cursor = [Math]::Max(0, [Math]::Min($cursor, $items.Count - 1))
            $page = [Math]::Floor($cursor / [double]$pageSize)
        }
        else {
            $cursor = 0
            $page = 0
        }
        $startIndex = $page * $pageSize
        $endIndex = [Math]::Min($items.Count, $startIndex + $pageSize)

        [Console]::WriteLine("$($script:Ansi.Cyan)FISH READER LIBRARY  [$viewLabel]$($script:Ansi.Reset)")
        [Console]::WriteLine(("  Page {0}/{1}  {2} item(s)  [N unread | R reading | D done | * favorite]" -f ($page + 1), $pageCount, $items.Count))
        [Console]::WriteLine('')

        if ($items.Count -eq 0) {
            if ([string]::IsNullOrWhiteSpace($filter)) {
                [Console]::WriteLine('  Nothing to show. Put TXT files in the shelf folder or press A to add.')
            }
            else {
                [Console]::WriteLine("  No match: $filter")
            }
        }
        elseif ($mode -eq 'Authors') {
            for ($index = $startIndex; $index -lt $endIndex; $index++) {
                $authorGroup = $authors[$index]
                $authorName = [string]$authorGroup.Name
                $marker = if ($index -eq $cursor) { '>' } else { ' ' }
                $authorWidth = [Math]::Max(12, $librarySize.Width - 25)
                $authorText = Format-FixedCellText -Text $authorName -Width $authorWidth
                $line = ('{0} {1,3}  {2} {3,4} book(s)' -f $marker, ($index + 1), $authorText, $authorGroup.Count)
                if ($index -eq $cursor) {
                    [Console]::WriteLine("$($script:Ansi.Cyan)$line$($script:Ansi.Reset)")
                }
                else {
                    [Console]::WriteLine($line)
                }
            }
        }
        else {
            for ($index = $startIndex; $index -lt $endIndex; $index++) {
                $entry = $entries[$index]
                $marker = if ($index -eq $cursor) { '>' } else { ' ' }
                $favoriteMark = if ([bool](Get-LibraryEntryValue -Entry $entry -Name 'Favorite' -DefaultValue $false)) { '*' } else { ' ' }
                $statusMark = switch (Get-LibraryBookStatus -Entry $entry) { 'READING' { 'R' }; 'FINISHED' { 'D' }; default { 'N' } }
                $percent = [Math]::Round([double]$entry.Progress * 100, 1)
                $title = [string]$entry.Title
                $author = [string]$entry.Author
                $prefix = ('{0}{1} {2,3}  ' -f $marker, $favoriteMark, ($index + 1))
                $suffix = (' {0,6:N1}% {1}' -f $percent, $statusMark)
                $available = [Math]::Max(8, $librarySize.Width - (Get-TextCellWidth -Text $prefix) - (Get-TextCellWidth -Text $suffix) - 1)
                if ($librarySize.Width -ge 72) {
                    $authorWidth = [Math]::Max(14, [Math]::Floor($available * 0.34))
                    $titleWidth = [Math]::Max(10, $available - $authorWidth - 1)
                    $titleText = Format-FixedCellText -Text $title -Width $titleWidth
                    $authorText = Format-FixedCellText -Text $author -Width $authorWidth
                    $line = "$prefix$titleText $authorText$suffix"
                }
                else {
                    $titleText = Format-FixedCellText -Text $title -Width $available
                    $line = "$prefix$titleText$suffix"
                }
                if ($index -eq $cursor) {
                    [Console]::WriteLine("$($script:Ansi.Cyan)$line$($script:Ansi.Reset)")
                }
                else {
                    [Console]::WriteLine($line)
                }
            }
        }

        [Console]::WriteLine('')
        if ($mode -eq 'AuthorBooks') {
            [Console]::WriteLine('Up/Down select | Enter open | B back | V category | F favorite | X status')
        }
        else {
            [Console]::WriteLine('Up/Down select | Enter open | M mode | V category | F favorite | X status')
        }
        [Console]::WriteLine('/ search | A add | D remove from index | Q quit')
        $key = Read-LibraryKey
        $keyCharacter = ([string]$key.KeyChar).ToUpperInvariant()
        $activateSelection = $false

        if ($key.Key -eq [ConsoleKey]::Q -or $keyCharacter -eq 'Q') {
            [Console]::Write("$script:Escape[?25h")
            return $null
        }

        if ($keyCharacter -eq 'A') {
            [Console]::Write("$script:Escape[?25h")
            [Console]::Write('TXT file or folder path: ')
            $candidateInput = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            if ($null -eq $candidateInput) {
                continue
            }
            $candidate = $candidateInput.Trim('"')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $resolvedCandidate = (Resolve-Path -LiteralPath $candidate).Path
                $candidateFile = Get-Item -LiteralPath $resolvedCandidate
                if ($candidateFile.Extension -eq '.txt') {
                    Sync-LibraryFiles -Files @($candidateFile)
                    return $resolvedCandidate
                }
            }
            elseif (Test-Path -LiteralPath $candidate -PathType Container) {
                $candidateFiles = @(Get-ChildItem -LiteralPath $candidate -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue)
                Sync-LibraryFiles -Files $candidateFiles
                $filter = ''
                $page = 0
                $cursor = 0
                continue
            }
            [Console]::WriteLine("$($script:Ansi.Yellow)TXT file or folder not found.$($script:Ansi.Reset)")
            Start-Sleep -Milliseconds 900
            continue
        }

        if ($keyCharacter -eq 'M') {
            $mode = if ($mode -eq 'Books') { 'Authors' } else { 'Books' }
            $selectedAuthor = ''
            $filter = ''
            $page = 0
            $cursor = 0
            continue
        }

        if ($keyCharacter -eq 'V') {
            $categoryIndex = ($categoryIndex + 1) % $categories.Count
            $selectedAuthor = ''
            if ($mode -eq 'AuthorBooks') { $mode = 'Books' }
            $filter = ''
            $page = 0
            $cursor = 0
            continue
        }

        if ($keyCharacter -in @('F', 'X') -and $mode -ne 'Authors' -and $items.Count -gt 0) {
            $selectedEntry = $entries[$cursor]
            if ($keyCharacter -eq 'F') {
                Update-LibraryBookFlags -BookPath ([string]$selectedEntry.Path) -ToggleFavorite
            }
            else {
                Update-LibraryBookFlags -BookPath ([string]$selectedEntry.Path) -CycleStatus
            }
            continue
        }

        if ($keyCharacter -eq 'B' -and $mode -eq 'AuthorBooks') {
            $mode = 'Authors'
            $selectedAuthor = ''
            $filter = ''
            $page = 0
            $cursor = 0
            continue
        }

        if ($keyCharacter -eq 'N' -or $key.Key -in @([ConsoleKey]::PageDown, [ConsoleKey]::RightArrow)) {
            if ($items.Count -gt 0) {
                $cursor = [Math]::Min($items.Count - 1, $cursor + $pageSize)
            }
            continue
        }

        if ($keyCharacter -eq 'P' -or $key.Key -in @([ConsoleKey]::PageUp, [ConsoleKey]::LeftArrow)) {
            if ($items.Count -gt 0) {
                $cursor = [Math]::Max(0, $cursor - $pageSize)
            }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            if ($items.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - 1) }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::DownArrow) {
            if ($items.Count -gt 0) { $cursor = [Math]::Min($items.Count - 1, $cursor + 1) }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::Home) {
            $cursor = 0
            continue
        }

        if ($key.Key -eq [ConsoleKey]::End) {
            if ($items.Count -gt 0) { $cursor = $items.Count - 1 }
            continue
        }

        if ($keyCharacter -eq '/') {
            [Console]::Write("$script:Escape[?25h")
            [Console]::Write('search> ')
            $searchInput = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            if ($null -ne $searchInput) { $filter = $searchInput.Trim() }
            $page = 0
            $cursor = 0
            continue
        }

        if ($key.Key -eq [ConsoleKey]::Escape) {
            if (-not [string]::IsNullOrWhiteSpace($filter)) {
                $filter = ''
            }
            elseif ($mode -eq 'AuthorBooks') {
                $mode = 'Authors'
                $selectedAuthor = ''
            }
            $cursor = 0
            continue
        }

        if ($keyCharacter -eq 'D' -and $mode -ne 'Authors' -and $items.Count -gt 0) {
            $entryToRemove = $entries[$cursor]
            [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25l")
            [Console]::WriteLine("$($script:Ansi.Yellow)REMOVE FROM LIBRARY INDEX?$($script:Ansi.Reset)")
            [Console]::WriteLine('')
            [Console]::WriteLine("  Title : $($entryToRemove.Title)")
            [Console]::WriteLine("  Author: $($entryToRemove.Author)")
            [Console]::WriteLine('')
            [Console]::WriteLine('  The TXT file will NOT be deleted.')
            [Console]::WriteLine('  Press Y to confirm; any other key cancels.')
            $confirmationKey = Read-LibraryKey
            if (([string]$confirmationKey.KeyChar).ToUpperInvariant() -eq 'Y') {
                Remove-LibraryEntry -BookPath $entryToRemove.Path
                if ($cursor -ge $items.Count - 1 -and $cursor -gt 0) { $cursor-- }
            }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::Enter) {
            $activateSelection = $true
        }
        elseif ($keyCharacter -match '^[1-9]$') {
            $quickSelection = [int]$keyCharacter
            if ($quickSelection -le $items.Count) {
                $cursor = $quickSelection - 1
                $activateSelection = $true
            }
        }

        if ($activateSelection -and $items.Count -gt 0 -and $mode -eq 'Authors') {
            $selectedAuthor = [string]$authors[$cursor].Name
            $mode = 'AuthorBooks'
            $filter = ''
            $page = 0
            $cursor = 0
            continue
        }

        if ($activateSelection -and $items.Count -gt 0 -and $mode -ne 'Authors') {
            $selectedPath = [string]$entries[$cursor].Path
            if (Test-Path -LiteralPath $selectedPath -PathType Leaf) {
                return $selectedPath
            }
            Remove-LibraryEntry -BookPath $selectedPath
        }
    }
}

function Read-LocalTextFile {
    param([Parameter(Mandatory)][string]$FilePath)

    $resolved = (Resolve-Path -LiteralPath $FilePath).Path
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $encodingName = 'UTF-8'

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encodingName = 'UTF-16LE'
        $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encodingName = 'UTF-16BE'
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        try {
            $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
            $text = $strictUtf8.GetString($bytes)
        }
        catch {
            $encodingName = 'GB18030'
            try {
                $text = [Text.Encoding]::GetEncoding(54936).GetString($bytes)
            }
            catch {
                $encodingName = 'GBK'
                $text = [Text.Encoding]::GetEncoding(936).GetString($bytes)
            }
        }
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $contentId = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    [pscustomobject]@{
        Id       = $contentId
        Path     = $resolved
        Name     = [IO.Path]::GetFileName($resolved)
        Length   = $bytes.LongLength
        Modified = [IO.File]::GetLastWriteTimeUtc($resolved).ToString('o')
        Encoding = $encodingName
        Text     = $text.Replace([string][char]0, [string]'')
    }
}

function Get-BookProgress {
    param([Parameter(Mandatory)]$Book)

    if (-not $script:ProgressEnabled -or -not (Test-Path -LiteralPath $script:ProgressStatePath)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $script:ProgressStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($state.Entries)) {
            if ([string]::Equals([string]$entry.Path, [string]$Book.Path, [StringComparison]::OrdinalIgnoreCase)) {
                return $entry
            }
        }
    }
    catch {
        # A damaged state file should never prevent a book from opening.
    }

    return $null
}

function Save-BookProgress {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$TotalLines,
        [Parameter(Mandatory)][int]$ReaderLineCount
    )

    if (-not $script:ProgressEnabled -or $TotalLines -le 0) {
        return
    }

    try {
        $entries = @()
        if (Test-Path -LiteralPath $script:ProgressStatePath) {
            $existing = Get-Content -LiteralPath $script:ProgressStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = @($existing.Entries | Where-Object {
                -not [string]::Equals([string]$_.Path, [string]$Book.Path, [StringComparison]::OrdinalIgnoreCase)
            })
        }

        $boundedLine = [Math]::Max(0, [Math]::Min($TotalLines - 1, $LineIndex))
        $entry = [pscustomobject]@{
            Path      = $Book.Path
            Length    = $Book.Length
            Modified  = $Book.Modified
            LineIndex = $boundedLine
            Width     = $Width
            Progress  = $boundedLine / [double][Math]::Max(1, $TotalLines - 1)
            ReaderLines = $ReaderLineCount
            UpdatedAt = [DateTime]::UtcNow.ToString('o')
        }

        $payload = [pscustomobject]@{
            Version = 1
            Entries = @($entries) + $entry
        }

        $directory = Split-Path -Parent $script:ProgressStatePath
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }

        $json = $payload | ConvertTo-Json -Depth 5
        $temporaryPath = "$($script:ProgressStatePath).tmp"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:ProgressStatePath -Force
        Update-LibraryEntry -Book $Book -Progress $entry.Progress -LineCount $ReaderLineCount -Touch
    }
    catch {
        # Progress persistence is best-effort and must not interrupt reading.
    }
}

function Get-AllBookmarks {
    if (-not (Test-Path -LiteralPath $script:BookmarkStatePath -PathType Leaf)) { return @() }
    try {
        $state = Get-Content -LiteralPath $script:BookmarkStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($state.Entries)
    }
    catch { return @() }
}

function Save-AllBookmarks {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    if (-not $script:ProgressEnabled) { return }
    try {
        $directory = Split-Path -Parent $script:BookmarkStatePath
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        $payload = [pscustomobject]@{ Version = 1; Entries = @($Entries) }
        $temporaryPath = "$($script:BookmarkStatePath).tmp"
        [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:BookmarkStatePath -Force
    }
    catch { }
}

function Get-BookBookmarks {
    param([Parameter(Mandatory)]$Book)
    return @(Get-AllBookmarks | Where-Object { [string]$_.BookId -eq [string]$Book.Id } | Sort-Object Progress)
}

function Get-ChapterTitleAtLine {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters,
        [Parameter(Mandatory)][int]$LineIndex
    )
    if ($Chapters.Count -eq 0) { return '' }
    $index = Get-CurrentChapterIndex -Chapters $Chapters -CurrentLine $LineIndex
    if ($index -ge 0 -and $index -lt $Chapters.Count) { return [string]$Chapters[$index].Title }
    return ''
}

function Add-BookBookmark {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][int]$TotalLines,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters
    )
    if ($TotalLines -le 0) { return }
    $progress = $LineIndex / [double][Math]::Max(1, $TotalLines - 1)
    $all = @(Get-AllBookmarks | Where-Object {
        -not ([string]$_.BookId -eq [string]$Book.Id -and [Math]::Abs([double]$_.Progress - $progress) -lt 0.0001)
    })
    $chapterTitle = Get-ChapterTitleAtLine -Chapters $Chapters -LineIndex $LineIndex
    $excerpt = if ($LineIndex -ge 0 -and $LineIndex -lt $WrappedLines.Count) { [string]$WrappedLines[$LineIndex] } else { '' }
    if ($excerpt.Length -gt 50) { $excerpt = $excerpt.Substring(0, 50) + [char]0x2026 }
    $label = if (-not [string]::IsNullOrWhiteSpace($chapterTitle)) { $chapterTitle } elseif (-not [string]::IsNullOrWhiteSpace($excerpt)) { $excerpt } else { 'Bookmark' }
    $entry = [pscustomobject]@{
        Id        = [Guid]::NewGuid().ToString('N')
        BookId    = $Book.Id
        Path      = $Book.Path
        Progress  = $progress
        Label     = $label
        Excerpt   = $excerpt
        CreatedAt = [DateTime]::UtcNow.ToString('o')
    }
    Save-AllBookmarks -Entries (@($all) + $entry)
}

function Request-Bookmark {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][int]$CurrentLine,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters
    )

    $cursor = 0
    while ($true) {
        $bookmarks = @(Get-BookBookmarks -Book $Book)
        if ($bookmarks.Count -gt 0) { $cursor = [Math]::Max(0, [Math]::Min($cursor, $bookmarks.Count - 1)) } else { $cursor = 0 }
        [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25l")
        [Console]::WriteLine("$($script:Ansi.Cyan)BOOKMARKS  [$($bookmarks.Count)]$($script:Ansi.Reset)")
        [Console]::WriteLine('')
        if ($bookmarks.Count -eq 0) {
            [Console]::WriteLine('  No bookmarks. Press A to add the current position.')
        }
        else {
            for ($index = 0; $index -lt $bookmarks.Count; $index++) {
                $bookmark = $bookmarks[$index]
                $marker = if ($index -eq $cursor) { '>' } else { ' ' }
                $percent = [Math]::Round([double]$bookmark.Progress * 100, 1)
                $label = [string]$bookmark.Label
                if ($label.Length -gt 58) { $label = $label.Substring(0, 57) + [char]0x2026 }
                $line = ('{0} {1,2}. {2,6:N1}%  {3}' -f $marker, ($index + 1), $percent, $label)
                if ($index -eq $cursor) { [Console]::WriteLine("$($script:Ansi.Cyan)$line$($script:Ansi.Reset)") } else { [Console]::WriteLine($line) }
            }
        }
        [Console]::WriteLine('')
        [Console]::WriteLine('Up/Down select | Enter jump | A add current | E rename | D delete | Q back')
        $key = Read-LibraryKey
        $character = ([string]$key.KeyChar).ToUpperInvariant()
        if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape -or $character -eq 'Q') { return -1 }
        if ($key.Key -eq [ConsoleKey]::UpArrow -and $bookmarks.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - 1); continue }
        if ($key.Key -eq [ConsoleKey]::DownArrow -and $bookmarks.Count -gt 0) { $cursor = [Math]::Min($bookmarks.Count - 1, $cursor + 1); continue }
        if ($key.Key -eq [ConsoleKey]::Enter -and $bookmarks.Count -gt 0) {
            return [Math]::Floor([double]$bookmarks[$cursor].Progress * [Math]::Max(0, $WrappedLines.Count - 1))
        }
        if ($character -eq 'A') {
            Add-BookBookmark -Book $Book -LineIndex $CurrentLine -TotalLines $WrappedLines.Count -WrappedLines $WrappedLines -Chapters $Chapters
            continue
        }
        if ($character -eq 'D' -and $bookmarks.Count -gt 0) {
            $targetId = [string]$bookmarks[$cursor].Id
            Save-AllBookmarks -Entries @(Get-AllBookmarks | Where-Object { [string]$_.Id -ne $targetId })
            continue
        }
        if ($character -eq 'E' -and $bookmarks.Count -gt 0) {
            [Console]::Write("$script:Escape[?25h`r`nlabel> ")
            $newLabel = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            if (-not [string]::IsNullOrWhiteSpace($newLabel)) {
                $targetId = [string]$bookmarks[$cursor].Id
                $updated = @(Get-AllBookmarks | ForEach-Object {
                    if ([string]$_.Id -eq $targetId) {
                        [pscustomobject]@{ Id=$_.Id; BookId=$_.BookId; Path=$_.Path; Progress=$_.Progress; Label=$newLabel.Trim(); Excerpt=$_.Excerpt; CreatedAt=$_.CreatedAt }
                    } else { $_ }
                })
                Save-AllBookmarks -Entries $updated
            }
        }
    }
}

function Get-Chapters {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines)

    $result = [System.Collections.Generic.List[object]]::new()
    $numericCandidates = [System.Collections.Generic.List[object]]::new()
    # Keep this pattern ASCII-only: Windows PowerShell 5.1 reads UTF-8
    # scripts without a BOM using the active ANSI code page.
    $pattern = '^\s*(?:\u7B2C[\u96F6\u3007\u4E00\u4E8C\u4E09\u56DB\u4E94\u516D\u4E03\u516B\u4E5D\u5341\u767E\u5343\u4E07\u4E24\d]+[\u7AE0\u8282\u5377\u56DE\u90E8\u7BC7](?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u5E8F\u7AE0(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u6954\u5B50(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u5F15\u5B50(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u5C3E\u58F0(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u540E\u8BB0(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)|\u756A\u5916(?:\s|[:\uFF1A\u3001.\uFF0E-]|$)).*$'
    $numericPattern = '^\s*(?<number>\d{1,3})(?:[.\uFF0E]\s*(?<title>.*)|\s+(?<title>\S.*))$'

    for ($index = 0; $index -lt $WrappedLines.Count; $index++) {
        $candidate = $WrappedLines[$index].Trim()
        if ($candidate -match $pattern) {
            $result.Add([pscustomobject]@{
                Title     = $candidate
                LineIndex = $index
            })
        }
        elseif ($candidate -match $numericPattern) {
            $numericCandidates.Add([pscustomobject]@{
                Number    = [int]$Matches['number']
                Title     = $candidate
                LineIndex = $index
            })
        }
    }

    # Bare numeric headings are common in Chinese TXT editions (for example,
    # "1. title" and "27 title").  Only accept a sequence that starts at 1
    # and advances consecutively, which avoids treating numbered body lists as
    # chapters.
    $numericSequence = [System.Collections.Generic.List[object]]::new()
    $expectedNumber = 1
    foreach ($candidate in $numericCandidates) {
        if ($candidate.Number -eq $expectedNumber) {
            $numericSequence.Add($candidate)
            $expectedNumber++
        }
    }

    if ($numericSequence.Count -ge 3) {
        foreach ($candidate in $numericSequence) {
            $result.Add([pscustomobject]@{
                Title     = $candidate.Title
                LineIndex = $candidate.LineIndex
            })
        }
    }

    return @($result.ToArray() | Sort-Object -Property LineIndex)
}

function Get-ChapterCacheEntries {
    if (-not (Test-Path -LiteralPath $script:CacheStatePath -PathType Leaf)) {
        return @()
    }
    try {
        $state = Get-Content -LiteralPath $script:CacheStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($state.Entries)
    }
    catch {
        return @()
    }
}

function Save-ChapterCacheEntry {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$TotalLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters
    )

    if (-not $script:ProgressEnabled -or $TotalLines -le 0) { return }
    try {
        $entries = @(Get-ChapterCacheEntries | Where-Object {
            -not ([string]$_.BookId -eq [string]$Book.Id -and [int]$_.Width -eq $Width)
        })
        $cachedChapters = @($Chapters | ForEach-Object {
            [pscustomobject]@{
                Title    = [string]$_.Title
                Progress = [int]$_.LineIndex / [double][Math]::Max(1, $TotalLines - 1)
            }
        })
        $entry = [pscustomobject]@{
            BookId     = $Book.Id
            Length     = $Book.Length
            Modified   = $Book.Modified
            Width      = $Width
            Chapters   = $cachedChapters
            UpdatedAt  = [DateTime]::UtcNow.ToString('o')
        }
        $allEntries = @($entries | Sort-Object UpdatedAt -Descending | Select-Object -First 99) + $entry
        $payload = [pscustomobject]@{ Version = 1; Entries = $allEntries }
        $directory = Split-Path -Parent $script:CacheStatePath
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        $temporaryPath = "$($script:CacheStatePath).tmp"
        [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:CacheStatePath -Force
    }
    catch { }
}

function Get-BookLayout {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][int]$Width
    )

    $key = "$($Book.Id)|$Width"
    if ($script:LayoutCache.ContainsKey($key)) {
        return $script:LayoutCache[$key]
    }

    $wrapped = @(ConvertTo-WrappedLines -Text $Book.Text -Width $Width)
    $chapters = @()
    $cached = Get-ChapterCacheEntries | Where-Object {
        [string]$_.BookId -eq [string]$Book.Id -and
        [int]$_.Width -eq $Width -and
        [long]$_.Length -eq [long]$Book.Length -and
        [string]$_.Modified -eq [string]$Book.Modified
    } | Select-Object -First 1

    if ($null -ne $cached) {
        $chapters = @($cached.Chapters | ForEach-Object {
            [pscustomobject]@{
                Title     = [string]$_.Title
                LineIndex = [Math]::Min($wrapped.Count - 1, [Math]::Floor([double]$_.Progress * [Math]::Max(0, $wrapped.Count - 1)))
            }
        })
    }
    else {
        $chapters = @(Get-Chapters -WrappedLines $wrapped)
        Save-ChapterCacheEntry -Book $Book -Width $Width -TotalLines $wrapped.Count -Chapters $chapters
    }

    $layout = [pscustomobject]@{ WrappedLines = $wrapped; Chapters = $chapters }
    $script:LayoutCache[$key] = $layout
    $script:LayoutCacheOrder.Add($key)
    while ($script:LayoutCacheOrder.Count -gt 3) {
        $oldestKey = $script:LayoutCacheOrder[0]
        $script:LayoutCacheOrder.RemoveAt(0)
        $script:LayoutCache.Remove($oldestKey)
    }
    return $layout
}

function Get-CurrentChapterIndex {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters,
        [Parameter(Mandatory)][int]$CurrentLine
    )

    $current = -1
    for ($index = 0; $index -lt $Chapters.Count; $index++) {
        if ($Chapters[$index].LineIndex -gt $CurrentLine) {
            break
        }
        $current = $index
    }
    return $current
}

function Request-Chapter {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters,
        [Parameter(Mandatory)][int]$CurrentLine
    )

    if ($Chapters.Count -eq 0) {
        [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25h")
        [Console]::WriteLine("$($script:Ansi.Yellow)No chapter headings were detected.$($script:Ansi.Reset)")
        Start-Sleep -Milliseconds 900
        [Console]::Write("$script:Escape[?25l")
        return -1
    }

    $current = Get-CurrentChapterIndex -Chapters $Chapters -CurrentLine $CurrentLine
    $cursor = [Math]::Max(0, $current)
    $filter = ''
    $menuPageSize = [Math]::Max(8, [Math]::Min(20, (Get-SafeConsoleSize).Height - 6))

    while ($true) {
        $visibleChapters = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $Chapters.Count; $index++) {
            if ([string]::IsNullOrWhiteSpace($filter) -or $Chapters[$index].Title.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $visibleChapters.Add([pscustomobject]@{
                    OriginalIndex = $index
                    Title         = $Chapters[$index].Title
                })
            }
        }

        if ($visibleChapters.Count -gt 0) {
            $cursor = [Math]::Max(0, [Math]::Min($cursor, $visibleChapters.Count - 1))
        }
        else {
            $cursor = 0
        }

        $page = if ($visibleChapters.Count -gt 0) { [Math]::Floor($cursor / [double]$menuPageSize) } else { 0 }
        $pageCount = [Math]::Max(1, [Math]::Ceiling($visibleChapters.Count / [double]$menuPageSize))
        $start = $page * $menuPageSize
        $end = [Math]::Min($visibleChapters.Count, $start + $menuPageSize)

        [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25l")
        [Console]::WriteLine("$($script:Ansi.Cyan)CHAPTER INDEX  [$($Chapters.Count) detected]  Page $($page + 1)/$pageCount$($script:Ansi.Reset)")
        if (-not [string]::IsNullOrWhiteSpace($filter)) {
            [Console]::WriteLine("  Search: $filter    $($visibleChapters.Count) match(es)")
        }
        else {
            [Console]::WriteLine('')
        }

        if ($visibleChapters.Count -eq 0) {
            [Console]::WriteLine('  No chapter matched the search text.')
        }
        else {
            for ($index = $start; $index -lt $end; $index++) {
                $chapterItem = $visibleChapters[$index]
                $marker = if ($index -eq $cursor) { '>' } else { ' ' }
                $line = ('{0} {1,5}  {2}' -f $marker, ($chapterItem.OriginalIndex + 1), $chapterItem.Title)
                if ($index -eq $cursor) {
                    [Console]::WriteLine("$($script:Ansi.Cyan)$line$($script:Ansi.Reset)")
                }
                else {
                    [Console]::WriteLine($line)
                }
            }
        }

        [Console]::WriteLine('')
        [Console]::WriteLine('Up/Down select | Enter jump | N/P page | / search | G number | Esc cancel')
        $key = Read-LibraryKey
        $keyCharacter = ([string]$key.KeyChar).ToUpperInvariant()

        if ($key.Key -eq [ConsoleKey]::Escape -or $keyCharacter -eq 'Q') {
            return -1
        }

        if ($key.Key -eq [ConsoleKey]::Enter -and $visibleChapters.Count -gt 0) {
            return [int]$visibleChapters[$cursor].OriginalIndex
        }

        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            if ($visibleChapters.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - 1) }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::DownArrow) {
            if ($visibleChapters.Count -gt 0) { $cursor = [Math]::Min($visibleChapters.Count - 1, $cursor + 1) }
            continue
        }

        if ($keyCharacter -eq 'N' -or $key.Key -in @([ConsoleKey]::PageDown, [ConsoleKey]::RightArrow)) {
            if ($visibleChapters.Count -gt 0) { $cursor = [Math]::Min($visibleChapters.Count - 1, $cursor + $menuPageSize) }
            continue
        }

        if ($keyCharacter -eq 'P' -or $key.Key -in @([ConsoleKey]::PageUp, [ConsoleKey]::LeftArrow)) {
            if ($visibleChapters.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - $menuPageSize) }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::Home) {
            $cursor = 0
            continue
        }

        if ($key.Key -eq [ConsoleKey]::End) {
            if ($visibleChapters.Count -gt 0) { $cursor = $visibleChapters.Count - 1 }
            continue
        }

        if ($keyCharacter -eq '/') {
            [Console]::Write("$script:Escape[?25hsearch> ")
            $searchInput = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            if ($null -ne $searchInput) { $filter = $searchInput.Trim() }
            $cursor = 0
            continue
        }

        if ($keyCharacter -eq 'G') {
            [Console]::Write("$script:Escape[?25hchapter number> ")
            $numberInput = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            $number = 0
            if ([int]::TryParse($numberInput, [ref]$number) -and $number -ge 1 -and $number -le $Chapters.Count) {
                return $number - 1
            }
        }
    }
}

function Request-BookSearch {
    param([AllowEmptyString()][string]$CurrentQuery)

    [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25h")
    [Console]::WriteLine("$($script:Ansi.Cyan)FULL TEXT SEARCH$($script:Ansi.Reset)")
    if (-not [string]::IsNullOrWhiteSpace($CurrentQuery)) {
        [Console]::WriteLine("  Current: $CurrentQuery")
    }
    [Console]::WriteLine('  Enter an empty query to clear search highlighting.')
    [Console]::WriteLine('')
    [Console]::Write('search> ')
    $query = [Console]::ReadLine()
    [Console]::Write("$script:Escape[?25l")
    if ($null -eq $query) { return $CurrentQuery }
    return $query.Trim()
}

function Find-BookSearchMatches {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][string]$Query
    )

    $result = [System.Collections.Generic.List[int]]::new()
    if ([string]::IsNullOrWhiteSpace($Query)) { return $result.ToArray() }
    for ($index = 0; $index -lt $WrappedLines.Count; $index++) {
        if ($WrappedLines[$index].IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result.Add($index)
        }
    }
    return $result.ToArray()
}

function Format-ReaderTextLine {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$SearchQuery,
        [switch]$ActiveMatch
    )

    if ([string]::IsNullOrWhiteSpace($SearchQuery)) {
        return "$($script:Ansi.Gray)$Text$($script:Ansi.Reset)"
    }

    $builder = [Text.StringBuilder]::new()
    $position = 0
    while ($position -lt $Text.Length) {
        $matchIndex = $Text.IndexOf($SearchQuery, $position, [StringComparison]::OrdinalIgnoreCase)
        if ($matchIndex -lt 0) {
            [void]$builder.Append($script:Ansi.Gray)
            [void]$builder.Append($Text.Substring($position))
            break
        }
        if ($matchIndex -gt $position) {
            [void]$builder.Append($script:Ansi.Gray)
            [void]$builder.Append($Text.Substring($position, $matchIndex - $position))
        }
        if ($ActiveMatch) {
            [void]$builder.Append($script:Ansi.SearchActive)
        }
        else {
            [void]$builder.Append($script:Ansi.Search)
        }
        [void]$builder.Append($Text.Substring($matchIndex, $SearchQuery.Length))
        [void]$builder.Append($script:Ansi.Reset)
        $position = $matchIndex + $SearchQuery.Length
    }
    [void]$builder.Append($script:Ansi.Reset)
    return $builder.ToString()
}

function ConvertTo-SafeWorkText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaximumLength = 160
    )

    if ($null -eq $Text) {
        return ''
    }

    $safe = $Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
    if ($safe.Length -gt $MaximumLength) {
        return $safe.Substring(0, [Math]::Max(1, $MaximumLength - 1)) + [char]0x2026
    }
    return $safe
}

function Get-RelativeWorkPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FullName
    )

    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($prefix.Length)
    }
    return $FullName
}

function Get-SavedCodexSessionId {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return $null
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $property = $settings.PSObject.Properties['CodexSessionId']
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return ([string]$property.Value).Trim()
        }
    }
    catch { }

    return $null
}

function Save-ReaderSetting {
    param(
        [Parameter(Mandatory)][ValidateSet('CodexSessionId', 'ColorMode', 'SpacingMode', 'TextWidth')][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    try {
        $directory = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }

        $values = [ordered]@{ Version = 1 }
        if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
            try {
                $existingSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($property in @($existingSettings.PSObject.Properties)) {
                    $values[$property.Name] = $property.Value
                }
            }
            catch { }
        }
        $values['Version'] = 1
        $values[$Name] = $Value
        $json = ([pscustomobject]$values) | ConvertTo-Json -Depth 5
        $temporaryPath = "$($script:SettingsPath).tmp"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:SettingsPath -Force
        return $true
    }
    catch {
        return $false
    }
}

function Save-CodexSessionId {
    param([Parameter(Mandatory)][string]$SessionId)
    return (Save-ReaderSetting -Name CodexSessionId -Value $SessionId)
}

function Save-ColorMode {
    param([Parameter(Mandatory)][ValidateSet('Dark', 'Light')][string]$Mode)
    return (Save-ReaderSetting -Name ColorMode -Value $Mode)
}

function Save-SpacingMode {
    param([Parameter(Mandatory)][ValidateSet('Compact', 'Paragraph', 'Relaxed')][string]$Mode)
    return (Save-ReaderSetting -Name SpacingMode -Value $Mode)
}

function Save-TextWidth {
    param([Parameter(Mandatory)][ValidateSet(0, 72, 88, 104)][int]$Width)
    return (Save-ReaderSetting -Name TextWidth -Value ([string]$Width))
}

function Resolve-CodexSessionPath {
    param([Parameter(Mandatory)][string]$SessionId)

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $null
    }

    $sessionRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        return $null
    }

    foreach ($candidate in @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $firstRecord = Get-Content -LiteralPath $candidate.FullName -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json
            if ($firstRecord.type -eq 'session_meta' -and [string]$firstRecord.payload.id -eq $SessionId) {
                return $candidate.FullName
            }
        }
        catch { }
    }

    return $null
}

function Request-CodexSessionId {
    [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25h")
    [Console]::WriteLine("$($script:Ansi.Cyan)SELECT CODEX SESSION  [READ-ONLY]$($script:Ansi.Reset)")
    [Console]::WriteLine('')
    [Console]::WriteLine("  Current: $($script:CodexSessionId)")
    [Console]::WriteLine('  Paste a local Codex session UUID; blank input cancels.')
    [Console]::WriteLine('')
    [Console]::Write('session> ')
    $inputValue = [Console]::ReadLine()
    [Console]::Write("$script:Escape[?25l")

    if ($null -eq $inputValue -or [string]::IsNullOrWhiteSpace($inputValue)) {
        return $null
    }

    $candidate = $inputValue.Trim()
    if ($candidate -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        [Console]::WriteLine("$($script:Ansi.Yellow)Invalid session ID. Expected a UUID.$($script:Ansi.Reset)")
        Start-Sleep -Milliseconds 1000
        return $null
    }

    $resolvedPath = Resolve-CodexSessionPath -SessionId $candidate
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        [Console]::WriteLine("$($script:Ansi.Yellow)Local session not found: $candidate$($script:Ansi.Reset)")
        Start-Sleep -Milliseconds 1200
        return $null
    }

    return $candidate.ToLowerInvariant()
}

function Test-CodexInternalUserText {
    param([Parameter(Mandatory)][string]$Text)

    $trimmed = $Text.TrimStart()
    foreach ($prefix in @(
        '<environment_context>',
        '<permissions instructions>',
        '<collaboration_mode>',
        '<app-context>',
        '<skills_instructions>',
        '<tools>',
        '<apps_instructions>',
        '<plugins_instructions>',
        '<recommended_plugins>'
    )) {
        if ($trimmed.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    if ($trimmed.IndexOf('>>> APPROVAL REQUEST', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $trimmed.IndexOf('<<< APPROVAL REQUEST', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }

    return $false
}

function Test-CodexInternalAssistantText {
    param([Parameter(Mandatory)][string]$Text)

    $trimmed = $Text.TrimStart()
    if ($trimmed.StartsWith('{', [StringComparison]::Ordinal) -and
        $trimmed.IndexOf('"risk_level"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $trimmed.IndexOf('"outcome"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $trimmed.IndexOf('"rationale"', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }

    return $false
}

function Get-CodexSessionPreview {
    param([Parameter(Mandatory)][IO.FileInfo]$File)

    try {
        $first = Get-Content -LiteralPath $File.FullName -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json
        if ($first.type -ne 'session_meta' -or [string]::IsNullOrWhiteSpace([string]$first.payload.id)) { return $null }
        $sessionId = [string]$first.payload.id
        $cwd = [string]$first.payload.cwd
        $title = ''

        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            # A short tail is enough for a recent user message and keeps the
            # session picker responsive even when old JSONL files are large.
            $tailBytes = [Math]::Min([long]256KB, $stream.Length)
            [void]$stream.Seek(-$tailBytes, [IO.SeekOrigin]::End)
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
            try {
                if ($tailBytes -lt $stream.Length) { [void]$reader.ReadLine() }
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($line.IndexOf('"type":"response_item"', [StringComparison]::Ordinal) -lt 0 -or
                        $line.IndexOf('"type":"message"', [StringComparison]::Ordinal) -lt 0) { continue }
                    try {
                        $record = $line | ConvertFrom-Json
                        if ($record.payload.type -ne 'message' -or $record.payload.role -ne 'user') { continue }
                        $parts = @($record.payload.content | ForEach-Object {
                            if ($null -ne $_.PSObject.Properties['text']) { [string]$_.text }
                        })
                        $candidate = ($parts -join ' ').Trim()
                        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not (Test-CodexInternalUserText -Text $candidate)) {
                            $title = $candidate
                        }
                    }
                    catch { }
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }

        if ([string]::IsNullOrWhiteSpace($title)) { return $null }
        $title = ($title -replace '\s+', ' ').Trim()
        if ($title.Length -gt 54) { $title = $title.Substring(0, 53) + [char]0x2026 }
        $project = if ([string]::IsNullOrWhiteSpace($cwd)) { '<unknown>' } else { Split-Path -Leaf $cwd }
        return [pscustomobject]@{
            Id      = $sessionId
            Project = $project
            Title   = $title
            Updated = $File.LastWriteTime
        }
    }
    catch { return $null }
}

function Get-RecentCodexSessions {
    $sessionRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) { return @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 24)) {
        $preview = Get-CodexSessionPreview -File $file
        if ($null -ne $preview) { $result.Add($preview) }
    }
    return $result.ToArray()
}

function Select-CodexSession {
    $sessions = @(Get-RecentCodexSessions)
    $filter = ''
    $cursor = 0
    $pageSize = 15

    while ($true) {
        $visible = @($sessions | Where-Object {
            [string]::IsNullOrWhiteSpace($filter) -or
            ([string]$_.Project).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.Title).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.Id).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($visible.Count -gt 0) { $cursor = [Math]::Max(0, [Math]::Min($cursor, $visible.Count - 1)) } else { $cursor = 0 }
        $page = if ($visible.Count -gt 0) { [Math]::Floor($cursor / [double]$pageSize) } else { 0 }
        $pageCount = [Math]::Max(1, [Math]::Ceiling($visible.Count / [double]$pageSize))
        $start = $page * $pageSize
        $end = [Math]::Min($visible.Count, $start + $pageSize)

        [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25l")
        [Console]::WriteLine("$($script:Ansi.Cyan)CODEX SESSIONS  [READ-ONLY]  Page $($page + 1)/$pageCount$($script:Ansi.Reset)")
        if (-not [string]::IsNullOrWhiteSpace($filter)) { [Console]::WriteLine("  Filter: $filter") }
        [Console]::WriteLine('')
        if ($visible.Count -eq 0) {
            [Console]::WriteLine('  No visible conversation sessions found.')
        }
        else {
            for ($index = $start; $index -lt $end; $index++) {
                $item = $visible[$index]
                $marker = if ($index -eq $cursor) { '>' } else { ' ' }
                $current = if ([string]$item.Id -eq $script:CodexSessionId) { '*' } else { ' ' }
                $project = [string]$item.Project
                if ($project.Length -gt 18) { $project = $project.Substring(0, 17) + [char]0x2026 }
                $title = [string]$item.Title
                if ($title.Length -gt 46) { $title = $title.Substring(0, 45) + [char]0x2026 }
                $line = ('{0}{1} {2:MM-dd HH:mm} {3,-19} {4}' -f $marker, $current, $item.Updated, $project, $title)
                if ($index -eq $cursor) { [Console]::WriteLine("$($script:Ansi.Cyan)$line$($script:Ansi.Reset)") } else { [Console]::WriteLine($line) }
            }
        }
        [Console]::WriteLine('')
        [Console]::WriteLine('Up/Down select | Enter follow | / search | P paste UUID | R rescan | Q back')
        $key = Read-LibraryKey
        $character = ([string]$key.KeyChar).ToUpperInvariant()
        if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape -or $character -eq 'Q') { return $null }
        if ($key.Key -eq [ConsoleKey]::UpArrow -and $visible.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - 1); continue }
        if ($key.Key -eq [ConsoleKey]::DownArrow -and $visible.Count -gt 0) { $cursor = [Math]::Min($visible.Count - 1, $cursor + 1); continue }
        if ($key.Key -eq [ConsoleKey]::PageDown -and $visible.Count -gt 0) { $cursor = [Math]::Min($visible.Count - 1, $cursor + $pageSize); continue }
        if ($key.Key -eq [ConsoleKey]::PageUp -and $visible.Count -gt 0) { $cursor = [Math]::Max(0, $cursor - $pageSize); continue }
        if ($key.Key -eq [ConsoleKey]::Enter -and $visible.Count -gt 0) { return [string]$visible[$cursor].Id }
        if ($character -eq 'R') { $sessions = @(Get-RecentCodexSessions); $cursor = 0; continue }
        if ($character -eq 'P') {
            $manualSessionId = Request-CodexSessionId
            return $manualSessionId
        }
        if ($character -eq '/') {
            [Console]::Write("$script:Escape[?25h`r`nsearch> ")
            $value = [Console]::ReadLine()
            [Console]::Write("$script:Escape[?25l")
            if ($null -ne $value) { $filter = $value.Trim() }
            $cursor = 0
        }
    }
}

function Add-CodexFeedRecord {
    param([Parameter(Mandatory)]$Record)

    if ($Record.type -ne 'response_item' -or $Record.payload.type -ne 'message') {
        return
    }

    $role = [string]$Record.payload.role
    if ($role -notin @('user', 'assistant')) {
        return
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Record.payload.content)) {
        $textProperty = $part.PSObject.Properties['text']
        if ($null -ne $textProperty -and -not [string]::IsNullOrWhiteSpace([string]$textProperty.Value)) {
            $parts.Add([string]$textProperty.Value)
        }
    }

    $text = ($parts -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }
    if ($role -eq 'user' -and (Test-CodexInternalUserText -Text $text)) {
        return
    }
    if ($role -eq 'assistant' -and (Test-CodexInternalAssistantText -Text $text)) {
        return
    }

    $phase = ''
    $phaseProperty = $Record.payload.PSObject.Properties['phase']
    if ($null -ne $phaseProperty) {
        $phase = [string]$phaseProperty.Value
    }

    $script:CodexFeedState.Messages.Add([pscustomobject]@{
        Role      = $role
        Text      = $text
        Phase     = $phase
        Timestamp = [string]$Record.timestamp
    })

    while ($script:CodexFeedState.Messages.Count -gt 40) {
        $script:CodexFeedState.Messages.RemoveAt(0)
    }
}

function Update-CodexFeed {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SessionId)

    if ($script:CodexFeedState.SessionId -ne $SessionId) {
        $script:CodexFeedState.SessionId = $SessionId
        $script:CodexFeedState.Path = $null
        $script:CodexFeedState.Offset = [long]0
        $script:CodexFeedState.Pending = ''
        $script:CodexFeedState.Messages.Clear()
        $script:CodexFeedState.Error = $null
        $script:CodexFeedState.UpdatedAt = $null
    }

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        $script:CodexFeedState.Error = 'No Codex session ID is configured.'
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$script:CodexFeedState.Path)) {
        $script:CodexFeedState.Path = Resolve-CodexSessionPath -SessionId $SessionId
        if ([string]::IsNullOrWhiteSpace([string]$script:CodexFeedState.Path)) {
            $script:CodexFeedState.Error = "Session not found: $SessionId"
            return
        }
    }

    try {
        $fileInfo = [IO.FileInfo]::new([string]$script:CodexFeedState.Path)
        if (-not $fileInfo.Exists) {
            throw 'The session record is no longer available.'
        }

        if ($fileInfo.Length -lt [long]$script:CodexFeedState.Offset) {
            $script:CodexFeedState.Offset = [long]0
            $script:CodexFeedState.Pending = ''
            $script:CodexFeedState.Messages.Clear()
        }
        if ($fileInfo.Length -eq [long]$script:CodexFeedState.Offset) {
            return
        }

        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open([string]$script:CodexFeedState.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            [void]$stream.Seek([long]$script:CodexFeedState.Offset, [IO.SeekOrigin]::Begin)
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
            try {
                $firstLine = $true
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($firstLine -and -not [string]::IsNullOrEmpty([string]$script:CodexFeedState.Pending)) {
                        $line = [string]$script:CodexFeedState.Pending + $line
                        $script:CodexFeedState.Pending = ''
                    }
                    $firstLine = $false

                    if ($line.IndexOf('"type":"response_item"', [StringComparison]::Ordinal) -lt 0 -or
                        $line.IndexOf('"type":"message"', [StringComparison]::Ordinal) -lt 0) {
                        continue
                    }

                    try {
                        Add-CodexFeedRecord -Record ($line | ConvertFrom-Json)
                    }
                    catch {
                        $script:CodexFeedState.Pending = $line
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
            $script:CodexFeedState.Offset = $stream.Length
        }
        finally {
            $stream.Dispose()
        }

        $script:CodexFeedState.Error = $null
        $script:CodexFeedState.UpdatedAt = $fileInfo.LastWriteTime
    }
    catch {
        $script:CodexFeedState.Error = $_.Exception.Message
    }
}

function Get-CodexFeedLines {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory)][int]$LineCount,
        [Parameter(Mandatory)][int]$Width
    )

    Update-CodexFeed -SessionId $SessionId
    $result = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace([string]$script:CodexFeedState.Error)) {
        $result.Add(@{ Kind = 'Dim'; Text = "CODEX FEED UNAVAILABLE: $($script:CodexFeedState.Error)" })
        return $result.ToArray()
    }

    if ($script:CodexFeedState.Messages.Count -eq 0) {
        $result.Add(@{ Kind = 'Dim'; Text = 'No visible user or assistant messages were found.' })
        return $result.ToArray()
    }

    $selectedLines = [System.Collections.Generic.List[object]]::new()
    $wrapWidth = [Math]::Max(20, $Width - 9)
    for ($messageIndex = $script:CodexFeedState.Messages.Count - 1; $messageIndex -ge 0; $messageIndex--) {
        $message = $script:CodexFeedState.Messages[$messageIndex]
        $label = if ($message.Role -eq 'user') { 'USER >' } else { 'CODEX>' }
        $kind = if ($message.Role -eq 'user') { 'User' } else { 'Assistant' }
        $wrapped = @(ConvertTo-WrappedLines -Text ([string]$message.Text) -Width $wrapWidth)
        $separatorCount = if ($selectedLines.Count -gt 0) { 1 } else { 0 }
        $remaining = $LineCount - $selectedLines.Count
        if ($remaining -le 0) { break }

        $block = [System.Collections.Generic.List[object]]::new()
        if (($wrapped.Count + $separatorCount) -le $remaining) {
            for ($index = 0; $index -lt $wrapped.Count; $index++) {
                $prefix = if ($index -eq 0) { "$label " } else { '       ' }
                $block.Add(@{ Kind = $kind; Text = "$prefix$($wrapped[$index])" })
            }
        }
        else {
            $bodyRoom = [Math]::Max(1, $remaining - $separatorCount)
            $block.Add(@{ Kind = $kind; Text = "$label ..." })
            $tailCount = [Math]::Max(0, $bodyRoom - 1)
            $tailStart = [Math]::Max(0, $wrapped.Count - $tailCount)
            for ($index = $tailStart; $index -lt $wrapped.Count; $index++) {
                $block.Add(@{ Kind = $kind; Text = "       $($wrapped[$index])" })
            }
        }

        if ($separatorCount -gt 0 -and $block.Count -lt $remaining) {
            $block.Add(@{ Kind = 'Dim'; Text = '' })
        }
        for ($index = $block.Count - 1; $index -ge 0; $index--) {
            $selectedLines.Insert(0, $block[$index])
        }

        if (($wrapped.Count + $separatorCount) -gt $remaining) {
            break
        }
    }

    foreach ($line in $selectedLines) {
        $result.Add($line)
    }
    return $result.ToArray()
}

function Get-WorkspaceFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaximumFiles = 1200,
        [int]$MaximumDirectories = 120
    )

    $skipNames = @('.git', '.svn', '.hg', 'node_modules', 'target', 'dist', 'build', '.idea', '.vs', '.vscode', '.venv', 'venv', '__pycache__', 'coverage', 'shelf')
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $queue.Enqueue($Root)
    $visitedDirectories = 0

    while ($queue.Count -gt 0 -and $visitedDirectories -lt $MaximumDirectories -and $files.Count -lt $MaximumFiles) {
        $directory = $queue.Dequeue()
        $visitedDirectories++

        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                try {
                    $files.Add([IO.FileInfo]::new($file))
                    if ($files.Count -ge $MaximumFiles) { break }
                }
                catch { }
            }

            if ($files.Count -ge $MaximumFiles) { break }

            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                $name = [IO.Path]::GetFileName($child)
                if ($skipNames -notcontains $name.ToLowerInvariant()) {
                    $queue.Enqueue($child)
                }
            }
        }
        catch { }
    }

    return $files.ToArray()
}

function Get-WorkOutput {
    param(
        [int]$LineCount,
        [int]$ProfileIndex,
        [int]$Tick,
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()][string]$LogPath,
        [int]$Width
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $profile = [int]($ProfileIndex % 5)
    $viewNames = @('ACTIVITY', 'GIT', 'PROCESS', 'LOG', 'CODEX')
    $prompt = "PS $Root>"
    $source = [System.Collections.Generic.List[object]]::new()
    $files = @()
    $recentFiles = @()
    if ($profile -ne 4) {
        $files = @(Get-WorkspaceFiles -Root $Root)
        $recentFiles = @($files | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 12)
    }

    if ($profile -eq 4) {
        $shortSessionId = if ([string]::IsNullOrWhiteSpace($script:CodexSessionId)) { 'NO SESSION' } elseif ($script:CodexSessionId.Length -ge 8) { $script:CodexSessionId.Substring(0, 8) } else { $script:CodexSessionId }
        $source.Add(@{ Kind = 'Heading'; Text = "CODEX SESSION  READ-ONLY  [$shortSessionId]  |  S change" })
    }
    else {
        $source.Add(@{ Kind = 'Heading'; Text = "WORKSPACE SNAPSHOT  $($viewNames[$profile])  [$timestamp]" })
    }

    switch ($profile) {
        0 {
            $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Get-ChildItem -File -Recurse | Sort-Object LastWriteTime -Descending" })
            foreach ($file in $recentFiles) {
                $relative = Get-RelativeWorkPath -Root $Root -FullName $file.FullName
                $size = if ($file.Length -ge 1MB) { '{0,7:N1} MB' -f ($file.Length / 1MB) } else { '{0,7:N0} KB' -f ($file.Length / 1KB) }
                $source.Add(@{ Kind = 'Dim'; Text = ('{0}  {1}  {2}' -f $file.LastWriteTime.ToString('HH:mm:ss'), $size, $relative) })
            }
            $source.Add(@{ Kind = 'Ok'; Text = "[$timestamp] scan complete: $($files.Count) files sampled" })
        }
        1 {
            $source.Add(@{ Kind = 'Prompt'; Text = "$prompt git status --short --branch" })
            $gitCommand = Get-Command git -ErrorAction SilentlyContinue
            $gitLines = @()
            if ($null -ne $gitCommand) {
                try {
                    $gitLines = @(& $gitCommand.Source -C $Root -c color.status=false status --short --branch --untracked-files=no 2>$null)
                }
                catch { }
            }

            if ($gitLines.Count -eq 0) {
                $source.Add(@{ Kind = 'Dim'; Text = 'No Git worktree detected, or the worktree is clean.' })
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Get-ChildItem -Force" })
                foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Select-Object -First 10)) {
                    $marker = if ($item.PSIsContainer) { '<DIR>' } else { '{0:N0} KB' -f ($item.Length / 1KB) }
                    $source.Add(@{ Kind = 'Dim'; Text = ('{0,-9} {1}' -f $marker, $item.Name) })
                }
            }
            else {
                foreach ($line in $gitLines | Select-Object -First ([Math]::Max(1, $LineCount - 3))) {
                    $kind = if ([string]$line -like '##*') { 'Ok' } else { 'Dim' }
                    $source.Add(@{ Kind = $kind; Text = [string]$line })
                }
            }
            $source.Add(@{ Kind = 'Ok'; Text = "[$timestamp] local status refreshed" })
        }
        2 {
            $packagePath = Join-Path $Root 'package.json'
            $cargoPath = Join-Path $Root 'Cargo.toml'
            $pythonPath = Join-Path $Root 'pyproject.toml'

            $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Get-CimInstance Win32_Process # filtered to this workspace" })
            $projectProcesses = @()
            try {
                $projectProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                    $commandLine = [string]$_.CommandLine
                    $_.ProcessId -ne $PID -and
                    -not [string]::IsNullOrWhiteSpace($commandLine) -and
                    $commandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    $commandLine -notmatch '(?i)(reader\.ps1|(?:mo-)?fish-reader\.cmd)'
                } | Select-Object -First 8)
            }
            catch { }

            if ($projectProcesses.Count -gt 0) {
                foreach ($process in $projectProcesses) {
                    $processCommand = ConvertTo-SafeWorkText -Text ([string]$process.CommandLine) -MaximumLength 110
                    $source.Add(@{ Kind = 'Dim'; Text = ('PID {0,-6} {1,-18} {2}' -f $process.ProcessId, $process.Name, $processCommand) })
                }
            }
            else {
                $source.Add(@{ Kind = 'Dim'; Text = 'No active process currently references this workspace.' })
            }

            if (Test-Path -LiteralPath $packagePath) {
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt # available package scripts" })
                try {
                    $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $packageName = if ($null -ne $package.PSObject.Properties['name']) { [string]$package.name } else { '<unnamed>' }
                    $packageVersion = if ($null -ne $package.PSObject.Properties['version']) { [string]$package.version } else { '<none>' }
                    $source.Add(@{ Kind = 'Ok'; Text = "name: $packageName    version: $packageVersion" })
                    if ($null -ne $package.PSObject.Properties['scripts'] -and $null -ne $package.scripts) {
                        foreach ($property in @($package.scripts.PSObject.Properties) | Select-Object -First 8) {
                            $source.Add(@{ Kind = 'Dim'; Text = ('npm run {0,-14} # {1}' -f $property.Name, $property.Value) })
                        }
                    }
                }
                catch {
                    $source.Add(@{ Kind = 'Dim'; Text = 'package.json exists but could not be parsed.' })
                }
            }
            elseif (Test-Path -LiteralPath $cargoPath) {
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Select-String .\Cargo.toml -Pattern 'name|version'" })
                foreach ($line in @(Get-Content -LiteralPath $cargoPath -ErrorAction SilentlyContinue | Select-String -Pattern '^\s*(name|version|edition)\s*=') | Select-Object -First 10) {
                    $source.Add(@{ Kind = 'Dim'; Text = $line.Line.Trim() })
                }
            }
            elseif (Test-Path -LiteralPath $pythonPath) {
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Select-String .\pyproject.toml -Pattern 'name|version|dependencies'" })
                foreach ($line in @(Get-Content -LiteralPath $pythonPath -ErrorAction SilentlyContinue | Select-String -Pattern '^\s*(name|version|dependencies)\s*=') | Select-Object -First 10) {
                    $source.Add(@{ Kind = 'Dim'; Text = $line.Line.Trim() })
                }
            }
            else {
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Get-ChildItem -File -Recurse | Group-Object Extension" })
                foreach ($group in @($files | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 10)) {
                    $extension = if ([string]::IsNullOrWhiteSpace($group.Name)) { '<none>' } else { $group.Name }
                    $source.Add(@{ Kind = 'Dim'; Text = ('{0,7}  {1}' -f $group.Count, $extension) })
                }
            }
            $source.Add(@{ Kind = 'Ok'; Text = "[$timestamp] project metadata refreshed" })
        }
        3 {
            $activeLog = $LogPath
            if ([string]::IsNullOrWhiteSpace($activeLog) -or -not (Test-Path -LiteralPath $activeLog -PathType Leaf)) {
                $logFile = $files | Where-Object { $_.Extension -eq '.log' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($null -ne $logFile) { $activeLog = $logFile.FullName }
            }

            if (-not [string]::IsNullOrWhiteSpace($activeLog) -and (Test-Path -LiteralPath $activeLog -PathType Leaf)) {
                $relativeLog = Get-RelativeWorkPath -Root $Root -FullName $activeLog
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt Get-Content '$relativeLog' -Tail 20 -Wait" })
                foreach ($line in @(Get-Content -LiteralPath $activeLog -Tail ([Math]::Max(1, $LineCount - 3)) -ErrorAction SilentlyContinue)) {
                    $source.Add(@{ Kind = 'Dim'; Text = [string]$line })
                }
            }
            else {
                $source.Add(@{ Kind = 'Prompt'; Text = "$prompt # live file activity (no .log file found)" })
                foreach ($file in $recentFiles) {
                    $relative = Get-RelativeWorkPath -Root $Root -FullName $file.FullName
                    $source.Add(@{ Kind = 'Dim'; Text = ('[{0} CHG] {1}' -f $file.LastWriteTime.ToString('HH:mm:ss'), $relative) })
                }
            }
            $source.Add(@{ Kind = 'Ok'; Text = "[$timestamp] watcher refresh complete" })
        }
        4 {
            foreach ($line in @(Get-CodexFeedLines -SessionId $script:CodexSessionId -LineCount ([Math]::Max(1, $LineCount - 1)) -Width $Width)) {
                $source.Add($line)
            }
        }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $maximumTextLength = [Math]::Max(40, $Width - 1)
    for ($index = 0; $index -lt $LineCount; $index++) {
        if ($index -lt $source.Count) {
            $line = $source[$index]
            $result.Add(@{
                Kind = $line.Kind
                Text = ConvertTo-SafeWorkText -Text ([string]$line.Text) -MaximumLength $maximumTextLength
            })
        }
        else {
            $result.Add(@{ Kind = 'Normal'; Text = '' })
        }
    }

    return $result.ToArray()
}

function Format-PowerShellCommandText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $builder = [Text.StringBuilder]::new()
    $tokenPattern = '"[^"]*"|''[^'']*''|\s+|[^\s]+'
    $commandSeen = $false
    $inComment = $false

    foreach ($match in [regex]::Matches($Text, $tokenPattern)) {
        $token = $match.Value
        if ($token -match '^\s+$') {
            [void]$builder.Append($token)
            continue
        }

        $color = $script:Ansi.Gray
        if ($inComment -or $token.StartsWith('#')) {
            $inComment = $true
            $color = $script:Ansi.Dim
        }
        elseif (-not $commandSeen) {
            $commandSeen = $true
            $color = $script:Ansi.Command
        }
        elseif ($token -match '^--?[A-Za-z][A-Za-z0-9-]*(?:[:=].*)?$') {
            $color = $script:Ansi.Parameter
        }
        elseif ($token.StartsWith('"') -or $token.StartsWith("'")) {
            $color = $script:Ansi.String
        }
        elseif ($token -match '^\$[A-Za-z_{]') {
            $color = $script:Ansi.Green
        }
        elseif ($token -match '^(\||>|>>|2>|2>>|=|&&|\|\|)$') {
            $color = $script:Ansi.Cyan
        }
        elseif ($token -match '^(?:\.{0,2}[\\/]|[A-Za-z]:[\\/]|~[\\/])' -or
                $token -match '\.(txt|json|jsonl|log|md|ps1|psm1|cmd|bat|yaml|yml|toml|xml|csv)(?:[,:;)]*)$') {
            $color = $script:Ansi.Path
        }
        elseif ($token -match '^[+-]?\d+(?:\.\d+)?(?:KB|MB|GB|ms|s)?[,;)]*$') {
            $color = $script:Ansi.Yellow
        }

        [void]$builder.Append($color)
        [void]$builder.Append($token)
        [void]$builder.Append($script:Ansi.Reset)
    }

    return $builder.ToString()
}

function Format-PowerShellPromptLine {
    param([AllowEmptyString()][string]$Text)

    $promptEnd = $Text.IndexOf('>')
    if ($promptEnd -lt 0) {
        return Format-PowerShellCommandText -Text $Text
    }

    $prompt = $Text.Substring(0, $promptEnd + 1)
    $commandText = $Text.Substring($promptEnd + 1).TrimStart()
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return "$($script:Ansi.Green)$prompt$($script:Ansi.Reset)"
    }

    return "$($script:Ansi.Green)$prompt$($script:Ansi.Reset) $(Format-PowerShellCommandText -Text $commandText)"
}

function Format-DialogueLine {
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Assistant')][string]$Role,
        [AllowEmptyString()][string]$Text
    )

    if ($Role -eq 'User') {
        if ($Text.StartsWith('USER >')) {
            return "$($script:Ansi.Green)USER >$($script:Ansi.Reset)$($script:Ansi.White)$($Text.Substring(6))$($script:Ansi.Reset)"
        }
        return "$($script:Ansi.White)$Text$($script:Ansi.Reset)"
    }

    if ($Text.StartsWith('CODEX>')) {
        return "$($script:Ansi.Cyan)CODEX>$($script:Ansi.Reset)$($script:Ansi.Gray)$($Text.Substring(6))$($script:Ansi.Reset)"
    }
    return "$($script:Ansi.Gray)$Text$($script:Ansi.Reset)"
}

function Format-WorkLine {
    param([hashtable]$Line)

    switch ($Line.Kind) {
        'Heading'   { return "$($script:Ansi.Blue)$($Line.Text)$($script:Ansi.Reset)" }
        'Prompt'    { return Format-PowerShellPromptLine -Text ([string]$Line.Text) }
        'User'      { return Format-DialogueLine -Role User -Text ([string]$Line.Text) }
        'Assistant' { return Format-DialogueLine -Role Assistant -Text ([string]$Line.Text) }
        'Ok'        { return "$($script:Ansi.Green)$($Line.Text)$($script:Ansi.Reset)" }
        'Dim'       { return "$($script:Ansi.Dim)$($Line.Text)$($script:Ansi.Reset)" }
        default     { return "$($script:Ansi.Gray)$($Line.Text)$($script:Ansi.Reset)" }
    }
}

function Show-ReaderScreen {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][int[]]$DisplayRows,
        [Parameter(Mandatory)][int]$Page,
        [Parameter(Mandatory)][int]$PageSize,
        [Parameter(Mandatory)][int]$WorkRows,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$ReaderLineCount,
        [Parameter(Mandatory)][int]$WorkProfileIndex,
        [Parameter(Mandatory)][int]$WorkTick,
        [Parameter(Mandatory)][string]$WorkRoot,
        [AllowNull()][string]$WorkLog,
        [Parameter(Mandatory)][bool]$PrivacyMode,
        [AllowEmptyString()][string]$SearchQuery = '',
        [int]$SearchIndex = -1,
        [int]$SearchCount = 0,
        [int]$SearchLine = -1,
        [Parameter(Mandatory)][ValidateSet('Compact', 'Paragraph', 'Relaxed')][string]$SpacingMode
    )

    $buffer = [Text.StringBuilder]::new()
    [void]$buffer.Append("$script:Escape[2J$script:Escape[H")

    $consoleSize = Get-SafeConsoleSize
    $shortcutRows = @(Get-ReaderShortcutRows -Width $Width)
    $footerRowCount = 2 + $shortcutRows.Count
    $workLineCount = if ($PrivacyMode) {
        [Math]::Max(4, $consoleSize.Height - $footerRowCount - 1)
    }
    else {
        $WorkRows
    }
    foreach ($line in (Get-WorkOutput -LineCount $workLineCount -ProfileIndex $WorkProfileIndex -Tick $WorkTick -Root $WorkRoot -LogPath $WorkLog -Width $Width)) {
        [void]$buffer.Append((Format-WorkLine -Line $line))
        [void]$buffer.Append("`r`n")
    }

    if (-not $PrivacyMode) {
        $separatorWidth = [Math]::Max(10, $Width - 48)
        $separator = [string]::new([char]0x2500, $separatorWidth)
        [void]$buffer.Append("$($script:Ansi.Dim) TERMINAL  OUTPUT  DEBUG CONSOLE  $separator  pwsh $($script:Ansi.Reset)`r`n")
        [void]$buffer.Append((Format-PowerShellPromptLine -Text 'PS C:\workspace\docs> Get-Content notes.txt'))
        [void]$buffer.Append("`r`n")

        $start = $Page * $PageSize
        for ($offset = 0; $offset -lt $PageSize; $offset++) {
            $displayIndex = $start + $offset
            $lineIndex = if ($displayIndex -lt $DisplayRows.Count) { $DisplayRows[$displayIndex] } else { -1 }
            if ($lineIndex -ge 0 -and $lineIndex -lt $WrappedLines.Count) {
                [void]$buffer.Append('  ')
                [void]$buffer.Append((Format-ReaderTextLine -Text ([string]$WrappedLines[$lineIndex]) -SearchQuery $SearchQuery -ActiveMatch:($lineIndex -eq $SearchLine)))
                [void]$buffer.Append("`r`n")
            }
            else {
                [void]$buffer.Append("`r`n")
            }
        }
    }

    $pageCount = [Math]::Max(1, [Math]::Ceiling($DisplayRows.Count / [double]$PageSize))
    $mode = if ($PrivacyMode) { 'FOCUS: OUTPUT' } else { "PAGE $($Page + 1)/$pageCount" }
    $activeWorkView = @('ACTIVITY', 'GIT', 'PROCESS', 'LOG', 'CODEX')[[int]($WorkProfileIndex % 5)]
    $searchStatus = if ($SearchCount -gt 0) { " | FIND $($SearchIndex + 1)/$SearchCount" } else { '' }
    $spacingStatus = switch ($SpacingMode) { 'Compact' { 'COMPACT' }; 'Paragraph' { 'PARA' }; default { 'RELAXED' } }
    $widthStatus = if ($script:ActiveTextWidth -eq 0) { 'AUTO' } else { [string]$script:ActiveTextWidth }
    $status = " $($Book.Encoding) | $mode | COL $widthStatus | SPC $spacingStatus | $activeWorkView$searchStatus "
    $footerDivider = [string]::new([char]0x2500, [Math]::Max(10, $Width - 1))
    [void]$buffer.Append("$($script:Ansi.Dim)$footerDivider$($script:Ansi.Reset)`r`n")
    [void]$buffer.Append("$($script:Ansi.Gray)$status$($script:Ansi.Reset)`r`n")
    for ($shortcutIndex = 0; $shortcutIndex -lt $shortcutRows.Count; $shortcutIndex++) {
        [void]$buffer.Append(" $($shortcutRows[$shortcutIndex])")
        if ($shortcutIndex -lt $shortcutRows.Count - 1) {
            [void]$buffer.Append("`r`n")
        }
    }

    [Console]::Write($buffer.ToString())
}

function Show-ReaderRegion {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$WrappedLines,
        [Parameter(Mandatory)][int[]]$DisplayRows,
        [Parameter(Mandatory)][int]$Page,
        [Parameter(Mandatory)][int]$PageSize,
        [Parameter(Mandatory)][int]$WorkRows,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$WorkProfileIndex,
        [AllowEmptyString()][string]$SearchQuery = '',
        [int]$SearchIndex = -1,
        [int]$SearchCount = 0,
        [int]$SearchLine = -1,
        [Parameter(Mandatory)][ValidateSet('Compact', 'Paragraph', 'Relaxed')][string]$SpacingMode
    )

    # The separator, prompt, divider, and shortcut rows are static during
    # ordinary paging. Only replace the body rows and the changing status row.
    $buffer = [Text.StringBuilder]::new()
    $start = $Page * $PageSize
    $firstBodyRow = $WorkRows + 3
    for ($offset = 0; $offset -lt $PageSize; $offset++) {
        $displayIndex = $start + $offset
        $lineIndex = if ($displayIndex -lt $DisplayRows.Count) { $DisplayRows[$displayIndex] } else { -1 }
        $row = $firstBodyRow + $offset
        if ($lineIndex -ge 0 -and $lineIndex -lt $WrappedLines.Count) {
            $formatted = Format-ReaderTextLine -Text ([string]$WrappedLines[$lineIndex]) -SearchQuery $SearchQuery -ActiveMatch:($lineIndex -eq $SearchLine)
            [void]$buffer.Append("$script:Escape[$row;1H$script:Escape[2K  $formatted")
        }
        else {
            [void]$buffer.Append("$script:Escape[$row;1H$script:Escape[2K")
        }
    }

    $pageCount = [Math]::Max(1, [Math]::Ceiling($DisplayRows.Count / [double]$PageSize))
    $activeWorkView = @('ACTIVITY', 'GIT', 'PROCESS', 'LOG', 'CODEX')[[int]($WorkProfileIndex % 5)]
    $searchStatus = if ($SearchCount -gt 0) { " | FIND $($SearchIndex + 1)/$SearchCount" } else { '' }
    $spacingStatus = switch ($SpacingMode) { 'Compact' { 'COMPACT' }; 'Paragraph' { 'PARA' }; default { 'RELAXED' } }
    $widthStatus = if ($script:ActiveTextWidth -eq 0) { 'AUTO' } else { [string]$script:ActiveTextWidth }
    $status = " $($Book.Encoding) | PAGE $($Page + 1)/$pageCount | COL $widthStatus | SPC $spacingStatus | $activeWorkView$searchStatus "
    $statusRow = $firstBodyRow + $PageSize + 1
    [void]$buffer.Append("$script:Escape[$statusRow;1H$script:Escape[2K$($script:Ansi.Gray)$status$($script:Ansi.Reset)")
    [Console]::Write($buffer.ToString())
}

function Request-NewPath {
    [Console]::Write("$script:Escape[2J$script:Escape[H$script:Escape[?25h")
    [Console]::Write("$($script:Ansi.Green)PS>$($script:Ansi.Reset) TXT path: ")
    $newPath = [Console]::ReadLine()
    [Console]::Write("$script:Escape[?25l")
    return $newPath
}

if (-not [string]::IsNullOrWhiteSpace($script:RequestedCodexSessionId)) {
    $script:CodexSessionId = $script:RequestedCodexSessionId
}
else {
    $savedCodexSessionId = Get-SavedCodexSessionId
    if (-not [string]::IsNullOrWhiteSpace($savedCodexSessionId)) {
        $script:CodexSessionId = $savedCodexSessionId
    }
    else {
        $script:CodexSessionId = ''
    }
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Select-BookFromLibrary
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
}

$book = Read-LocalTextFile -FilePath $Path
$readerLinesOverride = $ReaderLines -gt 0
$savedOnOpen = Get-BookProgress -Book $book
if ($readerLinesOverride) {
    $activeReaderLines = $ReaderLines
}
elseif ($null -ne $savedOnOpen -and $null -ne $savedOnOpen.PSObject.Properties['ReaderLines']) {
    $activeReaderLines = [Math]::Max(3, [Math]::Min(30, [int]$savedOnOpen.ReaderLines))
}
else {
    $activeReaderLines = 8
}
Update-LibraryEntry -Book $book -LineCount $activeReaderLines -Touch
$page = 0
$privacyMode = $false
$quit = $false
$originalTitle = [Console]::Title
$cachedWidth = 0
$wrappedLines = @()
$displayRows = @()
$lineRows = @()
$displayLayoutWidth = 0
$displayLayoutSpacing = ''
$chapters = @()
$initialPositionApplied = $false
$pendingLineIndex = -1
$lastPageSize = 0
$workProfileIndex = [Array]::IndexOf(@('ACTIVITY', 'GIT', 'PROCESS', 'LOG', 'CODEX'), $WorkView.ToUpperInvariant())
$workTick = 0
$searchQuery = ''
$searchMatches = @()
$searchIndex = -1
$searchWidth = 0
$renderMode = 'Full'
$progressDirty = $false
$progressDirtyAt = [DateTime]::MinValue
$lastProgressSignature = ''

try {
    [Console]::Title = 'Windows PowerShell'
    [Console]::Write("$script:Escape[?1049h$script:Escape[?25l")

    while (-not $quit) {
        $size = Get-SafeConsoleSize
        $visibleShortcutRows = @(Get-ReaderShortcutRows -Width $size.Width)
        $footerRowCount = 2 + $visibleShortcutRows.Count
        $contentHeight = [Math]::Max(18, $size.Height - $footerRowCount + 1)
        $maximumReaderRows = [Math]::Max(5, $contentHeight - 10)
        $readerRows = [Math]::Min($maximumReaderRows, [Math]::Max(5, $activeReaderLines + 2))
        $workRows = [Math]::Max(8, $contentHeight - $readerRows - 2)
        $pageSize = [Math]::Max(3, $readerRows - 2)
        $availableTextWidth = [Math]::Max(30, $size.Width - 4)
        $textWidth = if ($script:ActiveTextWidth -gt 0) {
            [Math]::Min($availableTextWidth, $script:ActiveTextWidth)
        }
        else {
            $availableTextWidth
        }

        $layoutProgress = -1.0
        $layoutChanged = $initialPositionApplied -and $wrappedLines.Count -gt 0 -and $displayRows.Count -gt 0 -and $lastPageSize -gt 0 -and
            ($cachedWidth -ne $textWidth -or $lastPageSize -ne $pageSize)
        if ($layoutChanged -and $pendingLineIndex -lt 0) {
            $oldLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $lastPageSize
            $layoutProgress = $oldLineIndex / [double][Math]::Max(1, $wrappedLines.Count - 1)
        }

        if ($cachedWidth -ne $textWidth -or $wrappedLines.Count -eq 0) {
            $layout = Get-BookLayout -Book $book -Width $textWidth
            $wrappedLines = @($layout.WrappedLines)
            $chapters = @($layout.Chapters)
            $cachedWidth = $textWidth
        }

        if ($displayLayoutWidth -ne $textWidth -or $displayLayoutSpacing -ne $script:ActiveSpacingMode -or $displayRows.Count -eq 0) {
            $displayLayout = New-ReaderDisplayLayout -WrappedLines $wrappedLines -Mode $script:ActiveSpacingMode
            $displayRows = @($displayLayout.Rows)
            $lineRows = @($displayLayout.LineRows)
            $displayLayoutWidth = $textWidth
            $displayLayoutSpacing = $script:ActiveSpacingMode
        }

        if (-not [string]::IsNullOrWhiteSpace($searchQuery) -and $searchWidth -ne $textWidth) {
            $currentSearchLine = [Math]::Min($wrappedLines.Count - 1, (Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize ([Math]::Max(1, $lastPageSize))))
            $searchMatches = @(Find-BookSearchMatches -WrappedLines $wrappedLines -Query $searchQuery)
            $searchIndex = 0
            for ($matchIndex = 0; $matchIndex -lt $searchMatches.Count; $matchIndex++) {
                if ($searchMatches[$matchIndex] -ge $currentSearchLine) { $searchIndex = $matchIndex; break }
            }
            $searchWidth = $textWidth
        }

        if ($layoutProgress -ge 0 -and $wrappedLines.Count -gt 0) {
            $resizedTargetLine = [Math]::Floor($layoutProgress * [Math]::Max(0, $wrappedLines.Count - 1))
            $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $resizedTargetLine -PageSize $pageSize
        }
        $pageCount = [Math]::Max(1, [Math]::Ceiling($displayRows.Count / [double]$pageSize))

        if ($pendingLineIndex -ge 0) {
            $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $pendingLineIndex -PageSize $pageSize
            $pendingLineIndex = -1
        }

        if (-not $initialPositionApplied) {
            if ($Chapter -gt 0 -and $Chapter -le $chapters.Count) {
                $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $chapters[$Chapter - 1].LineIndex -PageSize $pageSize
            }
            elseif ($Chapter -eq 0) {
                $savedProgress = Get-BookProgress -Book $book
                if ($null -ne $savedProgress) {
                    if ([int]$savedProgress.Width -eq $textWidth) {
                        $targetLine = [Math]::Min($wrappedLines.Count - 1, [int]$savedProgress.LineIndex)
                    }
                    else {
                        $targetLine = [Math]::Floor([double]$savedProgress.Progress * [Math]::Max(0, $wrappedLines.Count - 1))
                    }
                    $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $targetLine -PageSize $pageSize
                }
            }
            $initialPositionApplied = $true
        }

        $page = [Math]::Min($page, $pageCount - 1)
        $lastPageSize = $pageSize

        $activeSearchLine = if ($searchIndex -ge 0 -and $searchIndex -lt $searchMatches.Count) { [int]$searchMatches[$searchIndex] } else { -1 }
        if ($renderMode -eq 'Reader') {
            if (-not $privacyMode) {
                Show-ReaderRegion -Book $book -WrappedLines $wrappedLines -DisplayRows $displayRows -Page $page -PageSize $pageSize `
                    -WorkRows $workRows -Width $size.Width -WorkProfileIndex $workProfileIndex `
                    -SearchQuery $searchQuery -SearchIndex $searchIndex -SearchCount $searchMatches.Count -SearchLine $activeSearchLine `
                    -SpacingMode $script:ActiveSpacingMode
            }
        }
        elseif ($renderMode -eq 'Full') {
            Show-ReaderScreen -Book $book -WrappedLines $wrappedLines -DisplayRows $displayRows -Page $page -PageSize $pageSize `
                -WorkRows $workRows -Width $size.Width -ReaderLineCount $pageSize `
                -WorkProfileIndex $workProfileIndex -WorkTick $workTick `
                -WorkRoot $script:WorkRoot -WorkLog $script:WorkLog -PrivacyMode $privacyMode `
                -SearchQuery $searchQuery -SearchIndex $searchIndex -SearchCount $searchMatches.Count -SearchLine $activeSearchLine `
                -SpacingMode $script:ActiveSpacingMode
        }
        $renderMode = 'None'

        if ([string]::IsNullOrWhiteSpace($lastProgressSignature) -and $wrappedLines.Count -gt 0) {
            $signatureLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
            $lastProgressSignature = "$($book.Id)|$signatureLine|$pageSize|$textWidth"
        }

        if ($Preview) {
            break
        }

        # Stay still while idle, but redraw when the console is actually resized.
        $resizeDetected = $false
        while (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 40
            if ($progressDirty -and (([DateTime]::UtcNow - $progressDirtyAt).TotalMilliseconds -ge 1000)) {
                $progressLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                Save-BookProgress -Book $book -LineIndex $progressLine -Width $textWidth -TotalLines $wrappedLines.Count -ReaderLineCount $pageSize
                $progressDirty = $false
            }
            $currentSize = Get-SafeConsoleSize
            if ($currentSize.Width -ne $size.Width -or $currentSize.Height -ne $size.Height) {
                $resizeDetected = $true
                break
            }
        }
        if ($resizeDetected) {
            $renderMode = 'Full'
            continue
        }

        $key = [Console]::ReadKey($true)
        $keyHandled = $false
        $keyCharacter = ([string]$key.KeyChar).ToUpperInvariant()
        $renderMode = 'None'

        if ($key.KeyChar -eq '/') {
            $searchQuery = Request-BookSearch -CurrentQuery $searchQuery
            $searchMatches = if ([string]::IsNullOrWhiteSpace($searchQuery)) { @() } else { @(Find-BookSearchMatches -WrappedLines $wrappedLines -Query $searchQuery) }
            $searchIndex = if ($searchMatches.Count -gt 0) { 0 } else { -1 }
            $searchWidth = $textWidth
            if ($searchMatches.Count -gt 0) {
                $currentLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                for ($matchIndex = 0; $matchIndex -lt $searchMatches.Count; $matchIndex++) {
                    if ($searchMatches[$matchIndex] -ge $currentLine) { $searchIndex = $matchIndex; break }
                }
                $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $searchMatches[$searchIndex] -PageSize $pageSize
            }
            elseif (-not [string]::IsNullOrWhiteSpace($searchQuery)) {
                [Console]::Write("`r`n$($script:Ansi.Yellow)No matches: $searchQuery$($script:Ansi.Reset)")
                Start-Sleep -Milliseconds 900
            }
            $keyHandled = $true
            $renderMode = 'Full'
        }
        elseif ($searchMatches.Count -gt 0 -and ($keyCharacter -eq 'N' -or $key.Key -eq [ConsoleKey]::N)) {
            $searchIndex = ($searchIndex + 1) % $searchMatches.Count
            $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $searchMatches[$searchIndex] -PageSize $pageSize
            $keyHandled = $true
            $renderMode = 'Reader'
        }
        elseif ($searchMatches.Count -gt 0 -and ($keyCharacter -eq 'P' -or $key.Key -eq [ConsoleKey]::P)) {
            $searchIndex = ($searchIndex - 1 + $searchMatches.Count) % $searchMatches.Count
            $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $searchMatches[$searchIndex] -PageSize $pageSize
            $keyHandled = $true
            $renderMode = 'Reader'
        }
        elseif ($key.KeyChar -eq '[') {
            if ($chapters.Count -gt 0) {
                $visibleEndLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize -AtEnd
                $currentChapter = Get-CurrentChapterIndex -Chapters $chapters -CurrentLine $visibleEndLine
                $targetChapter = [Math]::Max(0, $currentChapter - 1)
                $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $chapters[$targetChapter].LineIndex -PageSize $pageSize
            }
            $keyHandled = $true
            $renderMode = 'Reader'
        }
        elseif ($key.KeyChar -eq ']') {
            if ($chapters.Count -gt 0) {
                $visibleEndLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize -AtEnd
                $currentChapter = Get-CurrentChapterIndex -Chapters $chapters -CurrentLine $visibleEndLine
                $targetChapter = [Math]::Min($chapters.Count - 1, $currentChapter + 1)
                $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $chapters[$targetChapter].LineIndex -PageSize $pageSize
            }
            $keyHandled = $true
            $renderMode = 'Reader'
        }

        if (-not $keyHandled) {
            switch ($key.Key) {
            'Spacebar'   { $page = [Math]::Min($pageCount - 1, $page + 1); $renderMode = 'Reader' }
            'PageDown'   { $page = [Math]::Min($pageCount - 1, $page + 1); $renderMode = 'Reader' }
            'DownArrow'  { $page = [Math]::Min($pageCount - 1, $page + 1); $renderMode = 'Reader' }
            'RightArrow' { $page = [Math]::Min($pageCount - 1, $page + 1); $renderMode = 'Reader' }
            'B'          { $page = [Math]::Max(0, $page - 1); $renderMode = 'Reader' }
            'PageUp'     { $page = [Math]::Max(0, $page - 1); $renderMode = 'Reader' }
            'UpArrow'    { $page = [Math]::Max(0, $page - 1); $renderMode = 'Reader' }
            'LeftArrow'  { $page = [Math]::Max(0, $page - 1); $renderMode = 'Reader' }
            'Add' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $activeReaderLines = [Math]::Min(30, $activeReaderLines + 1)
                $renderMode = 'Full'
            }
            'OemPlus' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $activeReaderLines = [Math]::Min(30, $activeReaderLines + 1)
                $renderMode = 'Full'
            }
            'Subtract' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $activeReaderLines = [Math]::Max(3, $activeReaderLines - 1)
                $renderMode = 'Full'
            }
            'OemMinus' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $activeReaderLines = [Math]::Max(3, $activeReaderLines - 1)
                $renderMode = 'Full'
            }
            'Home'       { $page = 0; $renderMode = 'Reader' }
            'End'        { $page = $pageCount - 1; $renderMode = 'Reader' }
            'Escape' {
                if (-not [string]::IsNullOrWhiteSpace($searchQuery)) {
                    $searchQuery = ''
                    $searchMatches = @()
                    $searchIndex = -1
                }
                else {
                    $privacyMode = -not $privacyMode
                }
                $renderMode = 'Full'
            }
            'W' {
                $workProfileIndex = ($workProfileIndex + 1) % 5
                $workTick = 0
                $renderMode = 'Full'
            }
            'R' { $workTick++; $renderMode = 'Full' }
            'T' {
                $nextColorMode = if ($script:ActiveColorMode -eq 'Dark') { 'Light' } else { 'Dark' }
                Set-ReaderColorMode -Mode $nextColorMode
                if (-not (Save-ColorMode -Mode $nextColorMode)) {
                    [Console]::WriteLine("$($script:Ansi.Yellow)Theme changed, but the saved setting could not be written.$($script:Ansi.Reset)")
                    Start-Sleep -Milliseconds 900
                }
                $renderMode = 'Full'
            }
            'I' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $nextSpacingMode = switch ($script:ActiveSpacingMode) {
                    'Compact' { 'Paragraph' }
                    'Paragraph' { 'Relaxed' }
                    default { 'Compact' }
                }
                $script:ActiveSpacingMode = $nextSpacingMode
                $displayLayoutSpacing = ''
                if (-not (Save-SpacingMode -Mode $nextSpacingMode)) {
                    [Console]::WriteLine("$($script:Ansi.Yellow)Spacing changed, but the saved setting could not be written.$($script:Ansi.Reset)")
                    Start-Sleep -Milliseconds 900
                }
                $renderMode = 'Full'
            }
            'Z' {
                $pendingLineIndex = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $nextTextWidth = switch ($script:ActiveTextWidth) {
                    72 { 88 }
                    88 { 104 }
                    104 { 0 }
                    default { 72 }
                }
                $script:ActiveTextWidth = $nextTextWidth
                if (-not (Save-TextWidth -Width $nextTextWidth)) {
                    [Console]::WriteLine("$($script:Ansi.Yellow)Text width changed, but the saved setting could not be written.$($script:Ansi.Reset)")
                    Start-Sleep -Milliseconds 900
                }
                $renderMode = 'Full'
            }
            'S' {
                $renderMode = 'Full'
                $selectedCodexSessionId = Select-CodexSession
                if (-not [string]::IsNullOrWhiteSpace($selectedCodexSessionId)) {
                    $script:CodexSessionId = $selectedCodexSessionId
                    if (-not (Save-CodexSessionId -SessionId $selectedCodexSessionId)) {
                        [Console]::WriteLine("$($script:Ansi.Yellow)Session changed, but the saved setting could not be written.$($script:Ansi.Reset)")
                        Start-Sleep -Milliseconds 1000
                    }
                    $workProfileIndex = 4
                    $workTick = 0
                }
            }
            'K' {
                $renderMode = 'Full'
                $currentLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                $bookmarkTargetLine = Request-Bookmark -Book $book -CurrentLine $currentLine -WrappedLines $wrappedLines -Chapters $chapters
                if ($bookmarkTargetLine -ge 0) {
                    $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $bookmarkTargetLine -PageSize $pageSize
                }
            }
            'C' {
                $renderMode = 'Full'
                $visibleEndLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize -AtEnd
                $selectedChapter = Request-Chapter -Chapters $chapters -CurrentLine $visibleEndLine
                if ($selectedChapter -ge 0) {
                    $page = Get-DisplayPageForSourceLine -LineRows $lineRows -LineIndex $chapters[$selectedChapter].LineIndex -PageSize $pageSize
                }
            }
            'L' {
                $renderMode = 'Full'
                $progressLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                Save-BookProgress -Book $book -LineIndex $progressLine -Width $textWidth -TotalLines $wrappedLines.Count -ReaderLineCount $pageSize
                $progressDirty = $false
                $selectedLibraryPath = Select-BookFromLibrary
                [Console]::Write("$script:Escape[?25l")
                if (-not [string]::IsNullOrWhiteSpace($selectedLibraryPath) -and
                    -not [string]::Equals($selectedLibraryPath, [string]$book.Path, [StringComparison]::OrdinalIgnoreCase)) {
                    try {
                        $book = Read-LocalTextFile -FilePath $selectedLibraryPath
                        $newSavedProgress = Get-BookProgress -Book $book
                        if (-not $readerLinesOverride -and $null -ne $newSavedProgress -and $null -ne $newSavedProgress.PSObject.Properties['ReaderLines']) {
                            $activeReaderLines = [Math]::Max(3, [Math]::Min(30, [int]$newSavedProgress.ReaderLines))
                        }
                        elseif (-not $readerLinesOverride) {
                            $activeReaderLines = 8
                        }
                        Update-LibraryEntry -Book $book -LineCount $activeReaderLines -Touch
                        $page = 0
                        $Chapter = 0
                        $initialPositionApplied = $false
                        $cachedWidth = 0
                        $wrappedLines = @()
                        $displayRows = @()
                        $lineRows = @()
                        $displayLayoutWidth = 0
                        $displayLayoutSpacing = ''
                        $chapters = @()
                        $searchQuery = ''
                        $searchMatches = @()
                        $searchIndex = -1
                        $searchWidth = 0
                        $lastProgressSignature = ''
                    }
                    catch {
                        [Console]::Write("`r`n$($script:Ansi.Yellow)$($_.Exception.Message)$($script:Ansi.Reset)")
                        Start-Sleep -Milliseconds 900
                    }
                }
            }
            'O' {
                $renderMode = 'Full'
                $progressLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
                Save-BookProgress -Book $book -LineIndex $progressLine -Width $textWidth -TotalLines $wrappedLines.Count -ReaderLineCount $pageSize
                $progressDirty = $false
                $newPath = Request-NewPath
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    try {
                        $book = Read-LocalTextFile -FilePath $newPath.Trim('"')
                        $newSavedProgress = Get-BookProgress -Book $book
                        if (-not $readerLinesOverride -and $null -ne $newSavedProgress -and $null -ne $newSavedProgress.PSObject.Properties['ReaderLines']) {
                            $activeReaderLines = [Math]::Max(3, [Math]::Min(30, [int]$newSavedProgress.ReaderLines))
                        }
                        elseif (-not $readerLinesOverride) {
                            $activeReaderLines = 8
                        }
                        Update-LibraryEntry -Book $book -LineCount $activeReaderLines -Touch
                        $page = 0
                        $Chapter = 0
                        $initialPositionApplied = $false
                        $cachedWidth = 0
                        $wrappedLines = @()
                        $displayRows = @()
                        $lineRows = @()
                        $displayLayoutWidth = 0
                        $displayLayoutSpacing = ''
                        $chapters = @()
                        $searchQuery = ''
                        $searchMatches = @()
                        $searchIndex = -1
                        $searchWidth = 0
                        $lastProgressSignature = ''
                    }
                    catch {
                        [Console]::Write("`r`n$($script:Ansi.Yellow)$($_.Exception.Message)$($script:Ansi.Reset)")
                        Start-Sleep -Milliseconds 900
                    }
                }
            }
            'Q' { $quit = $true }
            }
        }

        if ($wrappedLines.Count -gt 0) {
            $signatureLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
            $progressSignature = "$($book.Id)|$signatureLine|$pageSize|$textWidth"
            if (-not [string]::Equals($progressSignature, $lastProgressSignature, [StringComparison]::Ordinal)) {
                $lastProgressSignature = $progressSignature
                $progressDirty = $true
                $progressDirtyAt = [DateTime]::UtcNow
            }
        }
    }
}
finally {
    if ($wrappedLines.Count -gt 0) {
        $progressLine = Get-PageSourceLine -DisplayRows $displayRows -Page $page -PageSize $pageSize
        Save-BookProgress -Book $book -LineIndex $progressLine -Width $textWidth -TotalLines $wrappedLines.Count -ReaderLineCount $pageSize
    }
    [Console]::Title = $originalTitle
    [Console]::Write("$script:Escape[?25h$script:Escape[?1049l$($script:Ansi.Reset)")
}
