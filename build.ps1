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
    $newPath = "$machinePath;$userPath"

    $commonPaths = @(
        "$env:ProgramFiles\LLVM\bin",
        "$env:ProgramFiles\NASM",
        "$env:ProgramFiles\Meson",
        "$env:USERPROFILE\.cargo\bin"
    )
    foreach ($p in $commonPaths) {
        if ((Test-Path $p) -and ($newPath -notlike "*$p*")) {
            $newPath = "$p;$newPath"
        }
    }
    $env:PATH = $newPath

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
    winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to install $AppName." -ForegroundColor Red
        exit 1
    }
    Update-SessionEnvironment
    Write-Host "[INFO] $AppName installed successfully." -ForegroundColor Green
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

function Install-Msys2 {
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
    Invoke-Step "Installing MSYS2 base dependencies" {
        & $msysExe -lc "pacman --noconfirm -S --needed autoconf automake libtool base-devel pkg-config" | Out-Host
    }
    return $msysExe
}

function Install-VsBuildTools {
    param([bool]$VsIncludeV143)
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
        if ($VsIncludeV143) {
            $vsWorkloadComponents += " --add Microsoft.VisualStudio.ComponentGroup.VC.Tools.143.x86.x64"
        }
        $vsWingetArgs = "--quiet --wait --norestart $vsWorkloadComponents"
        $vsModifyArgs = "--quiet --norestart $vsWorkloadComponents"

        winget install -e --id 'Microsoft.VisualStudio.BuildTools' --source winget `
            --accept-source-agreements --accept-package-agreements `
            --override $vsWingetArgs | Out-Host

        if ($LASTEXITCODE -ne 0) {
            $existingInstallPath = & $vswhere -latest -products * -property installationPath 2>$null
            if (-not $existingInstallPath) {
                Write-Host "[ERROR] winget failed to install Visual Studio Build Tools (exit code $LASTEXITCODE) and no existing installation was found." -ForegroundColor Red
                exit 1
            }
            Write-Host "[INFO] VS Build Tools already installed, but there is no C++ workload." -ForegroundColor Cyan
            Write-Host "[INFO] Installing C++ workload..." -ForegroundColor Cyan
            $vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
            if (-not (Test-Path $vsInstallerPath)) {
                Write-Host "[ERROR] Could not find vs_installer.exe. Please open Visual Studio Installer manually and add the 'Desktop development with C++' workload." -ForegroundColor Red
                exit 1
            }
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

    $vsPathResult = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPathResult) {
        Write-Host "[ERROR] Visual Studio with C++ tools not found." -ForegroundColor Red
        exit 1
    }
    return $vsPathResult
}

function Import-Vcvars {
    param([string]$VsPath, [bool]$VsIncludeV143)
    $vcvars = Join-Path $VsPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path $vcvars)) {
        Write-Host "[ERROR] vcvarsall.bat not found at $vcvars" -ForegroundColor Red
        exit 1
    }

    $vcvarsArgs = "x64"
    if ($VsIncludeV143) { $vcvarsArgs += " -vcvars_ver=14.4" }

    $envLines = cmd /c "`"$vcvars`" $vcvarsArgs > nul && set"
    foreach ($line in $envLines) {
        if ($line -match '^([^=]+)=(.*)$') {
            $name = $matches[1]
            $val = $matches[2]
            if ($name -ieq 'INCLUDE' -or $name -ieq 'LIB' -or $name -ieq 'LIBPATH') {
                Set-Item "env:$name" $val
            }
            elseif ($name -ieq 'PATH') {
                $env:PATH = $val
            }
        }
    }
}

function Install-GpuSdk {
    param([string]$VshipBackend, [bool]$VsIncludeV143)
    if ($VshipBackend -eq 'cuda' -and -not $env:CUDA_PATH) {
        if (-not $VsIncludeV143) {
            Confirm-Install "NVIDIA CUDA Toolkit 13.2" "Nvidia.CUDA"
        }
        else {
            Write-Host ""
            Write-Host "[PROMPT] NVIDIA CUDA Toolkit 12.9 is missing." -ForegroundColor Yellow
            $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
            if ($choice -ieq 'N') { Write-Host "[ERROR] CUDA Toolkit is required. Exiting." -ForegroundColor Red; exit 1 }
            Install-Cuda129
        }
        if (-not $env:CUDA_PATH) {
            Write-Host "[ERROR] CUDA_PATH still not set after install. Try restarting your terminal, or set CUDA_PATH manually." -ForegroundColor Red
            exit 1
        }
    }

    if ($VshipBackend -eq 'hip' -and -not $env:HIP_PATH) {
        Write-Host ""
        Write-Host "[PROMPT] AMD HIP SDK is missing." -ForegroundColor Yellow
        $choice = Read-Host "Do you want to install it? (Y/N) [Default: Y]"
        if ($choice -ieq 'N') { Write-Host "[ERROR] AMD HIP SDK is required. Exiting." -ForegroundColor Red; exit 1 }
        
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
}

function Install-Dependencies {
    param([string]$VshipBackend, [bool]$VsIncludeV143)

    $basicTools = [ordered]@{
        'git'   = 'Git.Git'
        'cmake' = 'Kitware.CMake'
        'ninja' = 'Ninja-build.Ninja'
        'cargo' = 'Rustlang.Rustup'
    }

    foreach ($cmd in $basicTools.Keys) {
        if (-not (Assert-Command $cmd)) {
            Confirm-Install $cmd $basicTools[$cmd]
        }
    }

    $llvmBin = "$env:ProgramFiles\LLVM\bin"
    if (-not (Assert-Command 'clang++')) {
        if (-not (Test-Path "$llvmBin\clang++.exe")) { Confirm-Install "LLVM" "LLVM.LLVM" }
    }

    $nasmpath = "$env:ProgramFiles\NASM"
    if (-not (Assert-Command 'nasm')) {
        if (-not (Test-Path "$nasmpath\nasm.exe")) { Confirm-Install "NASM" "NASM.NASM" }
    }

    Update-SessionEnvironment

    if (-not (Assert-Command 'clang')) { Write-Host "[ERROR] clang not found after LLVM setup." -ForegroundColor Red; exit 1 }
    if (-not (Assert-Command 'clang++')) { Write-Host "[ERROR] clang++ not found after LLVM setup." -ForegroundColor Red; exit 1 }
    if (-not (Assert-Command 'llvm-ar')) { Write-Host "[ERROR] llvm-ar not found after LLVM setup." -ForegroundColor Red; exit 1 }
    if (-not (Assert-Command 'nasm')) { Write-Host "[ERROR] nasm not found after NASM setup." -ForegroundColor Red; exit 1 }

    Write-Host "[INFO] Setting Rust toolchain to nightly..." -ForegroundColor Cyan
    rustup default nightly | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to set Rust toolchain to nightly." -ForegroundColor Red; exit 1
    }

    if (-not $env:VULKAN_SDK) {
        Write-Host "[INFO] Vulkan SDK is always required for the hwaccel feature." -ForegroundColor Cyan
        Confirm-Install "Vulkan SDK" "KhronosGroup.VulkanSDK"
        if (-not $env:VULKAN_SDK) { Write-Host "[ERROR] VULKAN_SDK not found. Try restarting your terminal, or set VULKAN_SDK manually." -ForegroundColor Red; exit 1 }
    }

    Install-GpuSdk -VshipBackend $VshipBackend -VsIncludeV143 $VsIncludeV143
    $msysExe = Install-Msys2
    $vsPathResult = Install-VsBuildTools -VsIncludeV143 $VsIncludeV143

    return @{
        MsysExe = $msysExe
        VsPath  = $vsPathResult
    }
}

function Build-Vship {
    param([string]$Backend, [bool]$VsIncludeV143, [string]$VsPath)
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

        switch ($Backend) {
            'cuda' {
                $msvcBin = Split-Path (Get-Command cl.exe -ErrorAction SilentlyContinue).Definition
                if (-not $msvcBin) {
                    Write-Host "[WARNING] cl.exe not found in PATH. nvcc may fail." -ForegroundColor Yellow
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
}

function Build-SvtAv1 {
    param([string]$Variant, [string]$Dir, [string]$Branch, [string]$Repo, [string]$ExtraCFlags, [string]$ArchFlags)

    $avx512Supported = Get-Avx512Supported
    $svtAvx512Flag = if ($avx512Supported) { 'ON' } else { 'OFF' }
    Write-Host "[INFO] Detected AVX512 support: $avx512Supported. SVT-AV1 will be built with -DENABLE_AVX512=$svtAvx512Flag." -ForegroundColor Cyan

    if (Test-Path $Dir) {
        Push-Location $Dir; git pull; Pop-Location
    }
    else {
        if ($Branch) {
            # depth 300 to get the git tag
            git clone --depth 300 --branch $Branch $Repo $Dir
        }
        else {
            git clone --depth 300 $Repo $Dir
        }
    }
    Push-Location $Dir
    $pgoDir = "$PWD/svt_pgo_data"
    if (Test-Path $pgoDir) { Remove-Item -Recurse -Force $pgoDir }
    New-Item -ItemType Directory $pgoDir | Out-Null

    if (Test-Path svt_build_gen) { Remove-Item -Recurse -Force svt_build_gen }

    Invoke-Step "Configuring $Variant (PGO Gen)" {
        cmake -B svt_build_gen -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF `
            -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=$svtAvx512Flag `
            -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 $ArchFlags $ExtraCFlags -fprofile-generate=$pgoDir" `
            -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 $ArchFlags $ExtraCFlags -fprofile-generate=$pgoDir" `
            -DLOG_QUIET=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DCMAKE_OUTPUT_DIRECTORY=svt_build_gen
    }

    Invoke-Step "Building $Variant (PGO Gen)" { ninja -C svt_build_gen }

    $clipFile = @("y4m", "mkv", "mp4", "webm") |
    ForEach-Object { "..\pgo_clip.$_" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

    if ($clipFile) {
        Write-Host "[INFO] $clipFile found. Using it for PGO." -ForegroundColor Cyan
    }
    else {
        $clipUrl = "https://media.xiph.org/video/derf/webm/Netflix_FoodMarket2_4096x2160_60fps_10bit_420.webm"
        $clipHash = "F625E9460AA7964855D00C4CAD535D910EC4EEC7594B4CCEB5611CB00CC5F75B"
        $clipFile = "Netflix_FoodMarket2_4096x2160_60fps_10bit_420.webm"

        if (-not (Test-Path "..\$clipFile")) {
            Write-Host "[INFO] Downloading PGO clip..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $clipUrl -OutFile "..\$clipFile"
        }

        $actualHash = (Get-FileHash "..\$clipFile" -Algorithm SHA256).Hash
        if ($actualHash -ne $clipHash) {
            Write-Host "[ERROR] PGO clip hash mismatch. Expected $clipHash, got $actualHash." -ForegroundColor Red
            exit 1
        }

        if (-not (Test-Path "..\Netflix_FoodMarket2_1920x1080_60fps_10bit_420_65f.y4m")) {
            & "..\FFmpeg\ffmpeg.exe" -hide_banner -v error -stats -y -nostdin -i "..\$clipFile" -frames:v 65 -vf "scale=1920:1080:flags=lanczos+accurate_rnd+full_chroma_int:param0=4" -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe "..\Netflix_FoodMarket2_1920x1080_60fps_10bit_420_65f.y4m"
        }
        $clipFile = "..\Netflix_FoodMarket2_1920x1080_60fps_10bit_420_65f.y4m"
    }

    Invoke-Step "PGO Run for $Variant" {
        if ($clipFile -notlike '*.y4m') {
            & "..\FFmpeg\ffmpeg.exe" -i "$clipFile" -f yuv4mpegpipe -pix_fmt yuv420p10le -strict -1 - | & ".\svt_build_gen\SvtAv1EncApp.exe" -i - -b NUL --preset 2 | Out-Host
        }
        else {
            & ".\svt_build_gen\SvtAv1EncApp.exe" -i "$clipFile" -b NUL --preset 2 | Out-Host
        }
    }

    $profdata = "$pgoDir/default.profdata"
    Invoke-Step "Merging PGO data" {
        & "llvm-profdata" merge --sparse=true -o $profdata $pgoDir | Out-Host
    }

    if (Test-Path svt_build_use) { Remove-Item -Recurse -Force svt_build_use }

    Invoke-Step "Configuring $Variant (PGO Use)" {
        cmake -B svt_build_use -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF `
            -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=$svtAvx512Flag `
            -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 $ArchFlags $ExtraCFlags -fprofile-use=$profdata" `
            -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 $ArchFlags $ExtraCFlags -fprofile-use=$profdata" `
            -DLOG_QUIET=ON -DBUILD_APPS=OFF -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DCMAKE_OUTPUT_DIRECTORY=svt_build_use
    }

    Invoke-Step "Building $Variant (PGO Use)" { ninja -C svt_build_use }
    Pop-Location
    Copy-Item "$Dir\svt_build_use\SvtAv1Enc.lib" lib\ -Force
}

function Build-Opus {
    if (Test-Path 'lib\opus.lib') {
        Write-Host "[INFO] Opus already compiled. Skipping..." -ForegroundColor Cyan
    }
    else {
        if (Test-Path 'opus') { Push-Location opus; git pull; Pop-Location }
        else { git clone --depth 1 https://gitlab.xiph.org/xiph/opus.git }
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
}

function Build-Libopusenc {
    param([string]$MsysExe)
    if (Test-Path 'lib\opusenc.lib') {
        Write-Host "[INFO] libopusenc already compiled. Skipping..." -ForegroundColor Cyan
    }
    else {
        if (Test-Path 'libopusenc') { Push-Location libopusenc; git pull; Pop-Location }
        else { git clone --depth 1 https://gitlab.xiph.org/xiph/libopusenc.git }
        Push-Location libopusenc
        Invoke-Step "Building libopusenc (MSYS2)" {
            $bashScript = @'
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
make -j$(nproc)
'@
            Set-Content -Path 'build_msys2.sh' -Value $bashScript -Encoding Ascii
            $env:MSYS2_PATH_TYPE = 'inherit'
            $unixPath = $PWD.Path -replace '\\', '/'
            & $MsysExe -lc "cd `"$unixPath`" && sh ./build_msys2.sh"
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
}

function Build-Vulkan {
    param([string]$VsPath)
    if ((Test-Path 'lib\vulkan-1.lib') -and (Test-Path 'vulkan\install\include\spirv\unified1\spirv.h')) {
        Write-Host "[INFO] Vulkan and SPIRV-Headers already compiled/installed. Skipping..." -ForegroundColor Cyan
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

        if (Test-Path 'SPIRV-Headers') { Push-Location 'SPIRV-Headers'; git pull; Pop-Location }
        else { git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git }

        Invoke-Step "Configuring SPIRV-Headers" {
            cmake -S SPIRV-Headers -B SPIRV-Headers/build -G Ninja `
                -DCMAKE_BUILD_TYPE=Release `
                -DCMAKE_INSTALL_PREFIX="$PWD/install"
        }
        Invoke-Step "Installing SPIRV-Headers" {
            ninja -C SPIRV-Headers/build install
        }

        if (Test-Path 'Vulkan-Loader') { Push-Location 'Vulkan-Loader'; git pull; Pop-Location }
        else { git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Loader.git }

        Invoke-Step "Building Vulkan Loader" {
            cmake -S Vulkan-Loader -B Vulkan-Loader/build -G Ninja `
                -DCMAKE_BUILD_TYPE=Release `
                -DCMAKE_INSTALL_PREFIX="$PWD/install" `
                -DBUILD_SHARED_LIBS=ON `
                "-DCMAKE_ASM_MASM_COMPILER=ml64.exe" `
                -DVULKAN_HEADERS_INSTALL_DIR="$PWD/install" `
                -DCMAKE_C_FLAGS_RELEASE="-flto=thin -O3 -DNDEBUG -march=native"
            ninja -C Vulkan-Loader/build
            ninja -C Vulkan-Loader/build install
        }

        Pop-Location

        Copy-Item 'vulkan\install\lib\vulkan-1.lib' 'lib\vulkan-1.lib' -Force
    }
}

# dav1d
function Build-Dav1d {
    if (Test-Path 'lib\dav1d.lib') {
        Write-Host "[INFO] dav1d already compiled. Skipping..." -ForegroundColor Cyan
    }
    else {
        if (Test-Path 'dav1d') { Push-Location dav1d; git pull; Pop-Location }
        else { git clone --depth 1 https://code.videolan.org/videolan/dav1d.git }
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
            $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$mesonMsi`" /quiet /qn ALLUSERS=1" -Wait -PassThru -Verb RunAs
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
}

function Build-FFmpeg {
    param([string]$VsPath, [string]$MsysExe)
    
    $env:INCLUDE = "$PWD\dav1d\include;$PWD\dav1d\build\include;$PWD\vulkan\install\include;$env:INCLUDE"
    $env:LIB = "$PWD\lib;$PWD\vulkan\install\lib;$env:LIB"

    if (Test-Path 'lib\avcodec.lib') {
        Write-Host "[INFO] FFmpeg already compiled. Skipping..." -ForegroundColor Cyan
    }
    else {
        if (Test-Path 'FFmpeg') { Push-Location FFmpeg; git pull; Pop-Location }
        else { git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git }
        Push-Location FFmpeg
        Invoke-Step "Building FFmpeg" {
            $bashScript = @'
#!/bin/sh
set -e
export PKG_CONFIG_PATH="$(pwd)/../dav1d/build/meson-private:$(pwd)/../vulkan/install/lib/pkgconfig"
sed -i "s|^prefix=.*|prefix=$(pwd)/../dav1d/build|" $(pwd)/../dav1d/build/meson-private/dav1d.pc
sed -i "s|^libdir=.*|libdir=\${prefix}/src|" $(pwd)/../dav1d/build/meson-private/dav1d.pc
sed -i "s|^includedir=.*|includedir=\${prefix}/../include|" $(pwd)/../dav1d/build/meson-private/dav1d.pc
sed -i "s|^Cflags:.*|Cflags: -I\${includedir} -I\${prefix}/include|" $(pwd)/../dav1d/build/meson-private/dav1d.pc

sed -i 's/if test "$cc_type" = "clang"; then/if true; then/' configure
sed -i 's/test "$cc_type" != "$ld_type" && die "LTO requires same compiler and linker"/true/' configure
# sed -i 's/-L\*) \[ "$_flags_type" = "link" \] && echo -libpath:${flag#-L} ;;/-L*) [ "$_flags_type" = "link" ] \&\& echo -libpath:${flag#-L} ;; -I*) [ "$_flags_type" = "link" ] || echo $flag ;;/g' configure
# Don't treat lld-link warnings as link failure 🤤
sed -i "s/grep -qE 'LNK4044|lld-link: warning: ignoring unknown argument'/false/" configure
./configure \
    --disable-all \
    --disable-everything \
    --cc="clang-cl" \
    --cxx="clang-cl" \
    --ld="lld-link" \
    --ar="llvm-ar" \
    --ranlib="llvm-ranlib" \
    --nm="llvm-nm" \
    --strip="llvm-strip" \
    --toolchain="msvc" \
    --enable-lto="thin" \
    --extra-cflags="-flto=thin -DNDEBUG -march=native /clang:-O3" \
    --extra-libs="dav1d.lib vulkan-1.lib" \
    --disable-shared \
    --enable-static \
    --pkg-config-flags="--static" \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-network \
    --disable-autodetect \
    --disable-debug \
    --enable-ffmpeg \
    --disable-ffprobe \
    --disable-ffplay \
    --enable-avcodec \
    --enable-avformat \
    --enable-avutil \
    --enable-avfilter \
    --enable-swscale \
    --enable-swresample \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-demuxer=matroska \
    --enable-demuxer=mov \
    --enable-demuxer=mpegts \
    --enable-demuxer=mpegps \
    --enable-demuxer=flv \
    --enable-demuxer=avi \
    --enable-demuxer=ivf \
    --enable-demuxer=yuv4mpegpipe \
    --enable-muxer=yuv4mpegpipe \
    --enable-muxer=null \
    --enable-demuxer=h264 \
    --enable-demuxer=hevc \
    --enable-demuxer=vvc \
    --enable-decoder=ffv1 \
    --enable-decoder=rawvideo \
    --enable-encoder=wrapped_avframe \
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
    --enable-hwaccel=vp9_vulkan \
    --enable-filter=scale \
    --enable-filter=format
make -j$(nproc)
'@
            Set-Content -Path 'build_ffmpeg.sh' -Value $bashScript -Encoding Ascii
            $env:MSYS2_PATH_TYPE = 'inherit'
            $unixPath = $PWD.Path -replace '\\', '/'
            & $MsysExe -lc "cd `"$unixPath`" && sh ./build_ffmpeg.sh"
        }
        Pop-Location
        Copy-Item 'FFmpeg\libavcodec\avcodec.lib' 'lib\avcodec.lib' -Force
        Copy-Item 'FFmpeg\libavformat\avformat.lib' 'lib\avformat.lib' -Force
        Copy-Item 'FFmpeg\libavutil\avutil.lib' 'lib\avutil.lib' -Force
        Copy-Item 'FFmpeg\libswresample\swresample.lib' 'lib\swresample.lib' -Force
        Copy-Item 'FFmpeg\libswscale\swscale.lib' 'lib\swscale.lib' -Force
    }
}

function Build-Xav {
    param([string]$Backend, [string]$SvtChoice, [bool]$enableTQ)
    $env:RUSTFLAGS = @(
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
    ) -join ' '

    $features = "static"
    if ($enableTQ) {
        $features += ",vship"
        if ($Backend -eq 'cuda') { $features += ",nvidia" }
        elseif ($Backend -eq 'hip') { $features += ",amd" }
    }

    if ($SvtChoice -eq '3') {
        $features += ",5fish"
    }

    Invoke-Step "Cargo build ($Backend)" {
        cargo update
        if ($enableTQ) {
            cargo build --release --features $features
        }
        else {
            cargo build --release --features $features --no-default-features
        }
    }

    Write-Host ""
    if (-not (Test-Path 'target\release')) { New-Item -ItemType Directory 'target\release' | Out-Null }
    # We don't need the dll since the gpu driver already provides it, but since we already compiled it, why not
    if (-not (Test-Path 'target\release\vulkan-1.dll')) { Copy-Item 'vulkan\install\bin\vulkan-1.dll' 'target\release\vulkan-1.dll' -Force }
}

# main

Write-Host "Compile with target quality feature?"
$tqChoice = Read-Host "Enter choice (Y/N) [Default: Y]"
if (-not $tqChoice) { $tqChoice = 'Y' }

$enableTQ = $tqChoice -ieq 'Y'

if ($enableTQ) {
    Write-Host ""
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
}
else {
    $vshipBackend = 'none'
}

Write-Host ""
Write-Host "Select SVT-AV1 variant to compile:"
Write-Host "  1. svt-av1-hdr       (https://github.com/juliobbv-p/svt-av1-hdr)"
Write-Host "  2. svt-av1-essential (https://github.com/nekotrix/SVT-AV1-Essential)"
Write-Host "  3. 5fish             (https://github.com/5fish/svt-av1-psy)"
Write-Host "  4. svt-av1-tritium yis branch [testing only, do not use] (https://github.com/Uranite/svt-av1-tritium/tree/yis)"
Write-Host "  5. svt-av1-essential yiss fork [testing only, do not use] (https://github.com/Uranite/SVT-AV1-Essential)"
$svtChoice = Read-Host "Enter choice (1-5) [Default: 1]"
if (-not $svtChoice) { $svtChoice = '1' }

switch ($svtChoice) {
    '1' { $svtVariant = 'svt-av1-hdr'; $svtRepo = 'https://github.com/juliobbv-p/svt-av1-hdr.git'; $svtBranch = ''; $svtDir = 'svt-av1-hdr'; $svtExtraCFlags = '' }
    '2' { $svtVariant = 'svt-av1-essential'; $svtRepo = 'https://github.com/nekotrix/SVT-AV1-Essential.git'; $svtBranch = ''; $svtDir = 'SVT-AV1-Essential'; $svtExtraCFlags = '' }
    '3' { $svtVariant = '5fish'; $svtRepo = 'https://github.com/5fish/svt-av1-psy.git'; $svtBranch = ''; $svtDir = '5fish-svt-av1-psy'; $svtExtraCFlags = '-DSVT_LOG_QUIET' }
    '4' { $svtVariant = 'svt-av1-tritium-yis'; $svtRepo = 'https://github.com/Uranite/svt-av1-tritium.git'; $svtBranch = 'yis'; $svtDir = 'svt-av1-tritium-yis'; $svtExtraCFlags = '' }
    '5' { $svtVariant = 'svt-av1-essential-yis'; $svtRepo = 'https://github.com/Uranite/svt-av1-essential.git'; $svtBranch = ''; $svtDir = 'svt-av1-essential-yis'; $svtExtraCFlags = '' }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Select target architecture for SVT-AV1:"
Write-Host "  1. znver2          (-march=znver2 -mno-gather)"
Write-Host "  2. icelake-server  (-march=icelake-server -mtune=znver5 -mprefer-vector-width=512)"
Write-Host "  3. native          (-march=native)"
Write-Host "  4. x86-64-v3       (-march=x86-64-v3 -mno-gather)"
Write-Host "  5. skylake         (-march=skylake -mno-gather)"
Write-Host "  6. haswell         (-march=haswell -mno-gather)"
$archChoice = Read-Host "Enter choice (1-6) [Default: 1]"
if (-not $archChoice) { $archChoice = '1' }

switch ($archChoice) {
    '1' { $svtArchFlags = "-march=znver2 -mno-gather" }
    '2' { $svtArchFlags = "-march=icelake-server -mtune=znver5 -mprefer-vector-width=512" }
    '3' { $svtArchFlags = "-march=native" }
    '4' { $svtArchFlags = "-march=x86-64-v3 -mno-gather" }
    '5' { $svtArchFlags = "-march=skylake -mno-gather" }
    '6' { $svtArchFlags = "-march=haswell -mno-gather" }
    default {
        Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
        exit 1
    }
}

$env:CC = 'clang'
$env:CXX = 'clang++'

# Detect NVIDIA GPU generation when CUDA is selected.
# Latest CUDA for Turing and newer
# CUDA 12.9 for Pascal and older
$vsIncludeV143 = $false
$cudaWingetId = 'Nvidia.CUDA'

if ($vshipBackend -eq 'cuda') {
    $gpuName = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'NVIDIA' } |
    Select-Object -ExpandProperty Name -First 1

    if (-not $gpuName) {
        Write-Host "[WARNING] Could not detect NVIDIA GPU. Defaulting to CUDA 12.9 with MSVC v143." -ForegroundColor Yellow
        $vsIncludeV143 = $true
        $cudaWingetId = $null
    }

    Write-Host "[INFO] Detected GPU: $gpuName" -ForegroundColor Cyan

    $computeCap = $null
    try {
        $capOutput = & nvidia-smi --query-gpu=compute_cap --format="csv,noheader" 2>$null
        if ($capOutput) {
            $computeCap = [double](($capOutput | Select-Object -First 1).Trim())
        }
    }
    catch { }

    if ($null -ne $computeCap) {
        $isTuringOrNewer = $computeCap -ge 7.5
    }
    else {
        Write-Host "[WARNING] Could not query compute capability via nvidia-smi. Falling back to name parsing." -ForegroundColor Yellow
        $isTuringOrNewer = $gpuName -match 'RTX|GTX 16|TITAN RTX'
    }

    if ($isTuringOrNewer) {
        Write-Host "[INFO] Turing or newer detected. Using latest CUDA version." -ForegroundColor Cyan
        $vsIncludeV143 = $false
        $cudaWingetId = 'Nvidia.CUDA'
    }
    else {
        Write-Host "[INFO] Pascal or older detected. Using CUDA 12.9 with MSVC v143" -ForegroundColor Cyan
        $vsIncludeV143 = $true
        $cudaWingetId = $null
    }
}

$depResults = Install-Dependencies -VshipBackend $vshipBackend -VsIncludeV143 $vsIncludeV143
$msysExe = $depResults.MsysExe
$vsPath = $depResults.VsPath

Import-Vcvars -VsPath $vsPath -VsIncludeV143 $vsIncludeV143

if (-not (Test-Path 'lib')) { New-Item -ItemType Directory 'lib' }

if ($enableTQ) {
    Build-Vship -Backend $vshipBackend -VsIncludeV143 $vsIncludeV143 -VsPath $vsPath
}
Build-Dav1d
Build-Opus
Build-Libopusenc -MsysExe $msysExe
Build-Vulkan -VsPath $vsPath
Build-FFmpeg -VsPath $vsPath -MsysExe $msysExe
Build-SvtAv1 -Variant $svtVariant -Dir $svtDir -Branch $svtBranch -Repo $svtRepo -ExtraCFlags $svtExtraCFlags -ArchFlags $svtArchFlags
Build-Xav -Backend $vshipBackend -SvtChoice $svtChoice -enableTQ $enableTQ

Write-Host "[SUCCESS] Build script finished." -ForegroundColor Green
