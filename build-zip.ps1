<#
.SYNOPSIS
    Sumber Makmur Jaya — Build ZIP untuk deploy ke Hostinger Shared Hosting.
    Menjalankan npm run build, lalu membuat deploy-hostinger.zip yang ringan & siap upload.
.USAGE
    .\build-zip.ps1
#>

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Get-Location }

$ZipName = "deploy-hostinger.zip"
$ZipPath = Join-Path $ProjectRoot $ZipName
$TempDir = Join-Path $ProjectRoot "_build_temp"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Sumber Makmur Jaya - Build Deploy ZIP      " -ForegroundColor Cyan
Write-Host "  Target: Hostinger Shared Hosting (Business) " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Build front-end assets ──────────────────────────
Write-Host "[1/5] Menjalankan npm run build..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build gagal dengan exit code $LASTEXITCODE" }
    Write-Host "      Front-end assets berhasil di-build." -ForegroundColor Green
} finally {
    Pop-Location
}

# ── Step 2: Bersihkan build sebelumnya ──────────────────────
Write-Host "[2/5] Membersihkan build sebelumnya..." -ForegroundColor Yellow
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ── Step 3: Salin folder & file production ──────────────────
Write-Host "[3/5] Menyalin file production..." -ForegroundColor Yellow

# Folder yang WAJIB ada di production Laravel
$folders = @(
    'app',
    'bootstrap',
    'config',
    'database',
    'lang',
    'public',
    'resources',
    'routes',
    'storage',
    'vendor'
)

foreach ($folder in $folders) {
    $src = Join-Path $ProjectRoot $folder
    $dst = Join-Path $TempDir $folder
    if (Test-Path $src) {
        # Menggunakan robocopy untuk kecepatan, exclude log files
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP `
            /XD "node_modules" ".git" ".cline" `
            /XF "*.log" "*.md" ".gitignore" ".gitkeep" | Out-Null
        Write-Host "      + $folder" -ForegroundColor DarkGray
    } else {
        Write-Host "      ! $folder (tidak ditemukan, dilewati)" -ForegroundColor DarkYellow
    }
}

# File root yang WAJIB
$rootFiles = @(
    '.env',
    '.htaccess',
    'artisan',
    'composer.json',
    'composer.lock'
)

foreach ($file in $rootFiles) {
    $src = Join-Path $ProjectRoot $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $TempDir -Force
        Write-Host "      + $file" -ForegroundColor DarkGray
    } else {
        Write-Host "      ! $file (tidak ditemukan, dilewati)" -ForegroundColor DarkYellow
    }
}

# Pastikan folder storage memiliki struktur minimal
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
    # Pastikan .gitignore ada agar folder tidak kosong di hosting
    $gitignore = Join-Path $fullPath ".gitignore"
    if (-not (Test-Path $gitignore)) {
        Set-Content -Path $gitignore -Value "*`n!.gitignore" -NoNewline
    }
}

# ── Step 4: Buat ZIP ───────────────────────────────────────
Write-Host "[4/5] Membuat $ZipName..." -ForegroundColor Yellow

# Gunakan .NET ZipFile untuk menghindari masalah file lock
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $TempDir,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false  # tidak include root folder name
    )
} catch {
    Write-Host "      .NET ZipFile gagal, mencoba Compress-Archive..." -ForegroundColor DarkYellow
    Compress-Archive -Path "$TempDir\*" -DestinationPath $ZipPath -Force
}

$zipSize = (Get-Item $ZipPath).Length
$zipSizeMB = [math]::Round($zipSize / 1MB, 2)
Write-Host "      ZIP berhasil dibuat: $ZipName ($zipSizeMB MB)" -ForegroundColor Green

# ── Step 5: Bersihkan folder temp ──────────────────────────
Write-Host "[5/5] Membersihkan folder temporary..." -ForegroundColor Yellow
Remove-Item $TempDir -Recurse -Force
Write-Host "      Folder temp dihapus." -ForegroundColor Green

# ── Selesai ─────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  SELESAI! File siap upload ke Hostinger:" -ForegroundColor Green
Write-Host "  $ZipPath" -ForegroundColor White
Write-Host "  Ukuran: $zipSizeMB MB" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Langkah selanjutnya:" -ForegroundColor Cyan
Write-Host "  1. Login ke hPanel Hostinger" -ForegroundColor White
Write-Host "  2. Buka File Manager -> public_html/" -ForegroundColor White
Write-Host "  3. Upload $ZipName lalu Extract" -ForegroundColor White
Write-Host "  4. Pastikan .env sudah sesuai environment production" -ForegroundColor White
Write-Host "  5. Jalankan migration via SSH/Terminal Hostinger:" -ForegroundColor White
Write-Host "     php artisan migrate --force" -ForegroundColor DarkGray
Write-Host ""
