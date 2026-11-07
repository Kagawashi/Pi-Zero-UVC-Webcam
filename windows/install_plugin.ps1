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

    $drvInst = "C:\Program Files (x86)\Pupil-Labs\Pupil v3.5.1\Pupil Capture v3.5.1\PupilDrvInst.exe"
    if (Test-Path $drvInst) {
        $roles = @(
            @{ Pid = 37424; Desc = "Pupil Cam1 ID0" },
            @{ Pid = 37425; Desc = "Pupil Cam1 ID1" },
            @{ Pid = 37426; Desc = "Pupil Cam1 ID2" }
        )
        foreach ($r in $roles) {
            & $drvInst --vid 1443 --pid $r.Pid | Out-Null
            if ($LASTEXITCODE -eq 2) {
                Write-Host "[*] Takılı olan '$($r.Desc)' (PID: $($r.Pid)) için libusbK sürücüsü kuruluyor (Yönetici izni onaylayın)..." -ForegroundColor Yellow
                $tmpDir = Join-Path $env:TEMP ("pupil_drv_" + $r.Pid)
                New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                Start-Process -FilePath $drvInst -WorkingDirectory $tmpDir -ArgumentList "--vid 1443 --pid $($r.Pid) --desc `"$($r.Desc)`" --vendor `"Pupil Labs`" --inst" -Verb RunAs -Wait
            }
        }
    }

    Write-Host "Artık Pupil Capture uygulamasını açabilirsiniz:" -ForegroundColor Yellow
    Write-Host "Eye 0 / Eye 1 / World penceresinde 'Pi Zero Kamera Ayarları' menüsü görünecektir." -ForegroundColor White
} else {
    Write-Error "Kaynak eklenti dosyası bulunamadı: $sourceFile"
}

