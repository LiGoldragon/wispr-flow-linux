{
  autoPatchelfHook,
  lib,
  runCommand,
  runtimeInputs,
  stdenv,
}:
let
  helperTag = lib.trim (builtins.readFile ../helper-version.txt);
  helperVersion = lib.removePrefix "v" helperTag;
in
runCommand "wispr-flow-helper-runtime-contract"
  {
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
  }
  ''
    cp ${runtimeInputs.helper} helper
    chmod u+w helper
    autoPatchelf helper

    actual="$(./helper --version)"
    expected='wispr-flow-linux-helper ${helperVersion}'
    test "$actual" = "$expected"
    touch "$out"
  ''
