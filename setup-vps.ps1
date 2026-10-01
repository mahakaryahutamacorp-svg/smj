<#
.SYNOPSIS
    Sumber Makmur Jaya — Full VPS Setup & Deploy (Single SSH Session)
    Setup database MySQL, Nginx vhost, clone repo, dan deploy aplikasi Laravel
    ke VPS Hostinger yang sama dengan Maju Bersama Online.
    
    PENTING: Script ini hanya memerlukan 1x input password SSH!
    
.USAGE
    .\setup-vps.ps1                    # Full setup + deploy
    .\setup-vps.ps1 -SkipBuild        # Skip npm build (jika sudah build)
#>

param (
    [string]$HostingerHost = "187.53.139.230",
    [int]$HostingerPort = 22,
    [string]$HostingerUser = "root",
    [string]$HostingerPath = "/www/wwwroot/sumbermakmurjaya.store",
    [string]$GitRepo = "https://github.com/mahakaryahutamacorp-svg/smj.git",
    [string]$GitBranch = "main",
    [string]$DbName = "smj_pos",
    [string]$DbUser = "smj_user",
    [string]$DbPassword = "SmjP0s2026!Secure",
    [string]$Domain = "sumbermakmurjaya.store",
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

Write-Host "" 
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - VPS Setup & Deploy             " -ForegroundColor Cyan
Write-Host "  VPS   : $HostingerHost                              " -ForegroundColor Cyan
Write-Host "  Domain: $Domain                                     " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 0: Build front-end assets locally ──────────────────
if (-not $SkipBuild) {
    Write-Host "[0/4] Building front-end assets locally..." -ForegroundColor Yellow
    Push-Location $ProjectRoot
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build gagal." }
        Write-Host "      OK - Front-end assets berhasil di-build." -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[0/4] Skipping npm build..." -ForegroundColor DarkGray
}

# ── Step 1: Push latest code ke GitHub ──────────────────────
Write-Host "[1/4] Pushing latest code ke GitHub..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
    git add -A
    $hasChanges = (git status --porcelain) -ne ""
    if ($hasChanges) {
        git commit -m "deploy: SMJ production $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }
    git push origin $GitBranch 2>&1 | Out-Null
    Write-Host "      OK - Code pushed ke GitHub." -ForegroundColor Green
} catch {
    Write-Host "      Warning: $_" -ForegroundColor DarkYellow
} finally {
    Pop-Location
}

# ── Step 2: Baca .env.production untuk dikirim ke VPS ──────
$EnvFile = Join-Path $ProjectRoot ".env.production"
if (-not (Test-Path $EnvFile)) {
    throw ".env.production tidak ditemukan! Jalankan dulu dari direktori project."
}
$EnvContent = (Get-Content $EnvFile -Raw) -replace "`r`n", "`n"

# ── Step 3: SINGLE SSH SESSION — Setup Everything ──────────
Write-Host ""
Write-Host "[2/4] Connecting ke VPS (1x SSH session)..." -ForegroundColor Yellow
Write-Host "      Masukkan password SSH saat diminta." -ForegroundColor White
Write-Host ""

# Gabungkan semua command jadi 1 remote script
$RemoteScript = @"
#!/bin/bash
set -euo pipefail

echo ''
echo '=============================================='
echo '  STARTING VPS SETUP FOR SUMBER MAKMUR JAYA'
echo '=============================================='
echo ''

# ── 1. MySQL Database Setup ───────────────────────
echo '==> [STEP 1/7] Setting up MySQL database...'
if command -v mysql &> /dev/null; then
    echo '    MySQL/MariaDB found.'
else
    echo '    MySQL not found! Please install MySQL/MariaDB first.'
    exit 1
fi

mysql -u root -e "
CREATE DATABASE IF NOT EXISTS \`$DbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';
GRANT ALL PRIVILEGES ON \`$DbName\`.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
" 2>/dev/null && echo '    OK - Database dan user berhasil dibuat.' || {
    echo '    Trying with socket auth...'
    mysql -e "
    CREATE DATABASE IF NOT EXISTS \`$DbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';
    GRANT ALL PRIVILEGES ON \`$DbName\`.* TO '$DbUser'@'localhost';
    FLUSH PRIVILEGES;
    " && echo '    OK - Database dan user berhasil dibuat.'
}

# ── 2. Clone Repository ──────────────────────────
echo ''
echo '==> [STEP 2/7] Setting up application directory...'
mkdir -p '$HostingerPath'

if [ -d '$HostingerPath/.git' ]; then
    echo '    Git repo exists, pulling latest...'
    cd '$HostingerPath'
    git checkout -- . 2>/dev/null || true
    git pull origin $GitBranch
else
    echo '    Cloning repository...'
    git clone -b $GitBranch '$GitRepo' '$HostingerPath'
    cd '$HostingerPath'
fi
echo '    OK - Repository ready.'

# ── 3. Setup .env Production ─────────────────────
echo ''
echo '==> [STEP 3/7] Setting up .env production...'
cat > '$HostingerPath/.env' << 'ENVEOF'
$EnvContent
ENVEOF

# Generate APP_KEY if needed
if ! grep -q 'APP_KEY=base64:' '$HostingerPath/.env'; then
    cd '$HostingerPath'
    php artisan key:generate --force --no-interaction
fi
echo '    OK - .env production configured.'

# ── 4. Composer Install ──────────────────────────
echo ''
echo '==> [STEP 4/7] Installing Composer dependencies...'
cd '$HostingerPath'
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction 2>&1 | tail -5
echo '    OK - Composer dependencies installed.'

# ── 5. Database Migration & Seeding ──────────────
echo ''
echo '==> [STEP 5/7] Running database migrations & seeders...'
cd '$HostingerPath'
php artisan migrate --force --no-interaction
echo '    Migrations done. Running seeders...'
php artisan db:seed --force --no-interaction 2>&1 || echo '    (Seeder warning - mungkin data sudah ada)'
echo '    OK - Database migrated and seeded.'

# ── 6. Optimize & Permissions ────────────────────
echo ''
echo '==> [STEP 6/7] Optimizing application...'
cd '$HostingerPath'
php artisan storage:link 2>/dev/null || true
php artisan optimize:clear --no-interaction
php artisan config:cache --no-interaction
php artisan route:cache --no-interaction
php artisan view:cache --no-interaction

echo '    Setting file permissions...'
chown -R www:www '$HostingerPath' 2>/dev/null || chown -R www-data:www-data '$HostingerPath' 2>/dev/null || true
chmod -R 775 '$HostingerPath/storage' '$HostingerPath/bootstrap/cache'
echo '    OK - Application optimized.'

# ── 7. Reload Services ──────────────────────────
echo ''
echo '==> [STEP 7/7] Reloading web services...'
systemctl reload php-fpm-83 2>/dev/null || /etc/init.d/php-fpm-83 reload 2>/dev/null || systemctl reload php8.3-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true
echo '    OK - Services reloaded.'

# ── Summary ──────────────────────────────────────
echo ''
echo '=============================================='
echo '  SETUP SELESAI!'
echo '=============================================='
echo ''
echo "  Database : $DbName (MySQL)"
echo "  Web Root : $HostingerPath"
echo "  Domain   : $Domain"
echo ''
echo '  Login Credentials:'
echo '    Admin Pusat   : admin@sumbermakmurjaya.store / password'
echo '    Master        : master@sumbermakmurjaya.store / password'
echo '    Admin Cabang  : admin1-5@sumbermakmurjaya.store / password'
echo ''
echo '  Application Info:'
cd '$HostingerPath'
php artisan about --no-interaction 2>/dev/null | head -20 || true
echo ''
echo '  PENTING: Jangan lupa ubah password default!'
echo ''
"@

# Jalankan via SSH (1x password saja)
ssh -p $HostingerPort -o StrictHostKeyChecking=no "$HostingerUser@$HostingerHost" $RemoteScript

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[3/4] ✅ VPS Setup & Deploy berhasil!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[3/4] ❌ Ada error (exit code $LASTEXITCODE)" -ForegroundColor Red
    Write-Host "      Periksa output di atas untuk detail error." -ForegroundColor Yellow
    exit 1
}

# ── Step 4: Nginx Vhost Check ──────────────────────────────
Write-Host ""
Write-Host "[4/4] Checking Nginx vhost..." -ForegroundColor Yellow
Write-Host ""
Write-Host "      CATATAN: Jika VPS menggunakan aaPanel/BT Panel," -ForegroundColor Cyan
Write-Host "      buat website '$Domain' melalui panel." -ForegroundColor Cyan
Write-Host "      Set document root ke: $HostingerPath/public" -ForegroundColor Cyan
Write-Host ""

# ── Selesai ─────────────────────────────────────────────────
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  SETUP & DEPLOY SELESAI!                             " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Website URL : https://$Domain" -ForegroundColor White
Write-Host "  VPS         : $HostingerHost" -ForegroundColor White
Write-Host "  Web Root    : $HostingerPath" -ForegroundColor White
Write-Host "  Database    : $DbName (MySQL)" -ForegroundColor White
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Cyan
Write-Host "    1. Buat website di aaPanel/BT Panel (jika belum)" -ForegroundColor White
Write-Host "       - Domain: $Domain" -ForegroundColor DarkGray
Write-Host "       - Root: $HostingerPath/public" -ForegroundColor DarkGray
Write-Host "    2. Setup SSL certificate (Let's Encrypt)" -ForegroundColor White
Write-Host "    3. Pastikan DNS $Domain mengarah ke $HostingerHost" -ForegroundColor White
Write-Host "    4. Ubah password default di production!" -ForegroundColor White
Write-Host ""
Write-Host "  Untuk deploy berikutnya, gunakan:" -ForegroundColor Cyan
Write-Host "    .\deploy-direct.ps1" -ForegroundColor White
Write-Host ""
