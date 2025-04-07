{
  description = "Aider - AI pair programming in your terminal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

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

  outputs = { self, nixpkgs, flake-utils, uv2nix, pyproject-nix, pyproject-build-systems, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };
        python = pkgs.python311;
        inherit (nixpkgs) lib;

        # Load the uv workspace
        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

        # Create package overlay from workspace
        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel"; # prefer binary wheels
        };

        # Add overlay for additional packages or overrides
        # Extend generated overlay with build fixups
        extraOverlay = final: prev: {
          # # Add any necessary overrides here
          # aider-chat = prev.aider-chat.overrideAttrs (old: {
          #   nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.makeWrapper ];
          #   propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [
          #     pkgs.git
          #   ];
          #
          #   postInstall = ''
          #     wrapProgram $out/bin/aider \
          #       --set PYTHONPATH "${placeholder "out"}/${python.sitePackages}:$PYTHONPATH"
          #   '';
          # });
          #
          # # Create a package alias for backward compatibility
          # aider = final.aider-chat;
        };

        # Construct Python package set
        pythonSet =
          (pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          }).overrideScope
            (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.default
                overlay
                extraOverlay
              ]
            );

        # aider = pythonSet.aider;
        
      in
      {
        # packages = {
        #   inherit aider;
        #   default = aider;
        # };
        #
        # apps.default = flake-utils.lib.mkApp {
        #   drv = aider;
        #   name = "aider";
        # };


        # Package a virtual environment as our main application.
        #
        # Enable no optional dependencies for production build.
        packages.default = pythonSet.mkVirtualEnv "aider-env" workspace.deps.default;

        # Make hello runnable with `nix run`
        apps.x86_64-linux = {
          default = {
            type = "app";
            program = "${self.packages.x86_64-linux.default}/bin/aider";
          };
        };

        devShells = {
        
          impure = pkgs.mkShell {
            packages = [
              # aider
              python
              pkgs.uv
            ];
    
            env = {
              # Prevent uv from managing Python downloads
              UV_PYTHON_DOWNLOADS = "never";
              # Force uv to use nixpkgs Python interpreter
              UV_PYTHON = python.interpreter;
              # Ensure Python can find the package
              # PYTHONPATH = "${aider}/${python.sitePackages}:$PYTHONPATH";
            }// lib.optionalAttrs pkgs.stdenv.isLinux {
                # Python libraries often load native shared objects using dlopen(3).
                # Setting LD_LIBRARY_PATH makes the dynamic library loader aware of libraries without using RPATH for lookup.
                LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
    
            shellHook = ''
              unset PYTHONPATH
            '';
          };




          pure = let
            # Create an overlay enabling editable mode for all local dependencies.
            editableOverlay = workspace.mkEditablePyprojectOverlay {
              root = "$REPO_ROOT";
            };

            # Override previous set with our overrideable overlay.
            editablePythonSet = pythonSet.overrideScope (
              lib.composeManyExtensions [
                editableOverlay
                (final: prev: {
                  # Make setuptools available to all packages
                  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
                    (pyFinal: pyPrev: {
                      setuptools = pyPrev.setuptools;
                      pip = pyPrev.pip;
                      wheel = pyPrev.wheel;
                    })
                  ];

                  # Fix pyperclip build
                  pyperclip = prev.pyperclip.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      final.setuptools
                      final.pip
                      final.wheel
                    ];
                    format = "pyproject";
                  });

                  # Add cusparse override
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

                  # Add cusolver override
                  nvidia-cusolver-cu12 = prev.nvidia-cusolver-cu12.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
                    buildInputs = (old.buildInputs or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                    ];
                    
                    # Add runtime dependencies
                    runtimeDependencies = (old.runtimeDependencies or []) ++ [
                      pkgs.cudaPackages.cuda_cudart
                      pkgs.cudaPackages.libcublas
                      pkgs.cudaPackages.libcusparse
                      pkgs.cudaPackages.libnvjitlink
                    ];

                    # Set RPATH for the libraries
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

                  # Override torch to use CUDA-enabled version
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
                      
                      # Create lib directory
                      mkdir -p $out/lib
                      
                      # Create symlinks for CUDNN
                      ln -s ${pkgs.cudaPackages.cudnn}/lib/libcudnn.so* $out/lib/
                      
                      # Find the torch lib directory
                      TORCH_LIB_DIR=$(find $out/lib/python*/site-packages/torch/lib -type d | head -n 1)
                      
                      # Ensure the torch lib directory exists
                      mkdir -p "$TORCH_LIB_DIR"
                      
                      # Copy CUDNN libraries directly to torch lib directory
                      cp -P ${pkgs.cudaPackages.cudnn}/lib/libcudnn.so* "$TORCH_LIB_DIR/"
                    '';

                    preFixup = ''
                      # Add CUDA libraries to RPATH
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

                      # Add the output lib directory to RPATH
                      TORCH_LIBS="$out/lib:$out/lib/python*/site-packages/torch/lib"
                      
                      # Patch all torch libraries
                      for lib in $out/lib/python*/site-packages/torch/lib/lib*.so*; do
                        if [ -f "$lib" ]; then
                          echo "Patching RPATH for $lib"
                          patchelf --set-rpath "$TORCH_LIBS:$CUDA_LIBS" "$lib"
                        fi
                      done
                    '';

                    # Modified autoPatchelfHook configuration
                    autoPatchelfIgnoreMissingDeps = true;
                    
                    postFixup = ''
                      # Run auto-patchelf with specific library paths
                      addAutoPatchelfSearchPath ${pkgs.cudaPackages.cudnn}/lib
                      addAutoPatchelfSearchPath $out/lib
                      addAutoPatchelfSearchPath $out/lib/python*/site-packages/torch/lib
                      
                      autoPatchelf "$out"
                      
                      # Verify CUDNN is properly linked
                      if ! ldd $out/lib/python*/site-packages/torch/lib/libtorch_cuda.so | grep -q libcudnn.so.8; then
                        echo "Warning: libcudnn.so.8 not found in libtorch_cuda.so dependencies"
                        exit 1
                      fi
                    '';
                  });

                  # Fix imgcat build
                  imgcat = prev.imgcat.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
                      final.setuptools
                      final.pip
                      final.wheel
                    ];
                    format = "pyproject";
                  });

                  # Fix aider-chat build
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

            # Build virtual environment with local packages being editable
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
                
              # Add CUDA library paths
              LD_LIBRARY_PATH = lib.makeLibraryPath [
                pkgs.cudaPackages.cuda_cudart
                pkgs.cudaPackages.libcublas  # This includes libcublasLt
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
      });
}
