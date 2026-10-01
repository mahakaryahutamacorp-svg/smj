<#
.SYNOPSIS
    Sumber Makmur Jaya — Quick Deploy ke VPS Hostinger
    Digunakan setelah initial setup sudah dilakukan.
    Upload via SCP, composer install, migrate, optimize.
.USAGE
    .\deploy-direct.ps1
    .\deploy-direct.ps1 -SkipBuild     # Skip npm build
#>

param (
    [string]$HostingerHost = "187.53.139.230",
    [int]$HostingerPort = 22,
    [string]$HostingerUser = "root",
    [string]$HostingerPath = "/www/wwwroot/sumbermakmurjaya.store",
    [string]$SshKeyPath = "",
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - Quick VPS Deployment (SCP)     " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# SSH args helper
$SshArgs = @("-p", $HostingerPort, "-o", "StrictHostKeyChecking=no")
$ScpArgs = @("-P", $HostingerPort, "-o", "StrictHostKeyChecking=no")
if ($SshKeyPath -ne "" -and (Test-Path $SshKeyPath)) {
    $SshArgs = @("-i", $SshKeyPath) + $SshArgs
    $ScpArgs = @("-i", $SshKeyPath) + $ScpArgs
}
$SshTarget = "$HostingerUser@$HostingerHost"

# ── Step 1: Build assets ───────────────────────────────────
if (-not $SkipBuild) {
    Write-Host "[1/5] Building front-end assets..." -ForegroundColor Yellow
    Push-Location $ProjectRoot
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build gagal." }
        Write-Host "      OK" -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[1/5] Skip npm build." -ForegroundColor DarkGray
}

# ── Step 2: Buat tar.gz deploy ─────────────────────────────
Write-Host "[2/5] Membuat deploy package..." -ForegroundColor Yellow

$TempDir = Join-Path $ProjectRoot "_deploy_temp"
$TarPath = Join-Path $ProjectRoot "deploy-smj.tar.gz"

if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
if (Test-Path $TarPath) { Remove-Item $TarPath -Force }
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# Folder production (tanpa vendor untuk update cepat)
$folders = @('app','bootstrap','config','database','lang','public','resources','routes','storage')
foreach ($folder in $folders) {
    $src = Join-Path $ProjectRoot $folder
    $dst = Join-Path $TempDir $folder
    if (Test-Path $src) {
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP `
            /XD "node_modules" ".git" ".cline" `
            /XF "*.log" ".gitkeep" | Out-Null
    }
}

# File root
foreach ($file in @('.htaccess','artisan','composer.json','composer.lock')) {
    $src = Join-Path $ProjectRoot $file
    if (Test-Path $src) { Copy-Item $src -Destination $TempDir -Force }
}

# .env.production -> .env
$envProd = Join-Path $ProjectRoot ".env.production"
if (Test-Path $envProd) {
    Copy-Item $envProd -Destination (Join-Path $TempDir ".env") -Force
}

# Compress
tar -czf $TarPath -C $TempDir .
$tarSizeMB = [math]::Round((Get-Item $TarPath).Length / 1MB, 2)
Write-Host "      OK - deploy-smj.tar.gz ($tarSizeMB MB)" -ForegroundColor Green
Remove-Item $TempDir -Recurse -Force

# ── Step 3: Upload via SCP ─────────────────────────────────
Write-Host "[3/5] Uploading ke VPS..." -ForegroundColor Yellow
Write-Host "      (Masukkan password SSH - prompt ke-1)" -ForegroundColor White

scp @ScpArgs $TarPath "${SshTarget}:/tmp/deploy-smj.tar.gz"
if ($LASTEXITCODE -ne 0) {
    Write-Host "      ❌ Upload gagal!" -ForegroundColor Red; exit 1
}
Write-Host "      OK" -ForegroundColor Green

# ── Step 4: SSH deploy ─────────────────────────────────────
Write-Host "[4/5] Deploying di VPS..." -ForegroundColor Yellow
Write-Host "      (Masukkan password SSH - prompt ke-2)" -ForegroundColor White

$RemoteCommand = @"
set -euo pipefail
echo '==> 1. Extracting update...'
cd '$HostingerPath'
tar -xzf /tmp/deploy-smj.tar.gz -C '$HostingerPath'
rm -f /tmp/deploy-smj.tar.gz

echo '==> 2. Installing Composer dependencies...'
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

echo '==> 3. Running database migrations...'
php artisan migrate --force --no-interaction

echo '==> 4. Clearing and optimizing caches...'
php artisan optimize:clear --no-interaction 2>/dev/null || true
php artisan config:cache --no-interaction
php artisan route:cache --no-interaction
php artisan view:cache --no-interaction

echo '==> 5. Setting permissions, removing open_basedir lock & reloading...'
chattr -i '$HostingerPath/.user.ini' 2>/dev/null || true
rm -f '$HostingerPath/.user.ini' 2>/dev/null || true
chattr -i '$HostingerPath/public/.user.ini' 2>/dev/null || true
rm -f '$HostingerPath/public/.user.ini' 2>/dev/null || true
chown -R www:www '$HostingerPath' 2>/dev/null || chown -R www-data:www-data '$HostingerPath' 2>/dev/null || true
chmod -R 775 storage bootstrap/cache
systemctl restart php-fpm-83 2>/dev/null || /etc/init.d/php-fpm-83 restart 2>/dev/null || systemctl restart php8.3-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true

echo '==> Deployment finished!'
php artisan about --no-interaction 2>/dev/null | head -12 || true
"@

ssh @SshArgs $SshTarget $RemoteCommand

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[5/5] ✅ Deployment berhasil! https://sumbermakmurjaya.store" -ForegroundColor Green
} else {
    Write-Host "`n[5/5] ❌ Deployment gagal (exit $LASTEXITCODE)" -ForegroundColor Red
}

# Cleanup
if (Test-Path $TarPath) { Remove-Item $TarPath -Force }
