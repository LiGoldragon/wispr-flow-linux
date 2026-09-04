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
          wispr-flow = pkgs.callPackage ./nix/wispr-flow.nix { inherit runtimeInputs; };
          signedInstaller = pkgs.fetchurl {
            url = "https://dl.wisprflow.com/wispr-flow/win32/x64/Wispr%20Flow%20Setup-v1.6.774.exe";
            hash = "sha256-/TDvdPEDSCQeSmSrT8ZhkITsW3EIzcZETDwpBiCGG+s=";
          };
        in
        {
          # A real package derivation. It fetches the immutable signed installer
          # itself, then executes the extract, patch, repack, and archive
          # verification path used for deployment.
          package-artifact = wispr-flow;

          package-source-contract =
            let
              runtimeInputs = pkgs.callPackage ./nix/runtime-inputs.nix { };
              wispr-flow = pkgs.callPackage ./nix/wispr-flow.nix { inherit runtimeInputs; };
              packageArgs = builtins.functionArgs (import ./nix/wispr-flow.nix);
            in
            assert builtins.hasAttr "runtimeInputs" packageArgs;
            assert builtins.hasAttr "fetchurl" packageArgs;
            assert !(builtins.hasAttr "installerExe" packageArgs);
            assert wispr-flow.drvPath != "";
            pkgs.runCommand "wispr-flow-package-source-contract" { } ''
              touch "$out"
            '';

          helper-runtime-contract = pkgs.callPackage ./nix/helper-runtime-contract.nix {
            inherit runtimeInputs;
          };

          status-bootstrap = pkgs.callPackage ./nix/wispr-status-bootstrap-check.nix {
            inherit wispr-flow;
          };

          linux-patches =
            pkgs.runCommand "wispr-flow-linux-patches"
              {
                nativeBuildInputs = [
                  pkgs.bats
                  pkgs.nodejs
                  pkgs.python3
                  pkgs.p7zip
                  pkgs.asar
                ];
              }
              ''
                mkdir payload
                7z x -y ${signedInstaller} -opayload/installer >/dev/null
                nupkg=$(find payload/installer -iname '*-full.nupkg' | head -1)
                test -n "$nupkg"
                7z x -y "$nupkg" -opayload/nupkg >/dev/null
                asar extract payload/nupkg/lib/net45/resources/app.asar payload/app
                export WISPR_FLOW_AUDIT_APP="$PWD/payload/app"
                bats --print-output-on-failure \
                  ${self}/tests/linux-patches.bats \
                  ${self}/tests/verify-patches.bats \
                  ${self}/tests/status-bridge.bats \
                  ${self}/tests/signed-payload-patches.bats
                touch "$out"
              '';
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
