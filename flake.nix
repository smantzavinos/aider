{
  description = "Aider - AI pair programming in your terminal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      
      perSystem = { config, self', inputs', pkgs, system, lib, ... }: let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
        python = pkgs.python311;

        inherit (pkgs.callPackage inputs.pyproject-nix.build.util { }) mkApplication;

        # Load the uv workspace
        workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

        # Create package overlay from workspace
        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel"; # prefer binary wheels
        };

        # Add overlay for additional packages or overrides
        extraOverlay = final: prev: { };

        # Construct Python package set
        pythonSet =
          (pkgs.callPackage inputs.pyproject-nix.build.packages {
            inherit python;
          }).overrideScope
            (
              lib.composeManyExtensions [
                inputs.pyproject-build-systems.overlays.default
                overlay
                extraOverlay
              ]
            );

      in {
        packages = {
          default = let
            venv = pythonSet.mkVirtualEnv "aider-env" (workspace.deps.default // {
              nativeBuildInputs = [
                pythonSet.setuptools
                pythonSet.pip
                pythonSet.wheel
                pythonSet.setuptools-scm
              ];
              buildInputs = [
                pythonSet.setuptools
                pythonSet.setuptools-scm
              ];
            });
          in (mkApplication {
            inherit venv;
            package = pythonSet.aider-chat;
          }).overrideAttrs (old: {
            meta = (old.meta or {}) // {
              mainProgram = "aider";
            };
            
            # Add runtime dependencies
            propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [
              pythonSet.setuptools
              pythonSet.pip
              pythonSet.wheel
            ];
          });
        };

        apps = {
          default = {
            type = "app";
            program = "${self'.packages.default}/bin/aider";
          };
        };

        devShells = {
          impure = pkgs.mkShell {
            packages = [
              python
              pkgs.uv
            ];
    
            env = {
              UV_PYTHON_DOWNLOADS = "never";
              UV_PYTHON = python.interpreter;
            } // lib.optionalAttrs pkgs.stdenv.isLinux {
              LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
    
            shellHook = ''
              unset PYTHONPATH
            '';
          };

          pure = let
            editableOverlay = workspace.mkEditablePyprojectOverlay {
              root = "$REPO_ROOT";
            };

            editablePythonSet = pythonSet.overrideScope (
              lib.composeManyExtensions [
                editableOverlay
                (final: prev: {
                  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
                    (pyFinal: pyPrev: {
                      setuptools = pyPrev.setuptools;
                      pip = pyPrev.pip;
                      wheel = pyPrev.wheel;
                    })
                  ];

                  pyperclip = prev.pyperclip.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      final.setuptools
                      final.pip
                      final.wheel
                    ];
                    buildInputs = (old.buildInputs or []) ++ [
                      final.setuptools
                    ];
                    format = "pyproject";
                  });

                  nvidia-cusparse-cu12 = prev.nvidia-cusparse-cu12.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
                    buildInputs = (old.buildInputs or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libnvjitlink
                    ];
                    
                    runtimeDependencies = (old.runtimeDependencies or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libnvjitlink
                    ];

                    postFixup = ''
                      ${old.postFixup or ""}
                      patchelf --set-rpath "${pkgs.lib.makeLibraryPath [
                        pkgs.cudaPackages.cuda_cudart
                        pkgs.cudaPackages.libnvjitlink
                      ]}" $out/lib/python*/site-packages/nvidia/cusparse/lib/libcusparse.so.12
                    '';
                  });

                  nvidia-cusolver-cu12 = prev.nvidia-cusolver-cu12.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
                    buildInputs = (old.buildInputs or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                    ];
                    
                    runtimeDependencies = (old.runtimeDependencies or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                    ];

                    postFixup = ''
                      ${old.postFixup or ""}
                      patchelf --set-rpath "${pkgs.lib.makeLibraryPath [
                        pkgs.cudaPackages.cuda_cudart
                        pkgs.cudaPackages.libcublas
                        pkgs.cudaPackages.libcusparse
                        pkgs.cudaPackages.libnvjitlink
                      ]}" $out/lib/python*/site-packages/nvidia/cusolver/lib/libcusolver.so.11
                      
                      patchelf --set-rpath "${pkgs.lib.makeLibraryPath [
                        pkgs.cudaPackages.cuda_cudart
                        pkgs.cudaPackages.libcublas
                        pkgs.cudaPackages.libcusparse
                        pkgs.cudaPackages.libnvjitlink
                      ]}" $out/lib/python*/site-packages/nvidia/cusolver/lib/libcusolverMg.so.11
                    '';
                  });

                  torch = prev.torch.overrideAttrs (old: {
                    cudaSupport = true;
                    
                    buildInputs = (old.buildInputs or []) ++ [
                      pkgs.cudaPackages.cuda_nvcc
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.cuda_nvrtc
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusolver
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                      pkgs.cudaPackages.cudnn
                      pkgs.cudaPackages.nccl
                      pkgs.cudaPackages.libcufft
                      pkgs.cudaPackages.libcurand
                      pkgs.cudaPackages.cuda_cupti
                      pkgs.cudaPackages.cuda_nvtx
                      final.nvidia-cusolver-cu12
                    ];

                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      pkgs.autoPatchelfHook
                      pkgs.makeWrapper
                    ];

                    runtimeDependencies = (old.runtimeDependencies or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusolver
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                      pkgs.cudaPackages.cudnn
                      pkgs.cudaPackages.nccl
                      pkgs.cudaPackages.libcufft
                      pkgs.cudaPackages.libcurand
                      pkgs.cudaPackages.cuda_cupti
                      pkgs.cudaPackages.cuda_nvtx
                      final.nvidia-cusolver-cu12
                      final.nvidia-cusparse-cu12
                    ];

                    postInstall = ''
                      ${old.postInstall or ""}
                      mkdir -p $out/lib
                      ln -s ${pkgs.cudaPackages.cudnn}/lib/libcudnn.so* $out/lib/
                      mkdir -p "$out/lib/python3.11/site-packages/torch/lib"
                      for f in ${pkgs.cudaPackages.cudnn}/lib/libcudnn.so*; do
                        if [ -f "$f" ]; then
                          cp -P "$f" "$out/lib/python3.11/site-packages/torch/lib/"
                        fi
                      done
                    '';

                    preFixup = ''
                      CUDA_LIBS="${lib.makeLibraryPath ([
                        pkgs.cudaPackages.cuda_cudart
                        pkgs.cudaPackages.libcublas
                        pkgs.cudaPackages.libcusolver
                        pkgs.cudaPackages.libcusparse
                        pkgs.cudaPackages.libnvjitlink
                        pkgs.cudaPackages.cudnn
                        pkgs.cudaPackages.nccl
                        pkgs.cudaPackages.libcufft
                        pkgs.cudaPackages.libcurand
                        pkgs.cudaPackages.cuda_cupti
                        pkgs.cudaPackages.cuda_nvtx
                        final.nvidia-cusolver-cu12
                        final.nvidia-cusparse-cu12
                      ])}"

                      TORCH_LIBS="$out/lib:$out/lib/python*/site-packages/torch/lib"
                      
                      for lib in $out/lib/python*/site-packages/torch/lib/lib*.so*; do
                        if [ -f "$lib" ]; then
                          echo "Patching RPATH for $lib"
                          patchelf --set-rpath "$TORCH_LIBS:$CUDA_LIBS" "$lib"
                        fi
                      done
                    '';

                    autoPatchelfIgnoreMissingDeps = true;
                    
                    postFixup = ''
                      addAutoPatchelfSearchPath ${pkgs.cudaPackages.cudnn}/lib
                      addAutoPatchelfSearchPath $out/lib
                      addAutoPatchelfSearchPath $out/lib/python*/site-packages/torch/lib
                      
                      autoPatchelf "$out"
                      
                      if ! ldd $out/lib/python*/site-packages/torch/lib/libtorch_cuda.so | grep -q libcudnn.so.8; then
                        echo "Warning: libcudnn.so.8 not found in libtorch_cuda.so dependencies"
                        exit 1
                      fi
                    '';
                  });

                  imgcat = prev.imgcat.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      final.setuptools
                      final.pip
                      final.wheel
                    ];
                    format = "pyproject";
                  });

                  aider-chat = prev.aider-chat.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      final.setuptools
                      final.setuptools-scm
                      final.tomli
                      final.pip
                      final.wheel
                    ];
                    buildInputs = (old.buildInputs or []) ++ [
                      final.tomli
                    ];
                    format = "pyproject";
                  });
                })
              ]
            );

            virtualenv = editablePythonSet.mkVirtualEnv "aider-dev-env" workspace.deps.all;

          in pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];

            nativeBuildInputs = [
              python
              python.pkgs.setuptools
              python.pkgs.pip
              python.pkgs.wheel
            ];

            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = "${virtualenv}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
              PYTHONPATH = lib.makeSearchPath python.sitePackages [virtualenv];
                
              LD_LIBRARY_PATH = lib.makeLibraryPath [
                pkgs.cudaPackages.cuda_cudart
                pkgs.cudaPackages.libcublas
                pkgs.cudaPackages.libcusolver
                pkgs.cudaPackages.libcusparse
                pkgs.cudaPackages.libnvjitlink
              ];
            };

            shellHook = ''
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        };
      };
    };
}
