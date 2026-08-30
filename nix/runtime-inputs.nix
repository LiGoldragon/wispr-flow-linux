{
  fetchurl,
  stdenv,
}:
let
  assets = {
    x86_64-linux = {
      helper = {
        url = "https://github.com/wispr-flow-linux/helper/releases/download/v0.1.2/wispr-flow-linux-helper-x86_64";
        hash = "sha256-gnbc7SNqoDo8SZOp4Er2PDkFHuWMK5rLDAixwQHZGeQ=";
      };
      betterSqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/better_sqlite3-x86_64.node";
        hash = "sha256-omxv7HC7bTHDhglJGwORuOrfPZwsxYTVTxYBhX4JDj8=";
      };
      sqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/node_sqlite3-x86_64.node";
        hash = "sha256-yb0EGfd++ztdOmkf2gTiZfdArY3BlfC1YAPN6skumjQ=";
      };
      provenance = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/native-modules-x86_64.lock";
        hash = "sha256-2ZXd27xHK21iv72SS0vO0xMGj/x5ufQ1AQnKWHK9V6Y=";
      };
      helperInterpreter = "/lib64/ld-linux-x86-64.so.2";
    };
    aarch64-linux = {
      helper = {
        url = "https://github.com/wispr-flow-linux/helper/releases/download/v0.1.2/wispr-flow-linux-helper-aarch64";
        hash = "sha256-/8N9r5Cqbp/Msxeyee4jsoZgRiAkz/OSdAu7lMNiDdc=";
      };
      betterSqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/better_sqlite3-aarch64.node";
        hash = "sha256-UMAJvqy2usjulV3Yk0GLS2ymNvuMXQsH2qXqdEAL+Vc=";
      };
      sqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/node_sqlite3-aarch64.node";
        hash = "sha256-olwTlEnNCFLyQs4qrPwEAzxin3RWazMdR2Ye61B7Pbw=";
      };
      provenance = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/native-modules-aarch64.lock";
        hash = "sha256-bf3qwTCW+c+Vra/wZt6rkE0MmbAb+kIGZSlzFeTCmm0=";
      };
      helperInterpreter = "/lib/ld-linux-aarch64.so.1";
    };
  };
  selected =
    assets.${stdenv.hostPlatform.system}
      or (throw "wispr-flow: unsupported platform ${stdenv.hostPlatform.system}");
in
rec {
  helper = fetchurl (selected.helper // { executable = true; });
  betterSqlite = fetchurl selected.betterSqlite;
  sqlite = fetchurl selected.sqlite;
  provenance = fetchurl selected.provenance;

  helperVersion = "v0.1.2";
  nativeModulesVersion = "native-v1";
  electronAbi = "146";
  electronVersion = "42.3.0";
  helperInterpreter = selected.helperInterpreter;
}
