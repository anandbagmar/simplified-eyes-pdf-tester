$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
Usage:
  .\run-imagetester.ps1 [-Config <config-file>] [--dry-run] -f <path>

Script options:
  -Config, -c   Path to the properties file.
  -f            Path to the target folder or file.
  -Help         Show this help.

Notes:
  - All ImageTester options other than -f are read from the properties file.
  - apiKey is read from the properties file or APPLITOOLS_API_KEY.
  - serverUrl and proxy are optional in the properties file.
  - -os is auto-set to Windows, Linux, or Mac OSX.
  - -ap is always sent as pdf.
  - --dry-run shows the resolved Java command and exits.
"@
}

$Config = Join-Path $PSScriptRoot "config/imagetester.properties"
$DryRun = $false
$TargetPath = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "-c" {
            if (($i + 1) -ge $args.Count) {
                throw "Missing value for -c"
            }
            $i++
            $Config = $args[$i]
        }
        "--config" {
            if (($i + 1) -ge $args.Count) {
                throw "Missing value for --config"
            }
            $i++
            $Config = $args[$i]
        }
        "-f" {
            if (($i + 1) -ge $args.Count) {
                throw "Missing value for -f"
            }
            $i++
            $TargetPath = $args[$i]
        }
        "--dry-run" {
            $DryRun = $true
        }
        "-h" {
            Show-Usage
            exit 0
        }
        "--help" {
            Show-Usage
            exit 0
        }
        default {
            throw "Unsupported argument: $($args[$i]). Only -f, --dry-run, -c/--config, and -h/--help are supported."
        }
    }
}

function Read-Properties {
    param([string]$Path)

    $properties = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Properties file not found: $Path"
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed -split "=", 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim().Trim("'`"")
            $properties[$key] = $value
        }
    }

    return $properties
}

function Test-TrueValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "true" { return $true }
        "yes" { return $true }
        "1" { return $true }
        "y" { return $true }
        default { return $false }
    }
}

function Write-Field {
    param(
        [string]$Label,
        [string]$Value
    )

    Write-Host ("  {0,-13} : {1}" -f $Label, $Value)
}

function Add-AccessibilityArgs {
    param(
        [string]$AccessibilityValue,
        [System.Collections.Generic.List[string]]$ArgsList
    )

    if ([string]::IsNullOrWhiteSpace($AccessibilityValue)) {
        return
    }

    $normalized = $AccessibilityValue.Trim().Replace(";", ":")
    if ($normalized.Contains(":")) {
        $parts = $normalized.Split(":", 2)
        $level = $parts[0].Trim()
        $version = $parts[1].Trim()

        [void]$ArgsList.Add("-ac")
        if ($level) {
            [void]$ArgsList.Add($level)
        }
        if ($version) {
            [void]$ArgsList.Add($version)
        }
        return
    }

    [void]$ArgsList.Add("-ac")
    [void]$ArgsList.Add($normalized)
}

function Get-HostOsName {
    if ($IsWindows) { return "Windows" }
    if ($IsMacOS) { return "Mac OSX" }
    return "Linux"
}

function Get-AssetPattern {
    if ($IsWindows) {
        return "ImageTester_*_Windows.jar"
    }

    if ($IsMacOS) {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        if ($arch -eq "Arm64") {
            return "ImageTester_*_MacArm.jar"
        }
        return "ImageTester_*_Mac.jar"
    }

    return "ImageTester_*_Linux.jar"
}

function Get-ExistingJar {
    param([string]$JarsDir)

    if (-not (Test-Path -LiteralPath $JarsDir)) {
        New-Item -ItemType Directory -Path $JarsDir | Out-Null
    }

    $platformJar = Get-ChildItem -LiteralPath $JarsDir -Filter (Get-AssetPattern) -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -Last 1

    if ($platformJar) {
        return $platformJar.FullName
    }

    $fallbackJar = Get-ChildItem -LiteralPath $JarsDir -Filter "ImageTester*.jar" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -Last 1

    if ($fallbackJar) {
        return $fallbackJar.FullName
    }

    return $null
}

function Download-LatestJar {
    param([string]$JarsDir)

    if (-not (Test-Path -LiteralPath $JarsDir)) {
        New-Item -ItemType Directory -Path $JarsDir | Out-Null
    }

    $apiUrl = "https://api.github.com/repos/applitools/ImageTester/releases/latest"
    Write-Host "No ImageTester jar found in $JarsDir"
    Write-Host "Fetching latest release metadata from GitHub..."
    $release = Invoke-RestMethod -Uri $apiUrl

    $assetPattern = Get-AssetPattern
    $asset = $release.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1

    if (-not $asset) {
        throw "Could not locate a downloadable jar for pattern $(Get-AssetPattern)"
    }

    $outputPath = Join-Path $JarsDir $asset.name
    Write-Host "Downloading $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $outputPath
    return $outputPath
}

function Resolve-JarPath {
    param([string]$JarsDir)

    $existing = Get-ExistingJar -JarsDir $JarsDir
    if ($existing) {
        return $existing
    }

    return Download-LatestJar -JarsDir $JarsDir
}

function Get-SummaryStatus {
    param([string]$LogPath)

    $content = Get-Content -LiteralPath $LogPath -Raw

    if ($content -match "(?i)unresolved|mismatch|different|failed") {
        return "Differences detected or a failure was reported"
    }

    if ($content -match "(?i)new test|new baseline|created baseline") {
        return "A new baseline or test was created"
    }

    if ($content -match "(?i)passed|completed successfully|saved") {
        return "Completed successfully"
    }

    return "Execution finished. Review the detailed log below"
}

function Get-ResultDetails {
    param([string]$LogPath)

    $lines = Get-Content -LiteralPath $LogPath
    $results = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\[(?<status>Unresolved|Passed|Failed|New|Aborted)\]') {
            $status = $Matches["status"]
            $testName = if ($line -match 'test name:\s*([^,]+)') { $Matches[1].Trim() } else { "" }
            $steps = if ($line -match 'steps:\s*(\d+)') { $Matches[1] } else { "0" }
            $matchesCount = if ($line -match 'matches:\s*(\d+)') { $Matches[1] } else { "0" }
            $mismatches = if ($line -match 'mismatches:\s*(\d+)') { $Matches[1] } else { "0" }
            $missing = if ($line -match 'missing:\s*(\d+)') { $Matches[1] } else { "0" }
            $url = if ($line -match 'URL:\s*(https://\S+)') { $Matches[1] } else { "" }

            $results.Add("Result    : $status")
            $results.Add("Test      : $testName")
            $results.Add("Steps     : $steps total, $matchesCount matches, $mismatches mismatches, $missing missing")

            if (($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^Accessibility:') {
                $accessibilityLine = $lines[$i + 1]
                $accessibilityStatus = if ($accessibilityLine -match "AccessibilityStatus{name='([^']+)'}") { $Matches[1] } else { "" }
                $accessibilityLevel = if ($accessibilityLine -match "AccessibilityLevel{name='([^']+)'}") { $Matches[1] } else { "" }
                $accessibilityVersion = if ($accessibilityLine -match "AccessibilityGuidelinesVersion{name='([^']+)'}") { $Matches[1] } else { "" }
                if ($accessibilityStatus) {
                    $results.Add("Accessib. : $accessibilityStatus ($accessibilityLevel, $accessibilityVersion)")
                }
            }

            if ($url) {
                $results.Add("URL       : $url")
            }
            $results.Add("---")
        }
    }

    return $results
}

function Filter-LiveOutput {
    param([string[]]$Lines)

    $skipNextWarning = $false

    foreach ($line in $Lines) {
        if ($line -match '^\[(Unresolved|Passed|Failed|New|Aborted)\]') {
            continue
        }

        if ($line -match '^Accessibility:') {
            continue
        }

        if ($line -match '^\[\d+/\d+\]\s*$') {
            continue
        }

        if ($line -match '^SLF4J\(W\):') {
            continue
        }

        if ($line -match '^[A-Z][a-z]{2} \d{1,2}, \d{4} .* org\.apache\.pdfbox\.') {
            $skipNextWarning = $true
            continue
        }

        if ($skipNextWarning -and $line -match '^WARNING:') {
            $skipNextWarning = $false
            continue
        }

        $skipNextWarning = $false
        Write-Host $line
    }
}

$rootDir = $PSScriptRoot
$jarsDir = Join-Path $rootDir "jars"
$logsDir = Join-Path $rootDir "logs"

if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "Java is not installed or not available on PATH."
}

$properties = Read-Properties -Path $Config
$apiKey = $properties["apiKey"]
$serverUrl = $properties["serverUrl"]
$proxy = $properties["proxy"]
$appName = $properties["appName"]
$matchLevel = $properties["matchLevel"]
$ignoreDisplacements = $properties["ignoreDisplacements"]
$accessibility = $properties["accessibility"]
$ignoreRegions = $properties["ignoreRegions"]
$contentRegions = $properties["contentRegions"]
$layoutRegions = $properties["layoutRegions"]

if (-not $apiKey -and $env:APPLITOOLS_API_KEY) {
    $apiKey = $env:APPLITOOLS_API_KEY
}

if (-not $apiKey) {
    throw "Applitools apiKey is mandatory. Provide it in $Config using apiKey=YOUR_KEY or set APPLITOOLS_API_KEY."
}

if (-not $TargetPath) {
    throw "Target path is mandatory. Run the script with -f <path-to-pdf-folder-or-file>."
}

$jarPath = Resolve-JarPath -JarsDir $jarsDir
$hostOs = Get-HostOsName
$runArgs = New-Object System.Collections.Generic.List[string]

[void]$runArgs.Add("-f")
[void]$runArgs.Add($TargetPath)
[void]$runArgs.Add("-k")
[void]$runArgs.Add($apiKey)

if ($appName) {
    [void]$runArgs.Add("-a")
    [void]$runArgs.Add($appName)
}

if ($matchLevel -and $matchLevel -ne "Strict") {
    [void]$runArgs.Add("-ml")
    [void]$runArgs.Add($matchLevel)
}

if (Test-TrueValue -Value $ignoreDisplacements) {
    [void]$runArgs.Add("-id")
}

if ($accessibility) {
    Add-AccessibilityArgs -AccessibilityValue $accessibility -ArgsList $runArgs
}

if ($ignoreRegions) {
    [void]$runArgs.Add("-ir")
    [void]$runArgs.Add($ignoreRegions)
}

if ($contentRegions) {
    [void]$runArgs.Add("-cr")
    [void]$runArgs.Add($contentRegions)
}

if ($layoutRegions) {
    [void]$runArgs.Add("-lr")
    [void]$runArgs.Add($layoutRegions)
}

if ($serverUrl) {
    [void]$runArgs.Add("-s")
    [void]$runArgs.Add($serverUrl)
}

if ($proxy) {
    [void]$runArgs.Add("-p")
    [void]$runArgs.Add($proxy)
}

[void]$runArgs.Add("-os")
[void]$runArgs.Add($hostOs)
[void]$runArgs.Add("-ap")
[void]$runArgs.Add("pdf")

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logsDir "imagetester-$timestamp.log"

Write-Host ""
Write-Host "========================================"
Write-Host "Applitools ImageTester PDF Runner"
Write-Host "========================================"
Write-Field "Jar" $jarPath
Write-Field "Config" $Config
Write-Field "Target" $TargetPath
Write-Field "Host OS" $hostOs
Write-Field "Host App" "pdf"
Write-Field "App Name" $(if ($appName) { $appName } else { 'ImageTester' })
$resolvedMatchLevel = if ($matchLevel) { $matchLevel } else { "Strict" }
$matchLevelSuffix = if (-not $matchLevel -or $matchLevel -eq "Strict") { " (default)" } else { "" }
Write-Field "Match Level" "$resolvedMatchLevel$matchLevelSuffix"
Write-Field "Accessibility" $(if ($accessibility) { $accessibility } else { 'disabled' })
Write-Field "Log File" $logPath
$quotedArgs = @("java", "-jar", $jarPath) + $runArgs.ToArray() | ForEach-Object {
    if ($_ -match '[\s"]') {
        '"' + ($_ -replace '"', '\"') + '"'
    } else {
        $_
    }
}
Write-Field "Command" ($quotedArgs -join ' ')
Write-Host "========================================"
Write-Host ""

if ($DryRun) {
    Write-Host "Dry Run    : enabled"
    exit 0
}

& java -jar $jarPath @runArgs 2>&1 | Tee-Object -FilePath $logPath | ForEach-Object { $_.ToString() } | Tee-Object -Variable formattedLines | Out-Null
Filter-LiveOutput -Lines $formattedLines
$exitCode = $LASTEXITCODE

$dashboardUrl = Select-String -LiteralPath $logPath -Pattern 'https://\S+' -AllMatches |
    ForEach-Object { $_.Matches.Value } |
    Select-Object -Last 1

$summaryStatus = Get-SummaryStatus -LogPath $logPath
$resultDetails = Get-ResultDetails -LogPath $logPath

if ($resultDetails.Count -gt 0) {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Applitools Results"
    Write-Host "========================================"
    $detailsToPrint = $resultDetails
    if ($detailsToPrint[$detailsToPrint.Count - 1] -eq "---") {
        $detailsToPrint = $detailsToPrint[0..($detailsToPrint.Count - 2)]
    }
    $detailsToPrint | ForEach-Object { Write-Host $_ }
    Write-Host "========================================"
}

Write-Host ""
Write-Host "========================================"
Write-Host "Execution Summary"
Write-Host "========================================"
Write-Host "Status     : $summaryStatus"
Write-Host "Exit Code  : $exitCode"
if ($dashboardUrl) {
    Write-Host "Dashboard  : $dashboardUrl"
}
Write-Host "Detailed Log: $logPath"
Write-Host "========================================"

exit $exitCode
