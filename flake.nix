{
  description = "aider development environment";

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

  outputs = { self, nixpkgs, flake-utils, uv2nix, pyproject-nix, pyproject-build-systems }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;

        # Use existing requirements.txt as lock file
        workspace = uv2nix.lib.workspace.loadWorkspace { 
          workspaceRoot = ./.;
          lockFile = ./requirements.txt;
        };

        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };

        # Handle tree-sitter version differences
        pyprojectOverrides = final: prev: {
          tree-sitter = if python.pythonVersion >= "3.10" then
            prev.tree-sitter.override { version = "0.24.0"; }
          else
            prev.tree-sitter.override { version = "0.23.2"; };
        };

        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope (
          nixpkgs.lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            pyprojectOverrides
          ]
        );

        editableOverlay = workspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT";
        };

        editablePythonSet = pythonSet.overrideScope editableOverlay;
        virtualenv = editablePythonSet.mkVirtualEnv "aider-dev-env" workspace.deps.all;

      in {
        # Default package is the production virtualenv
        packages.default = pythonSet.mkVirtualEnv "aider-env" workspace.deps.default;

        # Development shell with editable install
        devShells.default = pkgs.mkShell {
          packages = [
            virtualenv
          ];

          shellHook = ''
            export REPO_ROOT=$(git rev-parse --show-toplevel)
          '';
        };

        # Make aider runnable with `nix run`
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/aider";
        };
      }
    );
}
