#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
#  Helper Functions
# ============================================================

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

# Refreshes PATH and common SDK env vars from the registry into the current session,
# so tools installed by winget are immediately usable without restarting the terminal.
function Update-SessionEnvironment {
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machinePath;$userPath"

    foreach ($var in @('CUDA_PATH', 'HIP_PATH', 'VULKAN_SDK', 'VCPKG_ROOT')) {
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

# ============================================================
#  Backend Selection
# ============================================================

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

# Set clang as the default C/C++ compiler for all builds
$env:CC = 'clang'
$env:CXX = 'clang++'

# ============================================================
#  System Dependencies
# ============================================================

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

# Ensure nightly toolchain is active
Write-Host "[INFO] Setting Rust toolchain to nightly..." -ForegroundColor Cyan
rustup default nightly
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to set Rust toolchain to nightly." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Visual Studio Build Tools
# vswhere.exe can exist independently of VS Build Tools (it ships with the VS installer),
# so we must check that vswhere actually finds an installation with C++ tools, not just
# that the file exists.
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

    # First try a fresh winget install (works when VS Build Tools are not installed at all).
    # --override forwards args directly to the VS bootstrapper, bypassing winget's defaults.
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget `
        --accept-source-agreements --accept-package-agreements `
        --override $vsWingetArgs

    if ($LASTEXITCODE -ne 0) {
        # winget refuses to reinstall an already-present package. Fall back to running
        # the existing VS installer directly in modify mode to add the missing workload.
        Write-Host "[INFO] VS Build Tools already installed. Modifying existing installation to add C++ workload..." -ForegroundColor Cyan
        $vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
        if (-not (Test-Path $vsInstallerPath)) {
            Write-Host "[ERROR] Could not find vs_installer.exe. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
        # 'modify' updates the existing installation without a full reinstall.
        $existingInstallPath = & $vswhere -latest -products * -property installationPath
        # -Verb RunAs elevates only this specific call since the script itself does not run as admin.
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

# Backend-specific SDKs
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

if ($vshipBackend -eq 'vulkan' -and -not $env:VULKAN_SDK) {
    Confirm-Install "Vulkan SDK" "KhronosGroup.VulkanSDK"
    if (-not $env:VULKAN_SDK) {
        Write-Host "[ERROR] VULKAN_SDK still not set after install. Try restarting your PC." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================================
#  vcpkg
# ============================================================

# Check VCPKG_ROOT first to respect an existing install anywhere on the system,
# then fall back to C:\vcpkg, and only prompt to install if neither exists.
if ($env:VCPKG_ROOT -and (Test-Path "$env:VCPKG_ROOT\vcpkg.exe")) {
    Write-Host "[INFO] Found existing vcpkg at $env:VCPKG_ROOT" -ForegroundColor Cyan
}
elseif (Test-Path 'C:\vcpkg\vcpkg.exe') {
    Write-Host "[INFO] Found existing vcpkg at C:\vcpkg" -ForegroundColor Cyan
    $env:VCPKG_ROOT = 'C:\vcpkg'
}
else {
    Write-Host ""
    Write-Host "[PROMPT] vcpkg is not installed." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to install it to C:\vcpkg? (Y/N) [Default: Y]"
    if ($choice -ieq 'N') {
        Write-Host "[ERROR] vcpkg is required. Please install it manually and set VCPKG_ROOT." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[INFO] Installing vcpkg to C:\vcpkg..." -ForegroundColor Cyan
    if (-not (Test-Path 'C:\vcpkg')) {
        git clone --depth 300 https://github.com/microsoft/vcpkg.git C:\vcpkg
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Failed to clone vcpkg." -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    & C:\vcpkg\bootstrap-vcpkg.bat -disableMetrics
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] vcpkg bootstrap failed." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    [System.Environment]::SetEnvironmentVariable('VCPKG_ROOT', 'C:\vcpkg', 'User')
    Write-Host "[INFO] VCPKG_ROOT set to C:\vcpkg" -ForegroundColor Green
    $env:VCPKG_ROOT = 'C:\vcpkg'
}

# ============================================================
#  Locate Visual Studio (vcvars64 will be invoked only for msbuild)
# ============================================================

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Host "[ERROR] Visual Studio with C++ tools not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$vcvarsScript = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"

function Invoke-WithMsvc {
    param([string]$Label, [scriptblock]$Action)

    # Save the entire current process environment
    $savedEnv = @{}
    foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
        $savedEnv[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    }

    # Runs a command inside an MSVC environment sourced from vcvars64.
    $vcvarsCmd = "`"$vcvarsScript`""
    # Reset PATH to system essentials before invoking cmd, because the accumulated
    # PATH from all tool installs can exceed cmd's 8191 char limit and cause
    # 'input line is too long'. vcvars64 will rebuild PATH correctly anyway.
    $savedPath = $env:PATH
    $minPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
    $envDump = cmd /c "set PATH=$minPath && $vcvarsCmd && set"
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    # Restore our full PATH (with all installed tools) on top of what vcvars set
    $env:PATH = $env:PATH + ';' + $savedPath

    if (-not (Assert-Command 'cl.exe')) {
        Write-Host "[ERROR] MSVC cl.exe not found after vcvars setup." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    try {
        Invoke-Step $Label $Action
    }
    finally {
        # Restore original environment variables
        foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
            if (-not $savedEnv.Contains($key)) {
                [System.Environment]::SetEnvironmentVariable($key, $null, 'Process')
            }
        }
        foreach ($key in $savedEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
        }
    }
}

# ============================================================
#  vcpkg Dependencies
# ============================================================

Write-Host "[INFO] Installing required vcpkg dependencies..." -ForegroundColor Cyan
& "$env:VCPKG_ROOT\vcpkg.exe" install 'ffmpeg[avcodec,avdevice,avfilter,avformat,swresample,swscale,zlib,bzip2,core,dav1d,gpl,version3,lzma,openssl,xml2]:x64-windows-static'
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] vcpkg install failed." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}



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
            # nvcc uses cl.exe as its host compiler. Detect the v143 (MSVC 14.4x)
            # toolset path so we can pass it via -ccbin, ensuring the correct
            # compiler is used even if v145 is the default on this machine.
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

# ============================================================
#  Compile FFMS2
# ============================================================

if (Test-Path 'ffms2\lib\ffms2.lib') {
    Write-Host "[INFO] FFMS2 already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'ffms2') { Push-Location ffms2; git pull; Pop-Location }
    else { git clone --depth 300 https://github.com/Uranite/ffms2.git }
    Push-Location ffms2
    Invoke-Step "Configuring FFMS2" {
        cmake --fresh -B ffms2_build -G Ninja -DBUILD_SHARED_LIBS=OFF -DENABLE_AVISYNTH=OFF `
            -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_CXX_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=znver2" `
            -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=znver2"
    }
    Invoke-Step "Building FFMS2" { ninja -C ffms2_build }
    Pop-Location
    if (-not (Test-Path 'ffms2\lib')) { New-Item -ItemType Directory 'ffms2\lib' | Out-Null }
    Copy-Item ffms2\ffms2_build\ffms2.lib ffms2\lib\ -Force

    $ffmsLib = "$PWD\ffms2\lib"
    $ffmsInclude = "$PWD\ffms2\include"
    $env:FFMS_LIB_DIR = $ffmsLib
    $env:FFMS_INCLUDE_DIR = $ffmsInclude
    [System.Environment]::SetEnvironmentVariable('FFMS_LIB_DIR', $ffmsLib, 'User')
    [System.Environment]::SetEnvironmentVariable('FFMS_INCLUDE_DIR', $ffmsInclude, 'User')
    Write-Host "[INFO] FFMS_LIB_DIR set to $ffmsLib" -ForegroundColor Green
    Write-Host "[INFO] FFMS_INCLUDE_DIR set to $ffmsInclude" -ForegroundColor Green
}

# ============================================================
#  SVT-AV1 Variant Selection
# ============================================================

Write-Host ""
Write-Host "Select SVT-AV1 variant to compile:"
Write-Host "  1. svt-av1-hdr      (https://github.com/juliobbv-p/svt-av1-hdr)"
Write-Host "  2. 5fish             (https://github.com/Akatmks/5fish-svt-av1-psy-pr/tree/dlf-bias)"
Write-Host "  3. svt-av1-essential (https://github.com/nekotrix/SVT-AV1-Essential/tree/Essential-v4.0.1)"
Write-Host "  4. svt-av1-tritium yis branch [WARNING: DO NOT USE - testing only] (https://github.com/Uranite/svt-av1-tritium/tree/yis)"
$svtChoice = Read-Host "Enter choice (1-4) [Default: 1]"
if (-not $svtChoice) { $svtChoice = '1' }

switch ($svtChoice) {
    '1' { $svtVariant = 'svt-av1-hdr'; $svtRepo = 'https://github.com/juliobbv-p/svt-av1-hdr.git'; $svtBranch = ''; $svtDir = 'svt-av1-hdr'; $svtExtraCFlags = '' }
    '2' { $svtVariant = '5fish'; $svtRepo = 'https://github.com/Akatmks/5fish-svt-av1-psy-pr.git'; $svtBranch = 'dlf-bias'; $svtDir = '5fish-svt-av1-psy-pr'; $svtExtraCFlags = ' -DSVT_LOG_QUIET' }
    '3' { $svtVariant = 'svt-av1-essential'; $svtRepo = 'https://github.com/nekotrix/SVT-AV1-Essential.git'; $svtBranch = 'Essential-v4.0.1'; $svtDir = 'SVT-AV1-Essential'; $svtExtraCFlags = '' }
    '4' {
        $svtVariant = 'svt-av1-tritium-yis'
        $svtRepo = 'https://github.com/Uranite/svt-av1-tritium.git'
        $svtBranch = 'yis'
        $svtDir = 'svt-av1-tritium'
        $svtExtraCFlags = ''
        Write-Host ""
        Write-Host "[WARNING] svt-av1-tritium yis branch is for testing only. DO NOT USE for production." -ForegroundColor Red
        $confirm = Read-Host "Are you sure you want to continue? (Y/N) [Default: N]"
        if ($confirm -ine 'Y') {
            Write-Host "[INFO] Aborting. Please re-run and select a different variant." -ForegroundColor Yellow
            Read-Host "Press Enter to exit"
            exit 0
        }
    }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================================
#  Compile SVT-AV1
# ============================================================

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

# ============================================================
#  Compile Opus
# ============================================================

if (Test-Path 'lib\opus.lib') {
    Write-Host "[INFO] Opus already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'opus') { Push-Location opus; git pull; Pop-Location }
    else { git clone --depth 300 https://gitlab.xiph.org/xiph/opus.git }
    Push-Location opus
    Invoke-Step "Configuring Opus" {
        cmake --fresh -B build -G Ninja `
            -DCMAKE_BUILD_TYPE=Release `
            -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG -march=znver2" `
            -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    }
    Invoke-Step "Building Opus" { ninja -C build }
    Pop-Location
    if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }
    Copy-Item opus\build\opus.lib lib\ -Force
}

# ============================================================
#  Compile libopusenc
# ============================================================

if (Test-Path 'lib\opusenc.lib') {
    Write-Host "[INFO] libopusenc already compiled. Skipping..." -ForegroundColor Cyan
}
else {
    if (Test-Path 'libopusenc') { Push-Location libopusenc; git pull; Pop-Location }
    else { git clone --depth 300 https://gitlab.xiph.org/xiph/libopusenc.git }
    Push-Location libopusenc\win32\VS2015
    # Build the static lib project explicitly. The default solution builds a DLL
    # which produces only a small import .lib rather than a full static archive.
    # WholeProgramOptimization is disabled to avoid LTO conflicts with clang-compiled libs.
    Invoke-WithMsvc "Building libopusenc (static)" {
        msbuild opusenc.vcxproj /p:Configuration=Release /p:Platform=x64 `
            /p:ConfigurationType=StaticLibrary `
            /p:RuntimeLibrary=MultiThreaded `
            /p:WholeProgramOptimization=false `
            /p:PlatformToolset=$msbuildToolset
    }
    Pop-Location
    if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' | Out-Null }
    Copy-Item libopusenc\win32\VS2015\x64\Release\opusenc.lib lib\ -Force
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
    '-C', 'target-feature=+crt-static'
)
$rustflagsJson = '[' + (($rustflags | ForEach-Object { "'$_'" }) -join ', ') + ']'
$cargoConfig = "build.rustflags=$rustflagsJson"

switch ($vshipBackend) {
    'cuda' {
        Invoke-Step "Cargo build (CUDA)" {
            cargo build --release --features "static,vship,nvidia,vcpkg" --config $cargoConfig
        }
    }
    'hip' {
        Invoke-Step "Cargo build (HIP)" {
            cargo build --release --features "static,vship,amd,vcpkg" --config $cargoConfig
        }
    }
    'vulkan' {
        Invoke-Step "Cargo build (Vulkan)" {
            cargo build --release --features "static,vship,vcpkg" --config $cargoConfig
        }
    }
}

Write-Host ""
Write-Host "[SUCCESS] Build script finished." -ForegroundColor Green
Read-Host "Press Enter to exit"