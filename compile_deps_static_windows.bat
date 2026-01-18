@echo off
setlocal enabledelayedexpansion

REM untested
REM --- Prerequisites: LLVM, CUDA Toolkit, HIP SDK, Vulkan SDK, Git, CMake, FFmpeg(vcpkg) ---
REM Please set your VCPKG_ROOT env variable after installing vcpkg

REM --- Select Vship Backend ---
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
    set MSBUILD_TOOLSET_ARG=/p:PlatformToolset=v145
    set VCVARS_ARG=
) else if "!VSHIP_CHOICE!"=="3" (
    set VSHIP_BACKEND=vulkan
    set CMAKE_TOOLSET_ARG=
    set MSBUILD_TOOLSET_ARG=/p:PlatformToolset=v145
    set VCVARS_ARG=
) else (
    echo [ERROR] Invalid choice.
    pause
    exit /b 1
)

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" ( echo [ERROR] vswhere.exe missing. & pause & exit /b 1 )

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
    set "VS_PATH=%%i"
)
if not exist "%VS_PATH%" ( echo [ERROR] Visual Studio not found. & pause & exit /b 1 )

REM --- Setup Environment ---
if "!VSHIP_BACKEND!"=="cuda" (
    echo Forcing v143 toolset for CUDA compatibility...
    call "%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat" !VCVARS_ARG!
) else (
    call "%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat"
)

where cl.exe >nul 2>nul
if %errorlevel% neq 0 ( echo [ERROR] MSVC toolset not found. & pause & exit /b 1 )

where cmake >nul 2>nul
if %errorlevel% neq 0 ( echo [ERROR] CMake not found. & pause & exit /b 1 )

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
if not defined CUDA_PATH ( echo [ERROR] CUDA_PATH not set. & pause & exit /b 1 )
"%CUDA_PATH%\bin\nvcc.exe" -x cu src/VshipLib.cpp -std=c++17 -I include -arch=all -Xcompiler /MT --lib -o libvship.lib
call :check_error "CUDA compilation failed"

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\cuda" mkdir "..\lib\vship\cuda"
copy /Y libvship.lib "..\lib\vship\cuda\"
goto compile_vship_done

:compile_hip
REM --- Compile Vship HIP ---
if not defined HIP_PATH ( echo [ERROR] HIP_PATH not set. & pause & exit /b 1 )
call "%HIP_PATH%\bin\hipcc" -c src/VshipLib.cpp -std=c++17 -I include --offload-arch=gfx1201,gfx1200,gfx1100,gfx1101,gfx1102,gfx1103,gfx1151,gfx1012,gfx1030,gfx1031,gfx1032,gfx906,gfx801,gfx802,gfx803 -Wno-unused-result -Wno-ignored-attributes -o libvship.o
call :check_error "HIP compilation failed"

if exist libvship.lib del libvship.lib
llvm-ar rcs libvship.lib libvship.o
call :check_error "llvm-ar (HIP) failed"

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\hip" mkdir "..\lib\vship\hip"
copy /Y libvship.lib "..\lib\vship\hip\"
goto compile_vship_done

:compile_vulkan
REM --- Compile Vship Vulkan ---
if not defined VULKAN_SDK ( echo [ERROR] VULKAN_SDK not set. & pause & exit /b 1 )
clang++ src/Vulkan/spvFileToCppHeader.cpp -std=c++17 -O2 -o shaderEmbedder.exe
call :check_error "shaderEmbedder compilation failed"

shaderEmbedder libvshipSpvShaders include/libvshipSpvShaders.hpp
call :check_error "shaderEmbedder execution failed"

clang++ -c src/VshipLib.cpp -DVULKANBUILD -DNDEBUG -std=c++17 -O2 -Wall -Wno-ignored-attributes -Wno-unused-variable -Wno-nullability-completeness -Wno-unused-private-field -I include -I "%VULKAN_SDK%\Include" -o libvship.o
call :check_error "Vulkan compilation failed"

if exist libvship.lib del libvship.lib
llvm-ar rcs libvship.lib libvship.o
call :check_error "llvm-ar (Vulkan) failed"

if not exist "..\lib" mkdir "..\lib"
copy /Y libvship.lib "..\lib\"
if not exist "..\lib\vship\vulkan" mkdir "..\lib\vship\vulkan"
copy /Y libvship.lib "..\lib\vship\vulkan\"
goto compile_vship_done

:compile_vship_done
popd

REM --- Compile Opus ---
if exist opus (
    pushd opus
    git pull
) else (
    git clone https://gitlab.xiph.org/xiph/opus.git
    pushd opus
)
cmake --fresh -B build -G Ninja -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG"
call :check_error "Opus CMake configure failed"
ninja -C build
call :check_error "Opus build failed"
popd
if not exist lib mkdir lib
copy /Y opus\build\opus.lib lib\

REM --- Compile libopusenc ---
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
REM We need to disable WholeProgramOptimization if we're going to mix with clang-compiled LTO libsvtav1, ffms2, and opus.
REM alternatively, we could create a cmake build system for libopusenc, and compile libopusenc with clang.
msbuild opusenc.sln /p:Configuration=Release /p:Platform=x64 /p:WholeProgramOptimization=false !MSBUILD_TOOLSET_ARG!
call :check_error "libopusenc build failed"
popd
if not exist lib mkdir lib
copy /Y libopusenc\win32\VS2015\x64\Release\opusenc.lib lib\

REM --- Compile FFMS2 ---
if exist ffms2 (
    pushd ffms2
    git pull
) else (
    git clone https://github.com/Uranite/ffms2.git
    pushd ffms2
)
cmake --fresh -B ffms2_build -G Ninja -DBUILD_SHARED_LIBS=OFF -DENABLE_AVISYNTH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE="-flto -O3 -DNDEBUG" -DCMAKE_C_FLAGS_RELEASE="-flto -O3 -DNDEBUG"
call :check_error "ffms2 CMake configure failed"
ninja -C ffms2_build
REM msbuild /t:Rebuild !MSBUILD_TOOLSET_ARG! /m /p:Configuration=Release /p:Platform=x64 "./build-msvc/ffms2.sln"
call :check_error "FFMS2 build failed"
popd

if not exist ffms2\lib mkdir ffms2\lib
copy /Y ffms2\ffms2_build\ffms2.lib ffms2\lib\

if exist svt-av1-hdr (
    pushd svt-av1-hdr
    git pull
) else (
    git clone https://github.com/juliobbv-p/svt-av1-hdr.git
    pushd svt-av1-hdr
)
REM --- Compile svt-av1-hdr ---
cmake --fresh -B svt_build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DSVT_AV1_LTO=OFF -DLIBDOVI_FOUND=0 -DLIBHDR10PLUS_RS_FOUND=0 -DENABLE_AVX512=ON -DCMAKE_CXX_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2" -DCMAKE_C_FLAGS_RELEASE="-flto -DNDEBUG -O2 -march=znver2" -DLOG_QUIET=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
call :check_error "svt-av1-hdr CMake configure failed"
ninja -C svt_build
call :check_error "svt-av1-hdr build failed"
popd

if not exist lib mkdir lib
copy /Y svt-av1-hdr\Bin\Release\SvtAv1Enc.lib lib

echo.
echo [SUCCESS] Build script finished.
endlocal
pause
exit /b 0

:check_error
if %errorlevel% neq 0 (
    echo [ERROR] %~1
    pause
    exit /b %errorlevel%
)
exit /b 0