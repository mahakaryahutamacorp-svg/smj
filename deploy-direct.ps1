<#
.SYNOPSIS
    Sumber Makmur Jaya — Quick Deploy ke VPS Hostinger
    Digunakan setelah initial setup sudah dilakukan.
    Git pull, composer install, migrate, optimize.
.USAGE
    .\deploy-direct.ps1
#>

param (
    [string]$HostingerHost = "187.53.139.230",
    [int]$HostingerPort = 22,
    [string]$HostingerUser = "root",
    [string]$HostingerPath = "/www/wwwroot/sumbermakmurjaya.store",
    [string]$SshKeyPath = ""
)

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - Quick VPS Deployment           " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# Build assets locally first
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

Write-Host "[1/4] Building front-end assets..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build gagal." }
} finally {
    Pop-Location
}

# Push to GitHub
Write-Host "[2/4] Pushing to GitHub..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
    git add -A
    $hasChanges = (git status --porcelain) -ne ""
    if ($hasChanges) {
        git commit -m "deploy: SMJ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }
    git push origin main
} catch {
    Write-Host "      Warning: $_" -ForegroundColor DarkYellow
} finally {
    Pop-Location
}

# SSH deploy
Write-Host "[3/4] Deploying to VPS..." -ForegroundColor Yellow

$SshArgs = @("-p", $HostingerPort, "-o", "StrictHostKeyChecking=no")
if ($SshKeyPath -ne "" -and (Test-Path $SshKeyPath)) {
    $SshArgs = @("-i", $SshKeyPath) + $SshArgs
}

$RemoteCommand = @"
set -euo pipefail
echo '==> 1. Pulling latest code...'
cd '$HostingerPath'
git checkout -- .
git pull origin main

echo '==> 2. Installing Composer dependencies...'
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

echo '==> 3. Running database migrations...'
php artisan migrate --force

echo '==> 4. Clearing and optimizing caches...'
php artisan optimize:clear
php artisan config:cache
php artisan route:cache
php artisan view:cache

echo '==> 5. Setting file permissions...'
chown -R www:www .
chmod -R 775 storage bootstrap/cache

echo '==> 6. Reloading services...'
systemctl reload php-fpm-83 2>/dev/null || /etc/init.d/php-fpm-83 reload 2>/dev/null || true
systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true

echo '==> Deployment finished!'
php artisan about --no-interaction | head -n 12
"@

ssh @SshArgs "$HostingerUser@$HostingerHost" $RemoteCommand

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[4/4] ✅ Deployment berhasil! Website aktif di https://sumbermakmurjaya.store" -ForegroundColor Green
} else {
    Write-Host "`n[4/4] ❌ Deployment gagal dengan exit code $LASTEXITCODE" -ForegroundColor Red
}
