{
  bash,
  bats,
  coreutils,
  lib,
  nodejs,
  python3,
  runCommand,
}:
let
  sourceRoot = lib.cleanSource ./..;
in
runCommand "wispr-flow-linux-patches-check"
  {
    nativeBuildInputs = [
      bash
      bats
      coreutils
      nodejs
      python3
    ];
  }
  ''
    bats \
      ${sourceRoot}/tests/launcher-common.bats \
      ${sourceRoot}/tests/linux-patches.bats \
      ${sourceRoot}/tests/verify-patches.bats

    touch "$out"
  ''
