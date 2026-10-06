$ErrorActionPreference = "Stop"

$Version = "v3.0.1-1161-g6eb3d9bc"
$Url = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/UE4SS_$Version.zip"
$ExpectedSha256 = "938dc9901e6452cad3120280681c93a00ae12df2b259668815a150e221a35563"

$InstallerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload = Join-Path $InstallerDir "payload"
$ZipPath = Join-Path $Payload "ue4ss.zip"
$ExtractPath = Join-Path $Payload "ue4ss"

New-Item -ItemType Directory -Force -Path $Payload | Out-Null
Remove-Item -Recurse -Force $ExtractPath -ErrorAction SilentlyContinue
Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue

Write-Host "Downloading pinned UE4SS build $Version..."
Invoke-WebRequest -Uri $Url -OutFile $ZipPath

$Actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $ExpectedSha256) {
    throw "UE4SS checksum mismatch. Expected $ExpectedSha256 but got $Actual"
}

Write-Host "UE4SS checksum verified."
Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

if (-not (Test-Path (Join-Path $ExtractPath "dwmapi.dll"))) {
    throw "UE4SS payload is missing dwmapi.dll"
}
if (-not (Test-Path (Join-Path $ExtractPath "ue4ss\UE4SS.dll"))) {
    throw "UE4SS payload is missing ue4ss\UE4SS.dll"
}

Write-Host "UE4SS payload ready."
