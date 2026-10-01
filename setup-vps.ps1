<#
.SYNOPSIS
    Sumber Makmur Jaya — VPS Deploy via SCP Upload
    Upload kode via SCP dan deploy Laravel ke VPS Hostinger.
    Database sudah dibuat di aaPanel (smj/smj).
    
    Password SSH diminta 2x (upload + deploy).
    
.USAGE
    .\setup-vps.ps1                    # Full deploy
    .\setup-vps.ps1 -SkipBuild        # Skip npm build
#>

param (
    [string]$HostingerHost = "187.53.139.230",
    [int]$HostingerPort = 22,
    [string]$HostingerUser = "root",
    [string]$HostingerPath = "/www/wwwroot/sumbermakmurjaya.store",
    [string]$Domain = "sumbermakmurjaya.store",
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

Write-Host "" 
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - VPS Deploy (SCP)               " -ForegroundColor Cyan
Write-Host "  VPS   : $HostingerHost                              " -ForegroundColor Cyan
Write-Host "  Domain: $Domain                                     " -ForegroundColor Cyan
Write-Host "  DB    : smj (sudah ada di aaPanel)                  " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 0: Build front-end assets ──────────────────────────
if (-not $SkipBuild) {
    Write-Host "[0/5] Building front-end assets locally..." -ForegroundColor Yellow
    Push-Location $ProjectRoot
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build gagal." }
        Write-Host "      OK" -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[0/5] Skip npm build." -ForegroundColor DarkGray
}

# ── Step 1: Buat tar.gz deploy ─────────────────────────────
Write-Host "[1/5] Membuat deploy package..." -ForegroundColor Yellow

$TempDir = Join-Path $ProjectRoot "_deploy_temp"
$TarPath = Join-Path $ProjectRoot "deploy-smj.tar.gz"

# Bersihkan
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
if (Test-Path $TarPath) { Remove-Item $TarPath -Force }
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# Folder production
$folders = @('app','bootstrap','config','database','lang','public','resources','routes','storage','vendor')
foreach ($folder in $folders) {
    $src = Join-Path $ProjectRoot $folder
    $dst = Join-Path $TempDir $folder
    if (Test-Path $src) {
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP `
            /XD "node_modules" ".git" ".cline" `
            /XF "*.log" ".gitkeep" | Out-Null
        Write-Host "      + $folder" -ForegroundColor DarkGray
    }
}

# File root
$rootFiles = @('.htaccess','artisan','composer.json','composer.lock')
foreach ($file in $rootFiles) {
    $src = Join-Path $ProjectRoot $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $TempDir -Force
        Write-Host "      + $file" -ForegroundColor DarkGray
    }
}

# Copy .env.production as .env
$envProd = Join-Path $ProjectRoot ".env.production"
if (Test-Path $envProd) {
    Copy-Item $envProd -Destination (Join-Path $TempDir ".env") -Force
    Write-Host "      + .env (dari .env.production)" -ForegroundColor DarkGray
} else {
    throw ".env.production tidak ditemukan!"
}

# Pastikan storage structure
$storageDirs = @(
    'storage/app/public',
    'storage/framework/cache/data',
    'storage/framework/sessions',
    'storage/framework/views',
    'storage/logs'
)
foreach ($dir in $storageDirs) {
    $fullPath = Join-Path $TempDir $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
}

# Buat tar.gz
Write-Host "      Compressing..." -ForegroundColor DarkGray
tar -czf $TarPath -C $TempDir .

$tarSizeMB = [math]::Round((Get-Item $TarPath).Length / 1MB, 2)
Write-Host "      OK - deploy-smj.tar.gz ($tarSizeMB MB)" -ForegroundColor Green

# Bersihkan temp
Remove-Item $TempDir -Recurse -Force

# ── Step 2: Upload ke VPS via SCP ──────────────────────────
Write-Host "[2/5] Uploading ke VPS via SCP..." -ForegroundColor Yellow
Write-Host "      (Masukkan password SSH - prompt ke-1)" -ForegroundColor White

scp -P $HostingerPort -o StrictHostKeyChecking=no $TarPath "${HostingerUser}@${HostingerHost}:/tmp/deploy-smj.tar.gz"

if ($LASTEXITCODE -ne 0) {
    Write-Host "      ❌ Upload gagal!" -ForegroundColor Red
    exit 1
}
Write-Host "      OK - Upload selesai." -ForegroundColor Green

# ── Step 3: SSH — Extract & Deploy ─────────────────────────
Write-Host "[3/5] Deploying di VPS..." -ForegroundColor Yellow
Write-Host "      (Masukkan password SSH - prompt ke-2)" -ForegroundColor White

$RemoteScript = @"
#!/bin/bash
set -euo pipefail

echo ''
echo '=============================================='
echo '  DEPLOYING SUMBER MAKMUR JAYA'
echo '=============================================='

# ── 1. Extract Application ───────────────────────
echo ''
echo '==> [1/5] Extracting application...'
mkdir -p '$HostingerPath'
tar -xzf /tmp/deploy-smj.tar.gz -C '$HostingerPath'
rm -f /tmp/deploy-smj.tar.gz
echo '    OK - Application extracted to $HostingerPath'

# ── 2. APP_KEY ───────────────────────────────────
echo ''
echo '==> [2/5] Checking APP_KEY...'
cd '$HostingerPath'
if ! grep -q 'APP_KEY=base64:' .env; then
    php artisan key:generate --force --no-interaction
    echo '    OK - APP_KEY generated.'
else
    echo '    OK - APP_KEY already set.'
fi

# ── 3. Database Migration & Seeding ──────────────
echo ''
echo '==> [3/5] Running migrations & seeders...'
cd '$HostingerPath'

# Test koneksi database
php artisan tinker --execute="try { DB::connection()->getPdo(); echo 'DB Connection OK'; } catch(\Exception \`$e) { echo 'DB FAIL: '.\`$e->getMessage(); exit(1); }" 2>/dev/null

if [ `$? -eq 0 ]; then
    php artisan migrate --force --no-interaction
    echo '    Migrations done.'
    php artisan db:seed --force --no-interaction 2>&1 || echo '    (Seeder note: data mungkin sudah ada)'
    echo '    OK - Database ready.'
else
    echo '    ⚠️  Database connection failed! Periksa .env'
fi

# ── 4. Optimize & Permissions ────────────────────
echo ''
echo '==> [4/5] Optimizing application...'
cd '$HostingerPath'
php artisan storage:link 2>/dev/null || true
php artisan optimize:clear --no-interaction 2>/dev/null || true
php artisan config:cache --no-interaction
php artisan route:cache --no-interaction
php artisan view:cache --no-interaction

chattr -i '$HostingerPath/.user.ini' 2>/dev/null || true
rm -f '$HostingerPath/.user.ini' 2>/dev/null || true
chattr -i '$HostingerPath/public/.user.ini' 2>/dev/null || true
rm -f '$HostingerPath/public/.user.ini' 2>/dev/null || true
chown -R www:www '$HostingerPath' 2>/dev/null || chown -R www-data:www-data '$HostingerPath' 2>/dev/null || true
chmod -R 775 '$HostingerPath/storage' '$HostingerPath/bootstrap/cache'
echo '    OK'

# ── 5. Reload Services ──────────────────────────
echo ''
echo '==> [5/5] Reloading services...'
systemctl restart php-fpm-83 2>/dev/null || /etc/init.d/php-fpm-83 restart 2>/dev/null || systemctl restart php8.3-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true
echo '    OK'

# ── Summary ──────────────────────────────────────
echo ''
echo '=============================================='
echo '  DEPLOYMENT SELESAI!'
echo '=============================================='
echo ''
echo '  Web Root : $HostingerPath'
echo '  Domain   : $Domain'
echo ''
cd '$HostingerPath'
php artisan about --no-interaction 2>/dev/null | head -20 || true
echo ''
"@

ssh -p $HostingerPort -o StrictHostKeyChecking=no "$HostingerUser@$HostingerHost" $RemoteScript

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[4/5] ✅ Deploy berhasil!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[4/5] ❌ Ada error (exit code $LASTEXITCODE)" -ForegroundColor Red
    Write-Host "      Periksa output di atas." -ForegroundColor Yellow
    exit 1
}

# ── Cleanup ─────────────────────────────────────────────────
Write-Host "[5/5] Cleanup..." -ForegroundColor Yellow
if (Test-Path $TarPath) { Remove-Item $TarPath -Force }
Write-Host "      OK" -ForegroundColor Green

# ── Selesai ─────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  DEPLOY SELESAI!                                     " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Website : https://$Domain" -ForegroundColor White
Write-Host "  VPS     : $HostingerHost" -ForegroundColor White
Write-Host "  Root    : $HostingerPath" -ForegroundColor White
Write-Host "  Database: smj (MySQL, sudah di aaPanel)" -ForegroundColor White
Write-Host ""
Write-Host "  Login Credentials:" -ForegroundColor Cyan
Write-Host "    Admin Pusat  : admin@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host "    Master       : master@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host "    Admin Cabang : admin1-5@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host ""
Write-Host "  Pastikan di aaPanel:" -ForegroundColor Cyan
Write-Host "    1. Website '$Domain' sudah dibuat" -ForegroundColor White
Write-Host "       Root: $HostingerPath/public" -ForegroundColor DarkGray
Write-Host "    2. SSL certificate aktif" -ForegroundColor White
Write-Host "    3. DNS mengarah ke $HostingerHost" -ForegroundColor White
Write-Host ""
