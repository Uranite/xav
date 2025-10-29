use std::env;
use std::path::PathBuf;

fn main() {
    if cfg!(target_os = "windows") {
        if cfg!(feature = "dynamic") {
            println!("cargo:rustc-link-lib=ffms2");
            println!("cargo:rustc-link-lib=libvship");
        }
    }
    if cfg!(feature = "static") {
        if cfg!(target_os = "windows") {
            let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

            let mut lib_path = PathBuf::from(&manifest_dir);
            lib_path.push("lib");
            println!("cargo:rustc-link-search=native={}", lib_path.display());

            #[cfg(feature = "vship")]
            {
                if !cfg!(feature = "amd") && !cfg!(feature = "nvidia") {
                    println!("cargo:warning=The 'vship' feature is enabled, but neither 'amd' nor 'nvidia' is selected. Please enable one, e.g., --features vship,amd");
                }

                #[cfg(feature = "amd")]
                {
                    println!("cargo:rustc-link-lib=static=libvship-amd");
                    match env::var("HIP_PATH") {
                        Ok(hip_path) => {
                            let hip_lib_path = std::path::Path::new(&hip_path).join("lib");
                            println!("cargo:rustc-link-search=native={}", hip_lib_path.display());
                        },
                        Err(_) => {
                            println!("cargo:warning=HIP_PATH environment variable not set.");
                        }
                    }
                    println!("cargo:rustc-link-lib=static=amdhip64");
                }

                #[cfg(feature = "nvidia")]
                {
                    println!("cargo:rustc-link-lib=static=libvship");
                    match env::var("CUDA_PATH") {
                        Ok(cuda_path) => {
                            let cuda_lib_path = std::path::Path::new(&cuda_path).join("lib").join("x64");
                            println!("cargo:rustc-link-search=native={}", cuda_lib_path.display());
                            println!("cargo:rustc-link-lib=static=cudart_static");
                        },
                        Err(_) => {
                            println!("cargo:warning=CUDA_PATH environment variable not set.");
                        }
                    }
                    println!("cargo:rustc-link-lib=static=cudart_static");
                }
            }

            #[cfg(feature = "use-vcpkg")]
            {
                vcpkg::Config::new()
                    .emit_includes(true)
                    .find_package("ffmpeg")
                    .expect("Failed to find ffmpeg via vcpkg");
            }

            #[cfg(not(feature = "use-vcpkg"))]
            {
                let mut ffmpeg_lib_path = PathBuf::from(&manifest_dir);
                ffmpeg_lib_path.push("ffmpeg");
                ffmpeg_lib_path.push("lib");
                println!("cargo:rustc-link-search=native={}", ffmpeg_lib_path.display());

                println!("cargo:rustc-link-lib=static=avformat");
                println!("cargo:rustc-link-lib=static=avcodec");
                println!("cargo:rustc-link-lib=static=swscale");
                println!("cargo:rustc-link-lib=static=swresample");
                println!("cargo:rustc-link-lib=static=avutil");
                println!("cargo:rustc-link-lib=static=lzma");
                println!("cargo:rustc-link-lib=static=dav1d");
                println!("cargo:rustc-link-lib=static=bcrypt");
                println!("cargo:rustc-link-lib=static=zlib");
                println!("cargo:rustc-link-lib=static=libssl");
                println!("cargo:rustc-link-lib=static=libcrypto");
                println!("cargo:rustc-link-lib=static=iconv");
                println!("cargo:rustc-link-lib=static=libxml2");
                println!("cargo:rustc-link-lib=static=bz2");
            }
            println!("cargo:rustc-link-lib=static=bcrypt");
            println!("cargo:rustc-link-lib=mfuuid");
            println!("cargo:rustc-link-lib=strmiids");
            println!("cargo:rustc-link-lib=advapi32");
            println!("cargo:rustc-link-lib=crypt32");
            println!("cargo:rustc-link-lib=user32");
            println!("cargo:rustc-link-lib=ole32");
        } else {
            let home = env::var("HOME").expect("HOME environment variable not set");
            println!("cargo:rustc-link-search=native={home}/.local/src/FFmpeg/install/lib");
            println!("cargo:rustc-link-search=native={home}/.local/src/dav1d/build/src");
            println!("cargo:rustc-link-search=native={home}/.local/src/zlib/install/lib");

            println!("cargo:rustc-link-lib=static=swscale");
            println!("cargo:rustc-link-lib=static=avformat");
            println!("cargo:rustc-link-lib=static=avcodec");
            println!("cargo:rustc-link-lib=static=avutil");
            println!("cargo:rustc-link-lib=static=dav1d");
            println!("cargo:rustc-link-lib=static=z");
            println!("cargo:rustc-link-lib=static=stdc++");

            #[cfg(feature = "vship")]
            {
                println!("cargo:rustc-link-search=native={home}/.local/src/Vship");

                println!("cargo:rustc-link-lib=static=vship");

                println!("cargo:rustc-link-lib=static=cudart_static");
                println!("cargo:rustc-link-search=native=/opt/cuda/lib64");

                println!("cargo:rustc-link-lib=dylib=cuda");
            }
        }
    }
}
