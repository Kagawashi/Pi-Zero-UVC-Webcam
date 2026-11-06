# Pupil Capture için Pi Zero UVC Eklentisi Otomatik Kurulum Betiği
[CmdletBinding()]
param()

$pluginDir = "$env:USERPROFILE\pupil_capture_settings\plugins"
if (-not (Test-Path $pluginDir)) {
    Write-Host "[*] Eklenti klasörü oluşturuluyor: $pluginDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
}

$sourceFile = Join-Path $PSScriptRoot "pi_zero_uvc_patch.py"
$destFile = Join-Path $pluginDir "pi_zero_uvc_patch.py"

if (Test-Path $sourceFile) {
    Copy-Item $sourceFile $destFile -Force
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "[OK] Pi Zero UVC Eklentisi Başarıyla Kuruldu!" -ForegroundColor Green
    Write-Host "     Hedef: $destFile" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "Artık Pupil Capture uygulamasını açabilirsiniz:" -ForegroundColor Yellow
    Write-Host "Eye 0 penceresinde 'Pi Zero Kamera Ayarları' menüsü görünecektir." -ForegroundColor White
} else {
    Write-Error "Kaynak eklenti dosyası bulunamadı: $sourceFile"
}

