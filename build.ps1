#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    Write-Host "[INFO] $Label..." -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] $Label failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        Read-Host "Press Enter to exit"
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
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[INFO] Installing $AppName..." -ForegroundColor Cyan
    winget install --id $WingetId -e --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to install $AppName." -ForegroundColor Red
        Read-Host "Press Enter to exit"
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
    '1' { $vshipBackend = 'cuda'; $msbuildToolset = 'v143'; $vcvarsArg = '-vcvars_ver=14.4' }
    '2' { $vshipBackend = 'hip'; $msbuildToolset = 'v143'; $vcvarsArg = '' }
    '3' { $vshipBackend = 'vulkan'; $msbuildToolset = 'v143'; $vcvarsArg = '' }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

$env:CC = 'clang'
$env:CXX = 'clang++'

Write-Host "[INFO] Checking basic system dependencies..." -ForegroundColor Cyan

if (-not (Assert-Command 'git')) {
    Confirm-Install "Git" "Git.Git"
}

if (-not (Assert-Command 'cmake')) {
    Confirm-Install "CMake" "Kitware.CMake"
}

if (-not (Assert-Command 'clang++')) {
    Confirm-Install "LLVM" "LLVM.LLVM"
}

if (-not (Assert-Command 'ninja')) {
    Confirm-Install "Ninja" "Ninja-build.Ninja"
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

if (-not (Test-Path 'C:\msys64\usr\bin\bash.exe')) {
    Confirm-Install "MSYS2" "MSYS2.MSYS2"
}

Write-Host "[INFO] Setting Rust toolchain to nightly..." -ForegroundColor Cyan
rustup default nightly
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to set Rust toolchain to nightly." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# vswhere ships with the VS installer independently of the build tools themselves,
# so check that it actually finds an installation with C++ tools.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCppTools = (Test-Path $vswhere) -and
(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
if (-not $hasCppTools) {
    Write-Host ""
    Write-Host "[PROMPT] Visual Studio Build Tools with C++ workload is missing." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
    if ($choice -ieq 'N') {
        Write-Host "[ERROR] Visual Studio Build Tools are required. Exiting." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[INFO] Installing Visual Studio Build Tools with Desktop C++ workload (this may take a while)..." -ForegroundColor Cyan

    $vsWorkloadComponents = "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $vsWingetArgs = "--quiet --wait --norestart $vsWorkloadComponents"
    $vsModifyArgs = "--quiet --norestart $vsWorkloadComponents"

    # --override forwards args directly to the VS bootstrapper, bypassing winget's defaults.
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget `
        --accept-source-agreements --accept-package-agreements `
        --override $vsWingetArgs

    if ($LASTEXITCODE -ne 0) {
        # winget refuses to reinstall an existing package; fall back to modify mode.
        Write-Host "[INFO] VS Build Tools already installed. Modifying existing installation to add C++ workload..." -ForegroundColor Cyan
        $vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
        if (-not (Test-Path $vsInstallerPath)) {
            Write-Host "[ERROR] Could not find vs_installer.exe. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
        $existingInstallPath = & $vswhere -latest -products * -property installationPath
        # Elevate only this call; the script itself does not require admin.
        Start-Process -FilePath $vsInstallerPath `
            -ArgumentList "modify --installPath `"$existingInstallPath`" $vsModifyArgs" `
            -Verb RunAs -Wait
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Failed to modify Visual Studio Build Tools. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    Update-SessionEnvironment
    Write-Host "[INFO] Visual Studio Build Tools with C++ workload installed successfully." -ForegroundColor Green
}

if ($vshipBackend -eq 'cuda' -and -not $env:CUDA_PATH) {
    Confirm-Install "NVIDIA CUDA Toolkit" "Nvidia.CUDA"
    if (-not $env:CUDA_PATH) {
        Write-Host "[ERROR] CUDA_PATH still not set after install. Try restarting your PC." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

if ($vshipBackend -eq 'hip' -and -not $env:HIP_PATH) {
    Write-Host "[INFO] Downloading AMD HIP SDK..." -ForegroundColor Cyan
    $hipInstaller = "$env:TEMP\AMD-HIP-Setup.exe"
    Invoke-WebRequest -Uri "https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q1-Win11-For-HIP.exe" -OutFile $hipInstaller
    Write-Host "[INFO] Installing AMD HIP SDK (this may take a while)..." -ForegroundColor Cyan
    Start-Process -FilePath $hipInstaller -ArgumentList '-install' -Wait
    Update-SessionEnvironment
    if (-not $env:HIP_PATH) {
        Write-Host "[ERROR] HIP_PATH still not set after install. Try restarting your PC." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# Vulkan SDK is always required - FFmpeg uses Vulkan decode hwaccels regardless of backend.
if (-not $env:VULKAN_SDK) {
    Confirm-Install "Vulkan SDK" "KhronosGroup.VulkanSDK"
    if (-not $env:VULKAN_SDK) {
        Write-Host "[ERROR] VULKAN_SDK still not set after install. Try restarting your PC." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================================
#  MSYS2 Dependencies
# ============================================================

$msysExe = 'C:\msys64\usr\bin\bash.exe'

Invoke-Step "Installing MSYS2 base dependencies" {
    & $msysExe -lc "pacman --noconfirm -S --needed autoconf automake libtool base-devel pkg-config"
}

# ============================================================
#  Locate Visual Studio
# ============================================================

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Host "[ERROR] Visual Studio with C++ tools not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$vcvarsScript = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"

# ============================================================
#  Compile Vship
# ============================================================

$vshipCacheLib = "lib\vship\$vshipBackend\libvship.lib"
if (Test-Path $vshipCacheLib) {
    Write-Host "[INFO] Vship for $vshipBackend already compiled. Skipping..." -ForegroundColor Cyan
    Copy-Item $vshipCacheLib "lib\" -Force
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
            if (-not $env:CUDA_PATH) {
                Write-Host "[ERROR] CUDA_PATH not set." -ForegroundColor Red
                Pop-Location; Read-Host "Press Enter to exit"; exit 1
            }
            # Pin nvcc to the v143 (14.4x) host compiler via -ccbin in case v145 is the default.
            $msvcV143Bin = Get-ChildItem "$vsPath\VC\Tools\MSVC\14.4*\bin\HostX64\x64" `
                -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
            if (-not $msvcV143Bin) {
                Write-Host "[WARNING] Could not find MSVC v143 toolset under $vsPath. nvcc will use whatever cl.exe is in PATH." -ForegroundColor Yellow
                $ccbinArg = @()
            }
            else {
                Write-Host "[INFO] Using MSVC v143 host compiler for nvcc: $msvcV143Bin" -ForegroundColor Cyan
                $ccbinArg = @('-ccbin', $msvcV143Bin)
            }
            Invoke-Step "Compiling Vship (CUDA)" {
                & "$env:CUDA_PATH\bin\nvcc.exe" @ccbinArg -x cu src/VshipLib.cpp -std=c++17 -I include -arch=native -Xcompiler /MT --lib -o libvship.lib
            }
        }
        'hip' {
            if (-not $env:HIP_PATH) {
                Write-Host "[ERROR] HIP_PATH not set." -ForegroundColor Red
                Pop-Location; Read-Host "Press Enter to exit"; exit 1
            }
            Invoke-Step "Compiling Vship (HIP)" {
                & "$env:HIP_PATH\bin\hipcc" -c src/VshipLib.cpp -std=c++17 -I include `
                    --offload-arch=native `
                    -Wno-unused-result -Wno-ignored-attributes -o libvship.o
            }
            if (Test-Path 'libvship.lib') { Remove-Item 'libvship.lib' }
            Invoke-Step "Archiving Vship (HIP)" { llvm-ar rcs libvship.lib libvship.o }
        }
        'vulkan' {
            if (-not $env:VULKAN_SDK) {
                Write-Host "[ERROR] VULKAN_SDK not set." -ForegroundColor Red
                Pop-Location; Read-Host "Press Enter to exit"; exit 1
            }
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

    if (-not (Test-Path '..\lib')) { New-Item -ItemType Directory '..\lib' | Out-Null }
    Copy-Item libvship.lib ..\lib\ -Force
    $cacheDir = "..\lib\vship\$vshipBackend"
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory $cacheDir | Out-Null }
    Copy-Item libvship.lib $cacheDir\ -Force

    Pop-Location
}

Write-Host ""
Write-Host "Select SVT-AV1 variant to compile:"
Write-Host "  1. svt-av1-hdr       (https://github.com/juliobbv-p/svt-av1-hdr)"
Write-Host "  2. svt-av1-tritium yis branch [WARNING: DO NOT USE - testing only] (https://github.com/Uranite/svt-av1-tritium/tree/yis)"
Write-Host "  3. svt-av1-essential (https://github.com/nekotrix/SVT-AV1-Essential/tree/Essential-v4.0.1)"
Write-Host "  4. 5fish             (https://github.com/Akatmks/5fish-svt-av1-psy-pr/tree/dlf-bias)"
$svtChoice = Read-Host "Enter choice (1-4) [Default: 1]"
if (-not $svtChoice) { $svtChoice = '1' }

switch ($svtChoice) {
    '1' { $svtVariant = 'svt-av1-hdr'; $svtRepo = 'https://github.com/juliobbv-p/svt-av1-hdr.git'; $svtBranch = ''; $svtDir = 'svt-av1-hdr'; $svtExtraCFlags = '' }
    '2' { $svtVariant = 'svt-av1-tritium-yis'; $svtRepo = 'https://github.com/Uranite/svt-av1-tritium.git'; $svtBranch = 'yis'; $svtDir = 'svt-av1-tritium'; $svtExtraCFlags = '' }
    '3' { $svtVariant = 'svt-av1-essential'; $svtRepo = 'https://github.com/nekotrix/SVT-AV1-Essential.git'; $svtBranch = 'Essential-v4.0.1'; $svtDir = 'SVT-AV1-Essential'; $svtExtraCFlags = '' }
    '4' { $svtVariant = '5fish'; $svtRepo = 'https://github.com/Akatmks/5fish-svt-av1-psy-pr.git'; $svtBranch = 'dlf-bias'; $svtDir = '5fish-svt-av1-psy-pr'; $svtExtraCFlags = ' -DSVT_LOG_QUIET' }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

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
        -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=ON `
        -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2$svtExtraCFlags" `
        -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2$svtExtraCFlags" `
        -DLOG_QUIET=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
}
Invoke-Step "Building $svtVariant" { ninja -C svt_build }
Pop-Location
if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }
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
            -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=native" `
            -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    }
    Invoke-Step "Building Opus" { ninja -C build }
    Pop-Location
    if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }
    Copy-Item opus\build\opus.lib lib\ -Force
}

if (Test-Path 'lib\opusenc.lib') {
    Write-Host "[INFO] libopusenc already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'libopusenc') { Push-Location libopusenc; git pull; Pop-Location }
    else { git clone --depth 300 https://gitlab.xiph.org/xiph/libopusenc.git }
    Push-Location libopusenc
    $msysExe = 'C:\msys64\usr\bin\bash.exe'
    Invoke-Step "Building libopusenc (MSYS2)" {
        $bashScript = @"
#!/bin/sh
set -e
./autogen.sh
./configure CC="clang" CXX="clang++" \
    CFLAGS="-target x86_64-pc-windows-msvc -O3 -flto -fuse-ld=lld -march=native" \
    LDFLAGS="-target x86_64-pc-windows-msvc -fuse-ld=lld" \
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
    if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }
    
    if (Test-Path 'libopusenc\.libs\opusenc.lib') {
        Copy-Item 'libopusenc\.libs\opusenc.lib' 'lib\opusenc.lib' -Force
    }
    else {
        Write-Host "[ERROR] Could not find compiled opusenc.lib output." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================================
#  Compile Vulkan, dav1d, FFmpeg
# ============================================================
$msysExe = 'C:\msys64\usr\bin\bash.exe'

if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }

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
            -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=native" `
            -DCMAKE_CXX_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=native"
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
            -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=native"
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
        Invoke-Step "Installing meson via pip" {
            pip install meson
        }
    }
    if (-not (Assert-Command 'nasm')) {
        Confirm-Install "NASM" "NetwideStudios.NASM"
    }
    Invoke-Step "Building dav1d" {
        meson setup build --default-library=static --buildtype=release -Db_vscrt=mt -Db_lto=true -Doptimization=3 -Denable_tools=false -Denable_examples=false -Dbitdepths="8,16" -Denable_asm=true "-Dc_args=-O3 -DNDEBUG -march=native -fuse-ld=lld" "-Dc_link_args=-O3 -DNDEBUG -march=native -fuse-ld=lld"
        ninja -C build
    }
    Pop-Location
    Copy-Item dav1d\build\src\libdav1d.a lib\dav1d.lib -Force
}

$msvcLibPath = Get-ChildItem "$vsPath\VC\Tools\MSVC" |
Sort-Object Name -Descending | Select-Object -First 1 |
ForEach-Object { "$($_.FullName)\lib\x64" }

$sdkVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' `
        -Name KitsRoot10 -ErrorAction SilentlyContinue) | ForEach-Object {
    Get-ChildItem "$($_.KitsRoot10)lib" | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
}
$sdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
$sdkLibUm = "$sdkRoot\lib\$sdkVersion\um\x64"
$sdkLibUcrt = "$sdkRoot\lib\$sdkVersion\ucrt\x64"
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
    --enable-lto \
    --extra-cflags="-flto -DNDEBUG -march=native /clang:-O3 -I`$(pwd)/../dav1d/include -I`$(pwd)/../dav1d/build/include -I`$(pwd)/../vulkan/install/include" \
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
    '-C', 'target-feature=+crt-static',
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

switch ($vshipBackend) {
    'cuda' {
        Invoke-Step "Cargo build (CUDA)" {
            cargo build --release --features $features --config $cargoConfig
        }
    }
    'hip' {
        Invoke-Step "Cargo build (HIP)" {
            cargo build --release --features $features --config $cargoConfig
        }
    }
    'vulkan' {
        Invoke-Step "Cargo build (Vulkan)" {
            cargo build --release --features $features --config $cargoConfig
        }
    }
}

Write-Host ""
if (-not (Test-Path 'target\release')) { New-Item -ItemType Directory 'target\release' | Out-Null }
Copy-Item 'vulkan\install\bin\vulkan-1.dll' 'target\release\vulkan-1.dll' -Force

Write-Host "[SUCCESS] Build script finished." -ForegroundColor Green
Read-Host "Press Enter to exit"