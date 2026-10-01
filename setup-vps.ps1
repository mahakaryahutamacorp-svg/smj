<#
.SYNOPSIS
    Sumber Makmur Jaya — Full VPS Setup & Deploy Script
    Setup database MySQL, Nginx vhost, clone repo, dan deploy aplikasi Laravel
    ke VPS Hostinger yang sama dengan Maju Bersama Online.
.USAGE
    .\setup-vps.ps1
    .\setup-vps.ps1 -SkipSetup    # Hanya deploy (jika setup sudah pernah)
#>

param (
    [string]$HostingerHost = "187.53.139.230",
    [int]$HostingerPort = 22,
    [string]$HostingerUser = "root",
    [string]$HostingerPath = "/www/wwwroot/sumbermakmurjaya.store",
    [string]$SshKeyPath = "",
    [string]$GitRepo = "https://github.com/mahakaryahutamacorp-svg/smj.git",
    [string]$GitBranch = "main",
    [string]$DbName = "smj_pos",
    [string]$DbUser = "smj_user",
    [string]$DbPassword = "SmjP0s2026!Secure",
    [string]$Domain = "sumbermakmurjaya.store",
    [switch]$SkipSetup
)

$ErrorActionPreference = 'Stop'

Write-Host "" 
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - VPS Setup & Deploy             " -ForegroundColor Cyan
Write-Host "  Target: $HostingerHost ($Domain)                    " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 0: Build front-end assets locally ──────────────────
Write-Host "[0/6] Building front-end assets locally..." -ForegroundColor Yellow
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

Push-Location $ProjectRoot
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build gagal." }
    Write-Host "      Front-end assets berhasil di-build." -ForegroundColor Green
} finally {
    Pop-Location
}

# ── SSH helper ──────────────────────────────────────────────
$SshArgs = @("-p", $HostingerPort, "-o", "StrictHostKeyChecking=no")
if ($SshKeyPath -ne "" -and (Test-Path $SshKeyPath)) {
    $SshArgs = @("-i", $SshKeyPath) + $SshArgs
}
$SshTarget = "$HostingerUser@$HostingerHost"

function Invoke-Ssh {
    param([string]$Command)
    ssh @SshArgs $SshTarget $Command
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command gagal (exit $LASTEXITCODE): $Command"
    }
}

if (-not $SkipSetup) {
    # ── Step 1: Create MySQL Database & User ────────────────
    Write-Host "[1/6] Setting up MySQL database..." -ForegroundColor Yellow
    
    $MysqlSetup = @"
set -euo pipefail

# Check if MySQL/MariaDB is running
if command -v mysql &> /dev/null; then
    echo '==> MySQL/MariaDB found.'
else
    echo '==> ERROR: MySQL/MariaDB not found. Installing...'
    apt-get update -qq && apt-get install -y -qq mariadb-server
    systemctl enable mariadb
    systemctl start mariadb
fi

# Create database and user
mysql -u root <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$DbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';
GRANT ALL PRIVILEGES ON \`$DbName\`.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
EOSQL

echo "==> Database '$DbName' dan user '$DbUser' berhasil dibuat."
"@

    Invoke-Ssh $MysqlSetup
    Write-Host "      MySQL database & user berhasil di-setup." -ForegroundColor Green

    # ── Step 2: Setup Nginx Virtual Host ────────────────────
    Write-Host "[2/6] Configuring Nginx virtual host..." -ForegroundColor Yellow
    
    $NginxSetup = @"
set -euo pipefail

# Buat direktori website
mkdir -p '$HostingerPath'

# Check apakah Nginx config sudah ada
NGINX_CONF="/etc/nginx/sites-available/$Domain"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/$Domain"

# Cek apakah menggunakan aaPanel/BT Panel (CyberPanel/Hostinger VPS)
if [ -d "/www/server/panel" ]; then
    echo "==> Terdeteksi aaPanel/BT Panel. Membuat vhost via panel conf..."
    NGINX_CONF="/www/server/panel/vhost/nginx/${Domain}.conf"
fi

# Cek apakah vhost sudah ada
if [ -f "`$NGINX_CONF" ]; then
    echo "==> Nginx config untuk $Domain sudah ada, skip..."
else
    echo "==> Membuat Nginx virtual host untuk $Domain..."
    cat > "`$NGINX_CONF" <<'EOCONF'
server {
    listen 80;
    listen [::]:80;
    server_name $Domain www.$Domain;
    
    root $HostingerPath/public;
    index index.php index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 1024;

    location / {
        try_files `$uri `$uri/ /index.php?`$query_string;
    }

    location ~ \.php`$ {
        fastcgi_pass unix:/tmp/php-cgi-83.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
        fastcgi_param PATH_INFO `$fastcgi_path_info;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    access_log /www/wwwlogs/${Domain}.log;
    error_log /www/wwwlogs/${Domain}.error.log;
}
EOCONF

    # Jika bukan aaPanel, enable site
    if [ -d "/etc/nginx/sites-enabled" ] && [ ! -L "`$NGINX_CONF_ENABLED" ]; then
        ln -sf "`$NGINX_CONF" "`$NGINX_CONF_ENABLED"
    fi

    # Test dan reload Nginx
    nginx -t && (systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true)
    echo "==> Nginx virtual host untuk $Domain berhasil dibuat."
fi
"@

    Invoke-Ssh $NginxSetup
    Write-Host "      Nginx virtual host berhasil dikonfigurasi." -ForegroundColor Green

} else {
    Write-Host "[1-2/6] Skipping setup (--SkipSetup)..." -ForegroundColor DarkGray
}

# ── Step 3: Push latest code to GitHub ──────────────────────
Write-Host "[3/6] Pushing latest code to GitHub..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
    git add -A
    $hasChanges = (git status --porcelain) -ne ""
    if ($hasChanges) {
        git commit -m "deploy: Sumber Makmur Jaya production $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        git push origin $GitBranch
        Write-Host "      Code pushed ke GitHub." -ForegroundColor Green
    } else {
        Write-Host "      No changes to commit." -ForegroundColor DarkGray
        git push origin $GitBranch 2>$null
    }
} catch {
    Write-Host "      Warning: Git push issue - $_" -ForegroundColor DarkYellow
} finally {
    Pop-Location
}

# ── Step 4: Clone/Pull & Install on VPS ────────────────────
Write-Host "[4/6] Deploying application to VPS..." -ForegroundColor Yellow

$DeployCommand = @"
set -euo pipefail

# Clone atau pull
if [ -d '$HostingerPath/.git' ]; then
    echo '==> Git repository exists, pulling latest...'
    cd '$HostingerPath'
    git checkout -- .
    git pull origin $GitBranch
else
    echo '==> Cloning repository...'
    git clone -b $GitBranch '$GitRepo' '$HostingerPath'
    cd '$HostingerPath'
fi

# Setup .env production
echo '==> Setting up .env production...'
if [ -f '.env.production' ]; then
    cp .env.production .env
else
    cp .env.example .env
    # Update .env untuk production
    sed -i 's/APP_ENV=local/APP_ENV=production/' .env
    sed -i 's/APP_DEBUG=true/APP_DEBUG=false/' .env
    sed -i "s|APP_URL=http://localhost|APP_URL=https://$Domain|" .env
    sed -i 's/APP_NAME=Laravel/APP_NAME="Sumber Makmur Jaya"/' .env
    sed -i 's/DB_CONNECTION=sqlite/DB_CONNECTION=mysql/' .env
    sed -i 's/# DB_HOST=127.0.0.1/DB_HOST=127.0.0.1/' .env
    sed -i 's/# DB_PORT=3306/DB_PORT=3306/' .env
    sed -i "s/# DB_DATABASE=laravel/DB_DATABASE=$DbName/" .env
    sed -i "s/# DB_USERNAME=root/DB_USERNAME=$DbUser/" .env
    sed -i "s/# DB_PASSWORD=/DB_PASSWORD=$DbPassword/" .env
    sed -i 's/LOG_LEVEL=debug/LOG_LEVEL=error/' .env
fi

# Generate APP_KEY jika belum ada
if ! grep -q 'APP_KEY=base64:' .env; then
    php artisan key:generate --force
fi

echo '==> Installing Composer dependencies...'
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

echo '==> Running database migrations...'
php artisan migrate --force

echo '==> Running seeders...'
php artisan db:seed --class=ChartOfAccountSeeder --force
php artisan db:seed --class=CustomerGroupSeeder --force

echo '==> Creating storage link...'
php artisan storage:link 2>/dev/null || true

echo '==> Optimizing application...'
php artisan optimize:clear
php artisan config:cache
php artisan route:cache
php artisan view:cache

echo '==> Setting file permissions...'
chown -R www:www '$HostingerPath'
chmod -R 775 storage bootstrap/cache

echo '==> Reloading services...'
systemctl reload php-fpm-83 2>/dev/null || /etc/init.d/php-fpm-83 reload 2>/dev/null || true
systemctl reload nginx 2>/dev/null || /etc/init.d/nginx reload 2>/dev/null || true

echo ''
echo '================================================'
echo '  Deployment berhasil!'
echo '  URL: https://$Domain'
echo '================================================'
php artisan about --no-interaction | head -n 15
"@

Invoke-Ssh $DeployCommand
Write-Host "      Aplikasi berhasil di-deploy ke VPS." -ForegroundColor Green

# ── Step 5: Seed initial data ──────────────────────────────
Write-Host "[5/6] Running full database seeder (first-time setup)..." -ForegroundColor Yellow

if (-not $SkipSetup) {
    $SeedCommand = @"
set -euo pipefail
cd '$HostingerPath'
php artisan db:seed --force
echo '==> Seeding selesai.'
"@
    Invoke-Ssh $SeedCommand
    Write-Host "      Database seeded successfully." -ForegroundColor Green
} else {
    Write-Host "      Skipping full seed (use manual if needed)." -ForegroundColor DarkGray
}

# ── Step 6: Verify deployment ──────────────────────────────
Write-Host "[6/6] Verifying deployment..." -ForegroundColor Yellow

$VerifyCommand = @"
set -euo pipefail
cd '$HostingerPath'

echo '==> PHP version:'
php -v | head -1

echo ''
echo '==> Database connection test:'
php artisan tinker --execute="DB::connection()->getPdo(); echo 'MySQL connection OK';" 2>/dev/null || echo 'Connection test skipped'

echo ''
echo '==> Storage directory permissions:'
ls -la storage/ | head -5

echo ''
echo '==> Application info:'
php artisan about --no-interaction 2>/dev/null | head -20
"@

Invoke-Ssh $VerifyCommand

# ── Selesai ─────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  SETUP & DEPLOY SELESAI!                             " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Website URL : https://$Domain" -ForegroundColor White
Write-Host "  VPS         : $HostingerHost" -ForegroundColor White
Write-Host "  Web Root    : $HostingerPath" -ForegroundColor White
Write-Host "  Database    : $DbName (MySQL)" -ForegroundColor White
Write-Host ""
Write-Host "  Login Credentials:" -ForegroundColor Cyan
Write-Host "    Admin Pusat  : admin@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host "    Master       : master@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host "    Admin Cabang : admin1-5@sumbermakmurjaya.store / password" -ForegroundColor White
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Cyan
Write-Host "    1. Setup SSL via aaPanel/BT Panel atau certbot" -ForegroundColor White
Write-Host "    2. Pastikan DNS $Domain mengarah ke $HostingerHost" -ForegroundColor White
Write-Host "    3. Ubah password default di production" -ForegroundColor White
Write-Host ""
