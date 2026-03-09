#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-Cuda129 {
    $url = 'https://developer.download.nvidia.com/compute/cuda/12.9.1/local_installers/cuda_12.9.1_576.57_windows.exe'
    $sha256 = 'F0CA7CC7B4CEA2FAC2C4951819D2A9CAEA31E04000E9110E2048719525F8EA0E'
    $installer = "$env:TEMP\cuda_12.9.1_windows.exe"
    $logPath = "$env:TEMP\cuda_12.9.1_install.log"

    Write-Host "[INFO] Downloading CUDA Toolkit 12.9.1 (this may take a while)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $installer

    Write-Host "[INFO] Verifying installer checksum..." -ForegroundColor Cyan
    $actual = (Get-FileHash $installer -Algorithm SHA256).Hash
    if ($actual -ne $sha256) {
        Write-Host "[ERROR] CUDA installer checksum mismatch. Expected $sha256, got $actual." -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Installing CUDA Toolkit 12.9.1 silently (this may take a while)..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath $installer -ArgumentList "-y -gm2 -s -n -log:`"$logPath`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "[ERROR] CUDA 12.9.1 installer failed (exit code $($proc.ExitCode)). Log: $logPath" -ForegroundColor Red
        exit 1
    }

    Update-SessionEnvironment
    Write-Host "[INFO] CUDA Toolkit 12.9.1 installed successfully." -ForegroundColor Green
    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}
function Install-Cuda132 {
    $url = 'https://developer.download.nvidia.com/compute/cuda/13.2.0/local_installers/cuda_13.2.0_windows.exe'
    $sha256 = '9D4CF64B3E9DC7B1DCC9DF9337A977478C930C67F5598DF9C6F842FAE747D241'
    $installer = "$env:TEMP\cuda_13.2.0_windows.exe"
    $logPath = "$env:TEMP\cuda_13.2.0_install.log"

    Write-Host "[INFO] Downloading CUDA Toolkit 13.2.0 (this may take a while)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $installer

    Write-Host "[INFO] Verifying installer checksum..." -ForegroundColor Cyan
    $actual = (Get-FileHash $installer -Algorithm SHA256).Hash
    if ($actual -ne $sha256) {
        Write-Host "[ERROR] CUDA installer checksum mismatch. Expected $sha256, got $actual." -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Installing CUDA Toolkit 13.2.0 silently (this may take a while)..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath $installer -ArgumentList "-y -gm2 -s -n -log:`"$logPath`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "[ERROR] CUDA 13.2.0 installer failed (exit code $($proc.ExitCode)). Log: $logPath" -ForegroundColor Red
        exit 1
    }

    Update-SessionEnvironment
    Write-Host "[INFO] CUDA Toolkit 13.2.0 installed successfully." -ForegroundColor Green
    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    Write-Host "[INFO] $Label..." -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] $Label failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }
}

# Refresh PATH and SDK env vars from registry so newly installed tools are usable immediately.
function Update-SessionEnvironment {
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machinePath;$userPath"

    foreach ($var in @('CUDA_PATH', 'HIP_PATH', 'VULKAN_SDK')) {
        $val = [System.Environment]::GetEnvironmentVariable($var, 'Machine')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($var, 'User') }
        if ($val) { Set-Item "env:$var" $val }
    }
}

function Get-Avx512Supported {
    # System.Runtime.Intrinsics is only available on .NET 5+ (PowerShell 7+).
    # On PS 5.1 / .NET Framework the type won't exist, so we catch and return $false.
    try {
        return [System.Runtime.Intrinsics.X86.Avx512F]::IsSupported
    }
    catch {
        Write-Host "[INFO] Could not detect AVX512 support (requires PowerShell 7+). Enabling anyway." -ForegroundColor Cyan
        return $true
    }
}

function Assert-Command {
    param([string]$Cmd)
    return [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function Confirm-Install {
    param([string]$AppName, [string]$WingetId)
    Write-Host ""
    Write-Host "[PROMPT] $AppName is missing." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to install it using winget? (Y/N) [Default: Y]"
    if ($choice -ieq 'N') {
        Write-Host "[ERROR] $AppName is required. Exiting." -ForegroundColor Red
        exit 1
    }
    Write-Host "[INFO] Installing $AppName..." -ForegroundColor Cyan
    winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to install $AppName." -ForegroundColor Red
        exit 1
    }
    Update-SessionEnvironment
    Write-Host "[INFO] $AppName installed successfully." -ForegroundColor Green
}

Write-Host "Select Vship backend to compile:"
Write-Host "  1. CUDA"
Write-Host "  2. HIP"
Write-Host "  3. Vulkan"
$vshipChoice = Read-Host "Enter choice (1-3) [Default: 1]"
if (-not $vshipChoice) { $vshipChoice = '1' }

switch ($vshipChoice) {
    '1' { $vshipBackend = 'cuda' }
    '2' { $vshipBackend = 'hip' }
    '3' { $vshipBackend = 'vulkan' }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Select SVT-AV1 variant to compile:"
Write-Host "  1. svt-av1-hdr       (https://github.com/juliobbv-p/svt-av1-hdr)"
Write-Host "  2. svt-av1-tritium yis branch [WARNING: DO NOT USE - testing only] (https://github.com/Uranite/svt-av1-tritium/tree/yis)"
Write-Host "  3. svt-av1-essential (https://github.com/nekotrix/SVT-AV1-Essential/tree/Essential-v4.0.1)"
Write-Host "  4. 5fish             (https://github.com/5fish/svt-av1-psy/tree/exp)"
$svtChoice = Read-Host "Enter choice (1-4) [Default: 1]"
if (-not $svtChoice) { $svtChoice = '1' }

switch ($svtChoice) {
    '1' { $svtVariant = 'svt-av1-hdr'; $svtRepo = 'https://github.com/juliobbv-p/svt-av1-hdr.git'; $svtBranch = ''; $svtDir = 'svt-av1-hdr'; $svtExtraCFlags = '' }
    '2' { $svtVariant = 'svt-av1-tritium-yis'; $svtRepo = 'https://github.com/Uranite/svt-av1-tritium.git'; $svtBranch = 'yis'; $svtDir = 'svt-av1-tritium'; $svtExtraCFlags = '' }
    '3' { $svtVariant = 'svt-av1-essential'; $svtRepo = 'https://github.com/nekotrix/SVT-AV1-Essential.git'; $svtBranch = 'Essential-v4.0.1'; $svtDir = 'SVT-AV1-Essential'; $svtExtraCFlags = '' }
    '4' { $svtVariant = '5fish'; $svtRepo = 'https://github.com/5fish/svt-av1-psy.git'; $svtBranch = 'exp'; $svtDir = '5fish-svt-av1-psy'; $svtExtraCFlags = ' -DSVT_LOG_QUIET' }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        exit 1
    }
}

$env:CC = 'clang'
$env:CXX = 'clang++'

# Detect NVIDIA GPU generation when CUDA backend is selected.
# RTX 2000 series (Turing) introduced the RTX brand; anything RTX 20xx or higher
# is "modern". GTX and older architectures are "legacy".
$vsIncludeV143 = $false                                    # only true for legacy CUDA GPU
# TODO: restore to 'Nvidia.CUDA' once Nvidia.CUDA 13.2 is available in winget
# Tracking PR: https://github.com/microsoft/winget-pkgs/pull/346618
$cudaWingetId = $null

if ($vshipBackend -eq 'cuda') {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'NVIDIA' } |
    Select-Object -First 1 -ExpandProperty Name

    if ($gpu) {
        Write-Host "[INFO] Detected GPU: $gpu" -ForegroundColor Cyan
    }
    else {
        Write-Host "[WARNING] Could not detect NVIDIA GPU. Defaulting to legacy settings." -ForegroundColor Yellow
    }

    # Extract the first 4-digit number after "RTX" to handle suffixes like
    # "Ti", "Ti Laptop GPU", "6GB", workstation names, etc.
    # e.g. "RTX 4060 Ti Laptop GPU", "RTX 3050 6GB", and "RTX A4000".
    # TITAN RTX is Turing (same gen as RTX 20xx) but has no 4-digit model number, so it gets a special case.
    $isTitanRtx = $gpu -and $gpu -match 'TITAN RTX'
    if ($isTitanRtx -or ($gpu -and $gpu -match 'NVIDIA\s+(?:GeForce\s+)?RTX\s*(\d{4})' -and [int]$Matches[1] -ge 2000)) {
        Write-Host "[INFO] Modern GPU (RTX 2000+) detected. Using latest CUDA and VS 2026 Build Tools." -ForegroundColor Cyan
        $vsIncludeV143 = $false
        # TODO: restore to 'Nvidia.CUDA' once Nvidia.CUDA 13.2 is available in winget
        $cudaWingetId = $null
    }
    else {
        Write-Host "[INFO] Legacy GPU detected. Using CUDA 12.9 and VS 2026 Build Tools with MSVC v143." -ForegroundColor Cyan
        $vsIncludeV143 = $true
        $cudaWingetId = $null  # no winget package exists; installed manually via Install-Cuda129
    }
}

if (-not (Assert-Command 'git')) {
    Confirm-Install "Git" "Git.Git"
}

if (-not (Assert-Command 'cmake')) {
    Confirm-Install "CMake" "Kitware.CMake"
}

if (-not (Assert-Command 'clang++')) {
    $llvmBin = "$env:ProgramFiles\LLVM\bin"
    if (Test-Path "$llvmBin\clang++.exe") {
        Write-Host "[INFO] LLVM not in PATH; adding $llvmBin to session PATH." -ForegroundColor Cyan
        $env:PATH = "$llvmBin;$env:PATH"
    }
    else {
        Confirm-Install "LLVM" "LLVM.LLVM"
        if (-not (Assert-Command 'clang++') -and (Test-Path "$llvmBin\clang++.exe")) {
            Write-Host "[INFO] LLVM not in PATH; adding $llvmBin to session PATH." -ForegroundColor Cyan
            $env:PATH = "$llvmBin;$env:PATH"
        }
    }
}

if (-not (Assert-Command 'clang++')) {
    Write-Host "[ERROR] clang++ not found after LLVM setup." -ForegroundColor Red
    exit 1
}
if (-not (Assert-Command 'llvm-ar')) {
    Write-Host "[ERROR] llvm-ar not found after LLVM setup." -ForegroundColor Red
    exit 1
}

if (-not (Assert-Command 'ninja')) {
    Confirm-Install "Ninja" "Ninja-build.Ninja"
}

if (-not (Assert-Command 'nasm')) {
    $nasmpath = "$env:ProgramFiles\NASM"
    if (Test-Path "$nasmpath\nasm.exe") {
        Write-Host "[INFO] NASM not in PATH; adding $nasmpath to session PATH." -ForegroundColor Cyan
        $env:PATH = "$nasmpath;$env:PATH"
    }
    else {
        Confirm-Install "NASM" "NASM.NASM"
        if (-not (Assert-Command 'nasm') -and (Test-Path "$nasmpath\nasm.exe")) {
            Write-Host "[INFO] NASM not in PATH; adding $nasmpath to session PATH." -ForegroundColor Cyan
            $env:PATH = "$nasmpath;$env:PATH"
        }
    }
}

if (-not (Assert-Command 'cargo')) {
    Confirm-Install "Rust (rustup)" "Rustlang.Rustup"
    # rustup writes cargo to ~\.cargo\bin, which may not be in the refreshed system
    # PATH yet since rustup adds it to the user PATH via its own installer logic.
    $cargoBin = "$env:USERPROFILE\.cargo\bin"
    if (Test-Path $cargoBin) {
        $env:PATH = "$cargoBin;$env:PATH"
    }
}

function Find-Msys2Root {
    # Well-known default path
    $candidates = @('C:\msys64')

    # Scoop (per-user and global)
    $candidates += "$env:USERPROFILE\scoop\apps\msys2\current"
    $candidates += "$env:ProgramData\scoop\apps\msys2\current"

    $found = $candidates | Where-Object { Test-Path "$_\usr\bin\bash.exe" } | Select-Object -First 1
    if ($found) { return $found }

    # Registry uninstall entries (covers custom install paths)
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        $entry = Get-ChildItem $root -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'MSYS2' } |
        Select-Object -First 1
        if ($entry -and $entry.InstallLocation -and (Test-Path "$($entry.InstallLocation)\usr\bin\bash.exe")) {
            return $entry.InstallLocation
        }
    }
    return $null
}

$msysRoot = Find-Msys2Root
if (-not $msysRoot) {
    Confirm-Install "MSYS2" "MSYS2.MSYS2"
    $msysRoot = Find-Msys2Root
    if (-not $msysRoot) {
        Write-Host "[ERROR] MSYS2 not found after install. Please re-run the script or set the path manually." -ForegroundColor Red
        exit 1
    }
}
Write-Host "[INFO] Found MSYS2 at $msysRoot" -ForegroundColor Cyan
$msysExe = "$msysRoot\usr\bin\bash.exe"

Write-Host "[INFO] Setting Rust toolchain to nightly..." -ForegroundColor Cyan
rustup default nightly
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to set Rust toolchain to nightly." -ForegroundColor Red
    exit 1
}

# vswhere ships with the VS installer independently of the build tools themselves,
# so check that it actually finds an installation with C++ tools.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCppTools = (Test-Path $vswhere) -and
(& $vswhere -latest -products * -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath 2>$null)
if (-not $hasCppTools) {
    Write-Host ""
    Write-Host "[PROMPT] Visual Studio Build Tools with C++ workload is missing." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
    if ($choice -ieq 'N') {
        Write-Host "[ERROR] Visual Studio Build Tools are required. Exiting." -ForegroundColor Red
        exit 1
    }
    Write-Host "[INFO] Installing Visual Studio Build Tools with Desktop C++ workload (this may take a while)..." -ForegroundColor Cyan

    $vsWorkloadComponents = "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if ($vsIncludeV143) {
        $vsWorkloadComponents += " --add Microsoft.VisualStudio.ComponentGroup.VC.Tools.143.x86.x64"
    }
    $vsWingetArgs = "--quiet --wait --norestart $vsWorkloadComponents"
    $vsModifyArgs = "--quiet --norestart $vsWorkloadComponents"

    # we override winget's defaults and actually install the Desktop Development with C++ workload
    winget install -e --id 'Microsoft.VisualStudio.BuildTools' --source winget `
        --accept-source-agreements --accept-package-agreements `
        --override $vsWingetArgs

    if ($LASTEXITCODE -ne 0) {
        # winget refuses to reinstall an existing package; fall back to modify mode.
        Write-Host "[INFO] VS Build Tools already installed. Modifying existing installation to add C++ workload..." -ForegroundColor Cyan
        $vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
        if (-not (Test-Path $vsInstallerPath)) {
            Write-Host "[ERROR] Could not find vs_installer.exe. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
            exit 1
        }
        $existingInstallPath = & $vswhere -latest -products * -property installationPath
        # We run this as admin
        Start-Process -FilePath $vsInstallerPath `
            -ArgumentList "modify --installPath `"$existingInstallPath`" $vsModifyArgs" `
            -Verb RunAs -Wait
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Failed to modify Visual Studio Build Tools. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
            exit 1
        }
    }
    Update-SessionEnvironment
    Write-Host "[INFO] Visual Studio Build Tools with C++ workload installed successfully." -ForegroundColor Green
}

if ($vshipBackend -eq 'cuda' -and -not $env:CUDA_PATH) {
    # TODO: when Nvidia.CUDA 13.2 lands in winget, restore $cudaWingetId and replace this block with:
    #   if ($cudaWingetId) { Confirm-Install "NVIDIA CUDA Toolkit" $cudaWingetId } else { Install-Cuda129 }
    if (-not $vsIncludeV143) {
        Write-Host ""
        Write-Host "[PROMPT] NVIDIA CUDA Toolkit 13.2 is missing." -ForegroundColor Yellow
        $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
        if ($choice -ieq 'N') {
            Write-Host "[ERROR] CUDA Toolkit is required. Exiting." -ForegroundColor Red
            exit 1
        }
        Install-Cuda132
    }
    else {
        Write-Host ""
        Write-Host "[PROMPT] NVIDIA CUDA Toolkit 12.9 is missing." -ForegroundColor Yellow
        $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
        if ($choice -ieq 'N') {
            Write-Host "[ERROR] CUDA Toolkit is required. Exiting." -ForegroundColor Red
            exit 1
        }
        Install-Cuda129
    }
    if (-not $env:CUDA_PATH) {
        Write-Host "[ERROR] CUDA_PATH still not set after install. Try restarting your terminal, or set CUDA_PATH manually." -ForegroundColor Red
        exit 1
    }
}

if ($vshipBackend -eq 'hip' -and -not $env:HIP_PATH) {
    Write-Host ""
    Write-Host "[PROMPT] AMD HIP SDK is missing." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
    if ($choice -ieq 'N') {
        Write-Host "[ERROR] AMD HIP SDK is required. Exiting." -ForegroundColor Red
        exit 1
    }
    Write-Host "[INFO] Downloading AMD HIP SDK..." -ForegroundColor Cyan
    $hipInstaller = "$env:TEMP\AMD-HIP-Setup.exe"
    Invoke-WebRequest -Uri "https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q1-Win11-For-HIP.exe" -OutFile $hipInstaller
    Write-Host "[INFO] Installing AMD HIP SDK (this may take a while)..." -ForegroundColor Cyan
    Start-Process -FilePath $hipInstaller -ArgumentList '-install' -Wait
    Update-SessionEnvironment
    if (-not $env:HIP_PATH) {
        Write-Host "[ERROR] HIP_PATH still not set after install. Try restarting your terminal, or set HIP_PATH manually." -ForegroundColor Red
        exit 1
    }
    Remove-Item -Path $hipInstaller -Force -ErrorAction SilentlyContinue
}

# Vulkan SDK is always required for the hwaccel feature
if (-not $env:VULKAN_SDK) {
    Write-Host "[INFO] Vulkan SDK is always required for the hwaccel feature." -ForegroundColor Cyan
    Confirm-Install "Vulkan SDK" "KhronosGroup.VulkanSDK"
    if (-not $env:VULKAN_SDK) {
        Write-Host "[ERROR] VULKAN_SDK not found. Try restarting your terminal, or set VULKAN_SDK manually." -ForegroundColor Red
        exit 1
    }
}

# ============================================================
#  MSYS2 Dependencies
# ============================================================

Invoke-Step "Installing MSYS2 base dependencies" {
    & $msysExe -lc "pacman --noconfirm -S --needed autoconf automake libtool base-devel pkg-config"
}

# ============================================================
#  Locate Visual Studio
# ============================================================

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Host "[ERROR] Visual Studio with C++ tools not found." -ForegroundColor Red
    exit 1
}

# ============================================================
#  Compile Vship
# ============================================================

if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }

if (Test-Path 'lib\libvship.lib') {
    Write-Host "[INFO] Vship already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'Vship') {
        Push-Location Vship; git pull; Pop-Location
    }
    else {
        git clone --depth 300 https://codeberg.org/Line-fr/Vship.git
    }
    Push-Location Vship

    switch ($vshipBackend) {
        'cuda' {
            if ($vsIncludeV143) {
                # "Legacy" GPU: use MSVC v143 via ccbin
                $msvcBin = Get-ChildItem "$vsPath\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '14.4*' } |
                Sort-Object Name -Descending | Select-Object -First 1 |
                ForEach-Object { "$($_.FullName)\bin\HostX64\x64" }
            }
            else {
                # "Modern" GPU: use the latest available MSVC.
                $msvcBin = Get-ChildItem "$vsPath\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1 |
                ForEach-Object { "$($_.FullName)\bin\HostX64\x64" }
            }
            if (-not $msvcBin) {
                Write-Host "[WARNING] Could not find MSVC toolset under $vsPath. nvcc may fail if cl.exe is not in PATH." -ForegroundColor Yellow
                $ccbinArg = @()
            }
            else {
                Write-Host "[INFO] Using MSVC host compiler for nvcc: $msvcBin" -ForegroundColor Cyan
                $ccbinArg = @('-ccbin', $msvcBin)
            }
            Invoke-Step "Compiling Vship (CUDA)" {
                & "$env:CUDA_PATH\bin\nvcc.exe" @ccbinArg -x cu src/VshipLib.cpp -std=c++17 -I include -arch=native -Xcompiler /MT --lib -o libvship.lib
            }
        }
        'hip' {
            Invoke-Step "Compiling Vship (HIP)" {
                & "$env:HIP_PATH\bin\hipcc" -c src/VshipLib.cpp -std=c++17 -I include `
                    --offload-arch=native `
                    -Wno-unused-result -Wno-ignored-attributes -o libvship.o
            }
            if (Test-Path 'libvship.lib') { Remove-Item 'libvship.lib' }
            Invoke-Step "Archiving Vship (HIP)" { llvm-ar rcs libvship.lib libvship.o }
        }
        'vulkan' {
            Invoke-Step "Compiling shaderEmbedder" {
                clang++ src/Vulkan/spvFileToCppHeader.cpp -std=c++17 -O2 -o shaderEmbedder.exe
            }
            Invoke-Step "Embedding shaders" {
                .\shaderEmbedder.exe libvshipSpvShaders include/libvshipSpvShaders.hpp
            }
            Invoke-Step "Compiling Vship (Vulkan)" {
                clang++ -c src/VshipLib.cpp -DVULKANBUILD -DNDEBUG -std=c++17 -O2 -Wall `
                    -Wno-ignored-attributes -Wno-unused-variable -Wno-nullability-completeness `
                    -Wno-unused-private-field -I include -I "$env:VULKAN_SDK\Include" -o libvship.o
            }
            if (Test-Path 'libvship.lib') { Remove-Item 'libvship.lib' }
            Invoke-Step "Archiving Vship (Vulkan)" { llvm-ar rcs libvship.lib libvship.o }
        }
    }

    Copy-Item libvship.lib ..\lib\ -Force

    Pop-Location
}

$avx512Supported = Get-Avx512Supported
$svtAvx512Flag = if ($avx512Supported) { 'ON' } else { 'OFF' }
Write-Host "[INFO] AVX512 support detected: $avx512Supported. SVT-AV1 will be built with -DENABLE_AVX512=$svtAvx512Flag." -ForegroundColor Cyan

if (Test-Path $svtDir) {
    Push-Location $svtDir; git pull; Pop-Location
}
else {
    if ($svtBranch) {
        git clone --depth 300 --branch $svtBranch $svtRepo $svtDir
    }
    else {
        git clone --depth 300 $svtRepo $svtDir
    }
}
Push-Location $svtDir
Invoke-Step "Configuring $svtVariant" {
    cmake -B svt_build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF `
        -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=$svtAvx512Flag `
        -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2$svtExtraCFlags" `
        -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2$svtExtraCFlags" `
        -DLOG_QUIET=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
}
Invoke-Step "Building $svtVariant" { ninja -C svt_build }
Pop-Location
Copy-Item $svtDir\Bin\Release\SvtAv1Enc.lib lib\ -Force

if (Test-Path 'lib\opus.lib') {
    Write-Host "[INFO] Opus already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'opus') { Push-Location opus; git pull; Pop-Location }
    else { git clone --depth 300 https://gitlab.xiph.org/xiph/opus.git }
    Push-Location opus
    Invoke-Step "Configuring Opus" {
        cmake -B build -G Ninja `
            -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_C_FLAGS_RELEASE="-flto=thin -O3 -DNDEBUG -march=native" `
            -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    }
    Invoke-Step "Building Opus" { ninja -C build }
    Pop-Location
    Copy-Item opus\build\opus.lib lib\ -Force
}

if (Test-Path 'lib\opusenc.lib') {
    Write-Host "[INFO] libopusenc already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'libopusenc') { Push-Location libopusenc; git pull; Pop-Location }
    else { git clone --depth 300 https://gitlab.xiph.org/xiph/libopusenc.git }
    Push-Location libopusenc
    Invoke-Step "Building libopusenc (MSYS2)" {
        $bashScript = @"
#!/bin/sh
set -e
./autogen.sh
./configure CC="clang" CXX="clang++" \
    CFLAGS="-O3 -flto=thin -fuse-ld=lld -march=native" \
    LDFLAGS="-O3 -flto=thin -fuse-ld=lld -march=native" \
    AR="llvm-ar" RANLIB="llvm-ranlib" \
    DEPS_CFLAGS="-I../opus/include" \
    DEPS_LIBS="-L../lib -lopus" \
    --enable-static --disable-shared
make clean
make -j`$(nproc)
"@
        Set-Content -Path 'build_in_msys.sh' -Value $bashScript -Encoding Ascii
        $env:MSYS2_PATH_TYPE = 'inherit'
        $unixPath = $PWD.Path -replace '\\', '/'
        & $msysExe -lc "cd `"$unixPath`" && sh ./build_in_msys.sh"
    }
    Pop-Location
    
    if (Test-Path 'libopusenc\.libs\opusenc.lib') {
        Copy-Item 'libopusenc\.libs\opusenc.lib' 'lib\opusenc.lib' -Force
    }
    else {
        Write-Host "[ERROR] Could not find compiled opusenc.lib output." -ForegroundColor Red
        exit 1
    }
}

# ============================================================
#  Compile Vulkan, dav1d, FFmpeg
# ============================================================

if (Test-Path 'lib\vulkan-1.lib') {
    Write-Host "[INFO] Vulkan already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (-not (Test-Path 'vulkan')) { New-Item -ItemType Directory 'vulkan' | Out-Null }
    Push-Location vulkan

    if (Test-Path 'Vulkan-Headers') { Push-Location 'Vulkan-Headers'; git pull; Pop-Location }
    else { git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git }

    Invoke-Step "Configuring Vulkan Headers" {
        cmake -S Vulkan-Headers -B Vulkan-Headers/build -G Ninja `
            -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_INSTALL_PREFIX="$PWD/install" `
            -DCMAKE_C_FLAGS_RELEASE="-flto=thin -O3 -DNDEBUG -march=native" `
            -DCMAKE_CXX_FLAGS_RELEASE="-flto=thin -O3 -DNDEBUG -march=native"
    }
    Invoke-Step "Installing Vulkan Headers" {
        ninja -C Vulkan-Headers/build install
    }

    if (Test-Path 'Vulkan-Loader') { Push-Location 'Vulkan-Loader'; git pull; Pop-Location }
    else { git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Loader.git }

    $ml64 = Get-ChildItem "$vsPath\VC\Tools\MSVC" |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { "$($_.FullName)\bin\HostX64\x64\ml64.exe" }

    Invoke-Step "Building Vulkan Loader" {
        cmake -S Vulkan-Loader -B Vulkan-Loader/build -G Ninja `
            -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_INSTALL_PREFIX="$PWD/install" `
            -DBUILD_SHARED_LIBS=ON `
            "-DCMAKE_ASM_MASM_COMPILER=$ml64" `
            -DVULKAN_HEADERS_INSTALL_DIR="$PWD/install" `
            -DCMAKE_C_FLAGS_RELEASE="-flto=thin -O3 -DNDEBUG -march=native"
        ninja -C Vulkan-Loader/build
        ninja -C Vulkan-Loader/build install
    }

    Pop-Location

    Copy-Item 'vulkan\install\lib\vulkan-1.lib' 'lib\vulkan-1.lib' -Force
}

# dav1d
if (Test-Path 'lib\dav1d.lib') {
    Write-Host "[INFO] dav1d already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'dav1d') { Push-Location dav1d; git pull; Pop-Location }
    else { git clone --depth 300 https://code.videolan.org/videolan/dav1d.git }
    Push-Location dav1d
    if (-not (Assert-Command 'meson')) {
        $mesonVersion = '1.10.0'
        $mesonUrl = "https://github.com/mesonbuild/meson/releases/download/$mesonVersion/meson-$mesonVersion-64.msi"
        $mesonHash = '8328ff3a06ddb58fd20e6330dfbcebe38b386863360738d6bca12037c8b10c99'
        $mesonMsi = "$env:TEMP\meson-$mesonVersion-64.msi"
        $mesonExe = "$env:ProgramFiles\Meson\meson.exe"

        Write-Host ""
        Write-Host "[PROMPT] Meson is missing." -ForegroundColor Yellow
        $choice = Read-Host "Do you want to install Meson $($mesonVersion)? (Y/N) [Default: Y]"
        if ($choice -ieq 'N') {
            Write-Host "[ERROR] Meson is required to build dav1d. Exiting." -ForegroundColor Red
            exit 1
        }

        Write-Host "[INFO] Downloading Meson $mesonVersion..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $mesonUrl -OutFile $mesonMsi

        $actual = (Get-FileHash $mesonMsi -Algorithm SHA256).Hash
        if ($actual -ne $mesonHash.ToUpper()) {
            Write-Host "[ERROR] Meson installer checksum mismatch. Expected $mesonHash, got $actual." -ForegroundColor Red
            exit 1
        }

        Write-Host "[INFO] Installing Meson $mesonVersion silently..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$mesonMsi`" /quiet /qn ALLUSERS=1" -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Host "[ERROR] Meson installer failed (exit code $($proc.ExitCode))." -ForegroundColor Red
            exit 1
        }

        if (Test-Path $mesonExe) {
            $mesonBin = Split-Path $mesonExe
            if ($env:PATH -notlike "*$mesonBin*") {
                $env:PATH = "$mesonBin;$env:PATH"
            }
        }
        else {
            Write-Host "[ERROR] meson.exe not found at $mesonExe after install." -ForegroundColor Red
            exit 1
        }
        Write-Host "[INFO] Meson $mesonVersion installed successfully." -ForegroundColor Green
    }
    Invoke-Step "Building dav1d" {
        meson setup build --default-library=static --buildtype=release -Db_vscrt=mt -Db_lto=true -Db_lto_mode=thin -Doptimization=3 -Denable_tools=false -Denable_examples=false -Dbitdepths="8,16" -Denable_asm=true "-Dc_args=-O3 -DNDEBUG -march=native -fuse-ld=lld" "-Dc_link_args=-O3 -DNDEBUG -march=native -fuse-ld=lld"
        ninja -C build
    }
    Pop-Location
    Copy-Item dav1d\build\src\libdav1d.a lib\dav1d.lib -Force
}

$msvcLibPath = Get-ChildItem "$vsPath\VC\Tools\MSVC" |
Sort-Object Name -Descending | Select-Object -First 1 |
ForEach-Object { "$($_.FullName)\lib\x64" }

$candidateRoots = @(
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10,
    "${env:ProgramFiles(x86)}\Windows Kits\10",
    "$env:ProgramFiles\Windows Kits\10"
)

$sdkRoot = $null
$sdkVersion = $null

foreach ($root in $candidateRoots) {
    if ($root -and (Test-Path $root)) {
        $foundVer = Get-ChildItem "$root\Lib" -ErrorAction SilentlyContinue | Where-Object { (Test-Path "$($_.FullName)\um\x64") -and (Test-Path "$($_.FullName)\ucrt\x64") } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
        if ($foundVer) {
            $sdkRoot = $root
            $sdkVersion = $foundVer
            break
        }
    }
}

if (-not $sdkRoot -or -not $sdkVersion) {
    Write-Host "[ERROR] Could not find a valid Windows 10/11 SDK installation with um\x64 and ucrt\x64 libraries." -ForegroundColor Red
    exit 1
}

$sdkLibUm = "$sdkRoot\Lib\$sdkVersion\um\x64"
$sdkLibUcrt = "$sdkRoot\Lib\$sdkVersion\ucrt\x64"

if (-not (Test-Path $sdkLibUm)) { Write-Host "[ERROR] Windows SDK lib um\x64 not found at $sdkLibUm." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $sdkLibUcrt)) { Write-Host "[ERROR] Windows SDK lib ucrt\x64 not found at $sdkLibUcrt." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $msvcLibPath)) { Write-Host "[ERROR] MSVC lib not found at $msvcLibPath." -ForegroundColor Red; exit 1 }

$msvcLibPathShort = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($msvcLibPath).ShortPath
$sdkLibUmShort = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($sdkLibUm).ShortPath
$sdkLibUcrtShort = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($sdkLibUcrt).ShortPath
$msvcLibPathUnix = $msvcLibPathShort -replace '\\', '/'
$sdkLibUmUnix = $sdkLibUmShort -replace '\\', '/'
$sdkLibUcrtUnix = $sdkLibUcrtShort -replace '\\', '/'

# FFmpeg
if (Test-Path 'lib\avcodec.lib') {
    Write-Host "[INFO] FFmpeg already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'FFmpeg') { Push-Location FFmpeg; git pull; Pop-Location }
    else { git clone --depth 300 https://github.com/FFmpeg/FFmpeg.git }
    Push-Location FFmpeg
    Invoke-Step "Building FFmpeg (MSYS2 Inherit)" {
        $bashScript = @"
#!/bin/sh
set -e
export PKG_CONFIG_PATH="`$(pwd)/../dav1d/build/meson-private:`$(pwd)/../vulkan/install/lib/pkgconfig"
sed -i "s|^prefix=.*|prefix=`$(pwd)/../dav1d/build|" `$(pwd)/../dav1d/build/meson-private/dav1d.pc

sed -i 's/if test "`$cc_type" = "clang"; then/if true; then/' configure
sed -i 's/test "`$cc_type" != "`$ld_type" && die "LTO requires same compiler and linker"/true/' configure
./configure \
    --cc="clang-cl" \
    --cxx="clang-cl" \
    --ld="lld-link" \
    --ar="llvm-ar" \
    --ranlib="llvm-ranlib" \
    --nm="llvm-nm" \
    --strip="llvm-strip" \
    --toolchain="msvc" \
    --enable-lto="thin" \
    --extra-cflags="-flto=thin -DNDEBUG -march=native /clang:-O3 -I`$(pwd)/../dav1d/include -I`$(pwd)/../dav1d/build/include -I`$(pwd)/../vulkan/install/include" \
    --extra-ldflags="-LIBPATH:`$(pwd)/../lib \"-LIBPATH:$msvcLibPathUnix\" \"-LIBPATH:$sdkLibUmUnix\" \"-LIBPATH:$sdkLibUcrtUnix\"" \
    --extra-libs="dav1d.lib vulkan-1.lib" \
    --disable-shared \
    --enable-static \
    --pkg-config-flags="--static" \
    --disable-programs \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-network \
    --disable-autodetect \
    --disable-all \
    --disable-everything \
    --enable-avcodec \
    --enable-avformat \
    --enable-avutil \
    --enable-swscale \
    --enable-swresample \
    --enable-protocol=file \
    --enable-demuxer=matroska \
    --enable-demuxer=mov \
    --enable-demuxer=mpegts \
    --enable-demuxer=mpegps \
    --enable-demuxer=flv \
    --enable-demuxer=avi \
    --enable-demuxer=ivf \
    --enable-demuxer=yuv4mpegpipe \
    --enable-demuxer=h264 \
    --enable-demuxer=hevc \
    --enable-demuxer=vvc \
    --enable-decoder=rawvideo \
    --enable-decoder=h264 \
    --enable-decoder=hevc \
    --enable-decoder=mpeg2video \
    --enable-decoder=mpeg1video \
    --enable-decoder=mpeg4 \
    --enable-decoder=av1 \
    --enable-decoder=libdav1d \
    --enable-decoder=vp9 \
    --enable-decoder=vc1 \
    --enable-decoder=vvc \
    --enable-decoder=aac \
    --enable-decoder=aac_latm \
    --enable-decoder=ac3 \
    --enable-decoder=eac3 \
    --enable-decoder=dca \
    --enable-decoder=truehd \
    --enable-decoder=mlp \
    --enable-decoder=mp1 \
    --enable-decoder=mp1float \
    --enable-decoder=mp2 \
    --enable-decoder=mp2float \
    --enable-decoder=mp3 \
    --enable-decoder=mp3float \
    --enable-decoder=opus \
    --enable-decoder=vorbis \
    --enable-decoder=flac \
    --enable-decoder=alac \
    --enable-decoder=ape \
    --enable-decoder=tak \
    --enable-decoder=tta \
    --enable-decoder=wavpack \
    --enable-decoder=wmalossless \
    --enable-decoder=wmapro \
    --enable-decoder=wmav1 \
    --enable-decoder=wmav2 \
    --enable-decoder=mpc7 \
    --enable-decoder=mpc8 \
    --enable-decoder=dsd_lsbf \
    --enable-decoder=dsd_lsbf_planar \
    --enable-decoder=dsd_msbf \
    --enable-decoder=dsd_msbf_planar \
    --enable-decoder=pcm_s16le \
    --enable-decoder=pcm_s16be \
    --enable-decoder=pcm_s24le \
    --enable-decoder=pcm_s24be \
    --enable-decoder=pcm_s32le \
    --enable-decoder=pcm_s32be \
    --enable-decoder=pcm_f32le \
    --enable-decoder=pcm_f32be \
    --enable-decoder=pcm_f64le \
    --enable-decoder=pcm_f64be \
    --enable-decoder=pcm_bluray \
    --enable-decoder=pcm_dvd \
    --enable-libdav1d \
    --enable-parser=h264 \
    --enable-parser=hevc \
    --enable-parser=mpeg4video \
    --enable-parser=mpegvideo \
    --enable-parser=av1 \
    --enable-parser=vp9 \
    --enable-parser=vvc \
    --enable-parser=vc1 \
    --enable-parser=aac \
    --enable-parser=ac3 \
    --enable-parser=dca \
    --enable-parser=mpegaudio \
    --enable-parser=opus \
    --enable-parser=vorbis \
    --enable-parser=flac \
    --enable-vulkan \
    --enable-hwaccel=h264_vulkan \
    --enable-hwaccel=hevc_vulkan \
    --enable-hwaccel=av1_vulkan \
    --enable-hwaccel=vp9_vulkan
make -j`$(nproc)
"@
        Set-Content -Path 'build_ffmpeg.sh' -Value $bashScript -Encoding Ascii
        $env:MSYS2_PATH_TYPE = 'inherit'
        $unixPath = $PWD.Path -replace '\\', '/'
        & $msysExe -lc "cd `"$unixPath`" && sh ./build_ffmpeg.sh"
    }
    Pop-Location
    Copy-Item 'FFmpeg\libavcodec\avcodec.lib' 'lib\avcodec.lib' -Force
    Copy-Item 'FFmpeg\libavformat\avformat.lib' 'lib\avformat.lib' -Force
    Copy-Item 'FFmpeg\libavutil\avutil.lib' 'lib\avutil.lib' -Force
    Copy-Item 'FFmpeg\libswresample\swresample.lib' 'lib\swresample.lib' -Force
    Copy-Item 'FFmpeg\libswscale\swscale.lib' 'lib\swscale.lib' -Force
}

# ============================================================
#  Cargo Build
# ============================================================

$rustflags = @(
    '-C', 'debuginfo=0',
    '-C', 'target-cpu=native',
    '-C', 'opt-level=3',
    '-C', 'codegen-units=1',
    '-C', 'strip=symbols',
    '-C', 'panic=abort',
    '-C', 'linker=lld-link',
    '-C', 'lto=fat',
    '-C', 'embed-bitcode=yes',
    '-Z', 'dylib-lto',
    '-Z', 'panic_abort_tests',
    '-C', 'link-arg=/OPT:REF',
    '-C', 'link-arg=/OPT:ICF'
)
$rustflagsJson = '[' + (($rustflags | ForEach-Object { "'$_'" }) -join ', ') + ']'
$cargoConfig = "build.rustflags=$rustflagsJson"

$features = "static,vship"
if ($vshipBackend -eq 'cuda') { $features += ",nvidia" }
elseif ($vshipBackend -eq 'hip') { $features += ",amd" }

if ($svtChoice -eq '4') {
    $features += ",5fish"
}

Invoke-Step "Cargo build ($vshipBackend)" {
    cargo update
    cargo build --release --features $features --config $cargoConfig
}

Write-Host ""
if (-not (Test-Path 'target\release')) { New-Item -ItemType Directory 'target\release' | Out-Null }
# We don't need the dll since the gpu driver already provides it, but since we already compiled it, why not
if (-not (Test-Path 'target\release\vulkan-1.dll')) { Copy-Item 'vulkan\install\bin\vulkan-1.dll' 'target\release\vulkan-1.dll' -Force }

Write-Host "[SUCCESS] Build script finished." -ForegroundColor Green
