param(
    [switch]$BuildOnly
)

$pubspecPath = Join-Path $PSScriptRoot "..\pubspec.yaml"
$pubspecPath = [System.IO.Path]::GetFullPath($pubspecPath)

if (-not (Test-Path -LiteralPath $pubspecPath)) {
    throw "pubspec.yaml tidak ditemukan di $pubspecPath"
}

$content = Get-Content -LiteralPath $pubspecPath
$versionLineIndex = -1

for ($i = 0; $i -lt $content.Length; $i++) {
    if ($content[$i] -match '^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$') {
        $versionLineIndex = $i
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $patch = [int]$Matches[3]
        $build = [int]$Matches[4]
        break
    }
}

if ($versionLineIndex -lt 0) {
    throw "Baris version tidak ditemukan atau formatnya tidak sesuai."
}

if ($BuildOnly) {
    $build += 1
} else {
    $patch += 1
    $build += 1
}

$newVersion = "$major.$minor.$patch+$build"
$content[$versionLineIndex] = "version: $newVersion"
Set-Content -LiteralPath $pubspecPath -Value $content

Write-Output "Version updated to $newVersion"
