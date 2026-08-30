{
  description = "Wispr Flow voice dictation for Linux (unofficial)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      # The payload is the proprietary Wispr Flow app, so the derivation is
      # marked unfree. Import nixpkgs with an allowance scoped to just our
      # package names — consumers `nix build`-ing from this flake don't need to
      # set NIXPKGS_ALLOW_UNFREE themselves.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [
              "wispr-flow"
            ];
        };
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          runtimeInputs = pkgs.callPackage ./nix/runtime-inputs.nix { };
          wispr-flow = pkgs.callPackage ./nix/wispr-flow.nix { inherit runtimeInputs; };
          wispr-flow-fhs = pkgs.callPackage ./nix/fhs.nix { inherit wispr-flow; };
        in
        {
          inherit wispr-flow wispr-flow-fhs;
          # FHS wrapper is the recommended default (provides the glibc loader
          # Electron needs on NixOS).
          default = wispr-flow-fhs;
        }
      );

      checks = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          runtimeInputs = pkgs.callPackage ./nix/runtime-inputs.nix { };
        in
        {
          wispr-flow-linux-patches = pkgs.callPackage ./nix/patches-check.nix { };
          wispr-flow-runtime = pkgs.callPackage ./nix/runtime-check.nix {
            inherit runtimeInputs;
          };
          wispr-flow-helper-keypress = pkgs.callPackage ./nix/helper-keypress-check.nix {
            inherit runtimeInputs;
          };
        }
      );

      # Overlay so the packages can be consumed from another flake's nixpkgs.
      overlays.default =
        final: prev:
        let
          runtimeInputs = final.callPackage ./nix/runtime-inputs.nix { };
          wispr-flow = final.callPackage ./nix/wispr-flow.nix { inherit runtimeInputs; };
        in
        {
          inherit wispr-flow;
          wispr-flow-fhs = final.callPackage ./nix/fhs.nix { inherit wispr-flow; };
        };
    };
}
