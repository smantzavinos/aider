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
        pkgs = nixpkgs.legacyPackages.${system};
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

        devShells.default = pkgs.mkShell {
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
      });
}
