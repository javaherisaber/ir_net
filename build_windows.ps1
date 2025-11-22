# Script to update version in Inno Setup, build Flutter Windows, and compile Installer

$ErrorActionPreference = "Stop"

$pubspecFile = "$PSScriptRoot\pubspec.yaml"
$issFile = "$PSScriptRoot\inno\Inno installer script.iss"

# Check if files exist
if (-not (Test-Path $pubspecFile)) {
    Write-Error "pubspec.yaml not found at $pubspecFile"
    exit 1
}
if (-not (Test-Path $issFile)) {
    Write-Error "Inno Setup script not found at $issFile"
    exit 1
}

# Read version name from pubspec.yaml
Write-Host "Reading version from pubspec.yaml..."
$versionName = $null
Get-Content -Path $pubspecFile | ForEach-Object {
    if ($_ -match "^version:\s+([^\s\+]+)") {
        $versionName = $matches[1]
    }
}

if ($versionName) {
    Write-Host "Found version name: $versionName"
} else {
    Write-Error "Could not find version in $pubspecFile"
    exit 1
}

# Update Inno Setup script
Write-Host "Updating Inno Setup script..."
$issContent = Get-Content -Path $issFile
$foundVersion = $false
$foundOutput = $false

$newIssContent = $issContent | ForEach-Object {
    if ($_ -match '^#define MyAppVersion ".*"') {
        $foundVersion = $true
        '#define MyAppVersion "{0}"' -f $versionName
    } elseif ($_ -match '^OutputBaseFilename=IRNet_windows_setup.*') {
        $foundOutput = $true
        'OutputBaseFilename=IRNet_windows_setup_{0}' -f $versionName
    } else {
        $_
    }
}

if ($foundVersion) {
    $newIssContent | Set-Content -Path $issFile
    Write-Host "Updated MyAppVersion to $versionName in $issFile"
} else {
    Write-Warning "Could not find '#define MyAppVersion' in $issFile. Version not updated."
}

if ($foundOutput) {
    Write-Host "Updated OutputBaseFilename to include version $versionName in $issFile"
} else {
    Write-Warning "Could not find 'OutputBaseFilename=IRNet_windows_setup...' in $issFile. Filename not updated."
}

# Run flutter build
Write-Host "Running flutter build windows..."
flutter build windows

if ($LASTEXITCODE -ne 0) {
    Write-Error "Flutter build failed."
    exit $LASTEXITCODE
}

# Find ISCC.exe
$isccPath = "ISCC.exe"
if (-not (Get-Command $isccPath -ErrorAction SilentlyContinue)) {
    $possiblePaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
    )
    
    $foundIscc = $false
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $isccPath = $path
            $foundIscc = $true
            break
        }
    }
    
    if (-not $foundIscc) {
        Write-Error "ISCC.exe not found in PATH or standard locations. Please add Inno Setup to PATH."
        exit 1
    }
}

# Compile Installer
Write-Host "Compiling Installer using $isccPath..."
& $isccPath $issFile

if ($LASTEXITCODE -eq 0) {
    Write-Host "Installer compilation completed successfully."
} else {
    Write-Error "Installer compilation failed."
    exit $LASTEXITCODE
}
