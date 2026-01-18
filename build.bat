@echo off
setlocal enabledelayedexpansion

echo Select Vship backend to compile:
echo 1. CUDA
echo 2. HIP
echo 3. Vulkan
set /p VSHIP_CHOICE="Enter choice (1-3) [Default: 1]: "

if "!VSHIP_CHOICE!"=="" set VSHIP_CHOICE=1

if "!VSHIP_CHOICE!"=="1" (
    set VSHIP_BACKEND=cuda
    set CMAKE_TOOLSET_ARG=-T v143
    set MSBUILD_TOOLSET_ARG=/p:PlatformToolset=v143
    set VCVARS_ARG=-vcvars_ver=14.4
) else if "!VSHIP_CHOICE!"=="2" (
    set VSHIP_BACKEND=hip
    set CMAKE_TOOLSET_ARG=
    set MSBUILD_TOOLSET_ARG=/p:PlatformToolset=v143
    set VCVARS_ARG=
) else if "!VSHIP_CHOICE!"=="3" (
    set VSHIP_BACKEND=vulkan
    set CMAKE_TOOLSET_ARG=
    set MSBUILD_TOOLSET_ARG=/p:PlatformToolset=v143
    set VCVARS_ARG=
) else (
    echo [ERROR] Invalid choice.
    pause
    exit /b 1
)

REM --- Install System Dependencies via winget ---
echo [INFO] Checking basic system dependencies...
where git >nul 2>nul
if %errorlevel% neq 0 (
    call :prompt_install "Git" "Git.Git"
    if errorlevel 1 exit /b 1
)

where cmake >nul 2>nul
if %errorlevel% neq 0 (
    call :prompt_install "CMake" "Kitware.CMake"
    if errorlevel 1 exit /b 1
)

where clang++ >nul 2>nul
if %errorlevel% neq 0 (
    call :prompt_install "LLVM" "LLVM.LLVM"
    if errorlevel 1 exit /b 1
)

where ninja >nul 2>nul
if %errorlevel% neq 0 (
    call :prompt_install "Ninja" "Ninja-build.Ninja"
    if errorlevel 1 exit /b 1
)

where cargo >nul 2>nul
if %errorlevel% neq 0 (
    call :prompt_install "Rust (rustup)" "Rustlang.Rustup"
    if errorlevel 1 exit /b 1
    echo [INFO] Setting Rust toolchain to nightly...
    rustup default nightly
    if errorlevel 1 (
        echo [ERROR] Failed to set Rust toolchain to nightly.
        pause
        exit /b 1
    )
    echo [WARNING] Rust was just installed. Please restart your terminal and re-run this script.
    pause
    exit /b 0
)

REM Visual Studio Build Tools
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    call :prompt_install "Visual Studio Build Tools" "Microsoft.VisualStudio.2022.BuildTools"
    if errorlevel 1 exit /b 1
)

if "!VSHIP_BACKEND!"=="cuda" (
    if not defined CUDA_PATH (
        call :prompt_install "NVIDIA CUDA Toolkit" "Nvidia.CUDA"
        if errorlevel 1 exit /b 1
        echo [WARNING] CUDA was just installed. You may need to restart your terminal or PC for CUDA_PATH to take effect.
    )
)

if "!VSHIP_BACKEND!"=="hip" (
    if not defined HIP_PATH (
        echo [INFO] Downloading AMD HIP SDK...
        curl -L -o "%TEMP%\AMD-HIP-Setup.exe" "https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q1-Win11-For-HIP.exe"
        if errorlevel 1 (
            echo [ERROR] Failed to download AMD HIP SDK.
            pause
            exit /b 1
        )
        echo [INFO] Installing AMD HIP SDK (this may take a while)...
        "%TEMP%\AMD-HIP-Setup.exe" -install
        if errorlevel 1 (
            echo [ERROR] AMD HIP SDK installation failed.
            pause
            exit /b 1
        )
        echo [WARNING] HIP was just installed. Please restart your terminal or PC for HIP_PATH to take effect.
    )
)

if "!VSHIP_BACKEND!"=="vulkan" (
    if not defined VULKAN_SDK (
        call :prompt_install "Vulkan SDK" "KhronosGroup.VulkanSDK"
        if errorlevel 1 exit /b 1
        echo [WARNING] Vulkan was just installed. You may need to restart your terminal or PC for VULKAN_SDK to take effect.
    )
)

REM --- Locate Visual Studio ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo [ERROR] vswhere.exe missing. Please install VS Build Tools manually.
    pause
    exit /b 1
)

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
    set "VS_PATH=%%i"
)
if not defined VS_PATH (
    echo [ERROR] Visual Studio with C++ tools not found.
    pause
    exit /b 1
)

REM --- Setup MSVC Environment ---
if "!VSHIP_BACKEND!"=="cuda" (
    echo [INFO] Forcing v143 toolset for CUDA compatibility...
    call "%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat" !VCVARS_ARG!
) else (
    call "%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat"
)

where cl.exe >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] MSVC cl.exe not found after vcvars setup.
    pause
    exit /b 1
)

if not defined VCPKG_ROOT (
    echo.
    echo [PROMPT] vcpkg is not installed (VCPKG_ROOT not set).
    set /p INSTALL_CHOICE="Do you want to install it to C:\vcpkg? (Y/N) [Default: Y]: "
    if /I "!INSTALL_CHOICE!"=="N" (
        echo [ERROR] vcpkg is required. Please install it manually and set VCPKG_ROOT.
        pause
        exit /b 1
    )
    echo [INFO] Installing vcpkg to C:\vcpkg...
    if not exist "C:\vcpkg" (
        git clone https://github.com/microsoft/vcpkg.git "C:\vcpkg"
        if errorlevel 1 (
            echo [ERROR] Failed to clone vcpkg.
            pause
            exit /b 1
        )
    )
    call "C:\vcpkg\bootstrap-vcpkg.bat" -disableMetrics
    if errorlevel 1 (
        echo [ERROR] vcpkg bootstrap failed.
        pause
        exit /b 1
    )
    setx VCPKG_ROOT "C:\vcpkg"
    if errorlevel 1 (
        echo [ERROR] Failed to set VCPKG_ROOT permanently.
        pause
        exit /b 1
    )
    set "VCPKG_ROOT=C:\vcpkg"
    echo [INFO] VCPKG_ROOT set permanently to C:\vcpkg
)

REM --- vcpkg Dependencies ---
echo [INFO] Installing required vcpkg dependencies...
"%VCPKG_ROOT%\vcpkg.exe" install ffmpeg[avcodec,avdevice,avfilter,avformat,swresample,swscale,zlib,bzip2,core,dav1d,gpl,version3,lzma,openssl,xml2]:x64-windows-static
call :check_error "vcpkg install failed" || exit /b 1

REM --- Compile Vship ---
if exist lib\vship\!VSHIP_BACKEND!\libvship.lib (
    echo [INFO] Vship for !VSHIP_BACKEND! already compiled. Skipping...
    copy /Y "lib\vship\!VSHIP_BACKEND!\libvship.lib" "lib\" >nul
    goto skip_vship
)

if exist Vship (
    pushd Vship
    git pull
) else (
    git clone https://codeberg.org/Line-fr/Vship.git
    pushd Vship
)

if "!VSHIP_BACKEND!"=="cuda" goto compile_cuda
if "!VSHIP_BACKEND!"=="hip" goto compile_hip
if "!VSHIP_BACKEND!"=="vulkan" goto compile_vulkan

:compile_cuda
REM --- Compile Vship CUDA ---
if not defined CUDA_PATH (
    echo [ERROR] CUDA_PATH not set. Please install CUDA and restart.
    pause
    exit /b 1
)
"%CUDA_PATH%\bin\nvcc.exe" -x cu src/VshipLib.cpp -std=c++17 -I include -arch=all -Xcompiler /MT --lib -o libvship.lib
call :check_error "CUDA compilation failed" || ( popd & exit /b 1 )

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\cuda" mkdir "..\lib\vship\cuda"
copy /Y libvship.lib "..\lib\vship\cuda\"
goto compile_vship_done

:compile_hip
REM --- Compile Vship HIP ---
if not defined HIP_PATH (
    echo [ERROR] HIP_PATH not set. Please install HIP SDK and restart.
    pause
    exit /b 1
)
call "%HIP_PATH%\bin\hipcc" -c src/VshipLib.cpp -std=c++17 -I include --offload-arch=gfx1201,gfx1200,gfx1100,gfx1101,gfx1102,gfx1103,gfx1151,gfx1012,gfx1030,gfx1031,gfx1032,gfx906,gfx801,gfx802,gfx803 -Wno-unused-result -Wno-ignored-attributes -o libvship.o
call :check_error "HIP compilation failed" || ( popd & exit /b 1 )

if exist libvship.lib del libvship.lib
llvm-ar rcs libvship.lib libvship.o
call :check_error "llvm-ar (HIP) failed" || ( popd & exit /b 1 )

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\hip" mkdir "..\lib\vship\hip"
copy /Y libvship.lib "..\lib\vship\hip\"
goto compile_vship_done

:compile_vulkan
REM --- Compile Vship Vulkan ---
if not defined VULKAN_SDK (
    echo [ERROR] VULKAN_SDK not set. Please install Vulkan SDK and restart.
    pause
    exit /b 1
)
clang++ src/Vulkan/spvFileToCppHeader.cpp -std=c++17 -O2 -o shaderEmbedder.exe
call :check_error "shaderEmbedder compilation failed" || ( popd & exit /b 1 )

shaderEmbedder libvshipSpvShaders include/libvshipSpvShaders.hpp
call :check_error "shaderEmbedder execution failed" || ( popd & exit /b 1 )

clang++ -c src/VshipLib.cpp -DVULKANBUILD -DNDEBUG -std=c++17 -O2 -Wall -Wno-ignored-attributes -Wno-unused-variable -Wno-nullability-completeness -Wno-unused-private-field -I include -I "%VULKAN_SDK%\Include" -o libvship.o
call :check_error "Vulkan compilation failed" || ( popd & exit /b 1 )

if exist libvship.lib del libvship.lib
llvm-ar rcs libvship.lib libvship.o
call :check_error "llvm-ar (Vulkan) failed" || ( popd & exit /b 1 )

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\vulkan" mkdir "..\lib\vship\vulkan"
copy /Y libvship.lib "..\lib\vship\vulkan\"
goto compile_vship_done

:compile_vship_done
popd

:skip_vship

REM --- Compile Opus ---
if exist lib\opus.lib (
    echo [INFO] Opus already compiled. Skipping...
    goto skip_opus
)

if exist opus (
    pushd opus
    git pull
) else (
    git clone https://gitlab.xiph.org/xiph/opus.git
    pushd opus
)
cmake --fresh -B build -G Ninja -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG"
call :check_error "Opus CMake configure failed" || ( popd & exit /b 1 )
ninja -C build
call :check_error "Opus build failed" || ( popd & exit /b 1 )
popd
if not exist lib mkdir lib
copy /Y opus\build\opus.lib lib\

:skip_opus

REM --- Compile libopusenc ---
if exist lib\opusenc.lib (
    echo [INFO] libopusenc already compiled. Skipping...
    goto skip_libopusenc
)

if exist libopusenc (
    pushd libopusenc
    git pull
    popd
) else (
    git clone https://gitlab.xiph.org/xiph/libopusenc.git
    pushd libopusenc
    popd
)
pushd libopusenc\win32\VS2015
REM Disabling WholeProgramOptimization to avoid LTO conflicts with clang-compiled libs.
msbuild opusenc.sln /p:Configuration=Release /p:Platform=x64 /p:WholeProgramOptimization=false !MSBUILD_TOOLSET_ARG!
call :check_error "libopusenc build failed" || ( popd & exit /b 1 )
popd
if not exist lib mkdir lib
copy /Y libopusenc\win32\VS2015\x64\Release\opusenc.lib lib\

:skip_libopusenc

REM --- Compile FFMS2 ---
if exist ffms2\lib\ffms2.lib (
    echo [INFO] FFMS2 already compiled. Skipping...
    goto skip_ffms2
)

if exist ffms2 (
    pushd ffms2
    git pull
) else (
    git clone https://github.com/Uranite/ffms2.git
    pushd ffms2
)
cmake --fresh -B ffms2_build -G Ninja -DBUILD_SHARED_LIBS=OFF -DENABLE_AVISYNTH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE="-flto -O3 -DNDEBUG" -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG"
call :check_error "ffms2 CMake configure failed" || ( popd & exit /b 1 )
ninja -C ffms2_build
call :check_error "FFMS2 build failed" || ( popd & exit /b 1 )
popd

if not exist ffms2\lib mkdir ffms2\lib
copy /Y ffms2\ffms2_build\ffms2.lib ffms2\lib\

set "FFMS_LIB_DIR=%CD%\ffms2\lib"
set "FFMS_INCLUDE_DIR=%CD%\ffms2\include"
setx FFMS_LIB_DIR "%CD%\ffms2\lib"
setx FFMS_INCLUDE_DIR "%CD%\ffms2\include"
echo [INFO] FFMS_LIB_DIR set to %FFMS_LIB_DIR%
echo [INFO] FFMS_INCLUDE_DIR set to %FFMS_INCLUDE_DIR%

:skip_ffms2

REM --- Compile svt-av1-hdr ---
if exist lib\SvtAv1Enc.lib (
    echo [INFO] svt-av1-hdr already compiled. Skipping...
    goto skip_svt_av1
)

if exist svt-av1-hdr (
    pushd svt-av1-hdr
    git pull
) else (
    git clone https://github.com/juliobbv-p/svt-av1-hdr.git
    pushd svt-av1-hdr
)
cmake --fresh -B svt_build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=ON -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2" -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2" -DLOG_QUIET=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
call :check_error "svt-av1-hdr CMake configure failed" || ( popd & exit /b 1 )
ninja -C svt_build
call :check_error "svt-av1-hdr build failed" || ( popd & exit /b 1 )
popd

if not exist lib mkdir lib
copy /Y svt-av1-hdr\Bin\Release\SvtAv1Enc.lib lib

:skip_svt_av1

REM --- Cargo Build ---
if "!VSHIP_BACKEND!"=="cuda" (
    echo [INFO] Building Cargo project for CUDA...
    cargo build --release --features "static,vship,nvidia,vcpkg,libsvtav1" --config "build.rustflags=['-C', 'debuginfo=0', '-C', 'target-cpu=native', '-C', 'opt-level=3', '-C', 'codegen-units=1', '-C', 'strip=symbols', '-C', 'panic=abort', '-C', 'linker=lld-link', '-C', 'lto=fat', '-C', 'embed-bitcode=yes', '-Z', 'dylib-lto', '-Z', 'panic_abort_tests', '-C', 'target-feature=+crt-static']"
    call :check_error "Cargo build (CUDA) failed" || exit /b 1
) else if "!VSHIP_BACKEND!"=="hip" (
    echo [INFO] Building Cargo project for AMD ^(HIP^)...
    cargo build --release --features "static,vship,amd,vcpkg,libsvtav1" --config "build.rustflags=['-C', 'debuginfo=0', '-C', 'target-cpu=native', '-C', 'opt-level=3', '-C', 'codegen-units=1', '-C', 'strip=symbols', '-C', 'panic=abort', '-C', 'linker=lld-link', '-C', 'lto=fat', '-C', 'embed-bitcode=yes', '-Z', 'dylib-lto', '-Z', 'panic_abort_tests', '-C', 'target-feature=+crt-static']"
    call :check_error "Cargo build (HIP) failed" || exit /b 1
) else if "!VSHIP_BACKEND!"=="vulkan" (
    echo [INFO] Building Cargo project for Vulkan...
    cargo build --release --features "static,vship,vcpkg,libsvtav1" --config "build.rustflags=['-C', 'debuginfo=0', '-C', 'target-cpu=native', '-C', 'opt-level=3', '-C', 'codegen-units=1', '-C', 'strip=symbols', '-C', 'panic=abort', '-C', 'linker=lld-link', '-C', 'lto=fat', '-C', 'embed-bitcode=yes', '-Z', 'dylib-lto', '-Z', 'panic_abort_tests', '-C', 'target-feature=+crt-static']"
    call :check_error "Cargo build (Vulkan) failed" || exit /b 1
)

echo.
echo [SUCCESS] Build script finished.
endlocal
pause
exit /b 0

REM ============================================================
REM  Subroutines
REM ============================================================

:check_error
if %errorlevel% neq 0 (
    echo [ERROR] %~1
    pause
    exit /b 1
)
exit /b 0

:prompt_install
set "APP_NAME=%~1"
set "WINGET_ID=%~2"

echo.
echo [PROMPT] %APP_NAME% is missing.
set /p INSTALL_CHOICE="Do you want to install it using winget? (Y/N) [Default: Y]: "
if /I "!INSTALL_CHOICE!"=="N" (
    echo [INFO] Skipping installation of %APP_NAME%.
    exit /b 0
)

echo [INFO] Installing %APP_NAME%...
winget install --id %WINGET_ID% -e --source winget --accept-source-agreements --accept-package-agreements
call :check_error "Failed to install %APP_NAME%"
exit /b %errorlevel%