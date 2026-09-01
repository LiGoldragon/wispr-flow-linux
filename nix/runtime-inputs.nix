{ fetchurl, stdenv }:
let
  assets = {
    x86_64-linux = {
      helper = {
        url = "https://github.com/LiGoldragon/helper/releases/download/v0.1.3/wispr-flow-linux-helper-x86_64";
        hash = "sha256-wOV0Rn2hzECCVo7ngTx0RTGrhGWz4t56aQcQ3wSilK8=";
      };
      betterSqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/better_sqlite3-x86_64.node";
        hash = "sha256-omxv7HC7bTHDhglJGwORuOrfPZwsxYTVTxYBhX4JDj8=";
      };
      sqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/node_sqlite3-x86_64.node";
        hash = "sha256-yb0EGfd++ztdOmkf2gTiZfdArY3BlfC1YAPN6skumjQ=";
      };
    };
    aarch64-linux = {
      helper = {
        url = "https://github.com/LiGoldragon/helper/releases/download/v0.1.3/wispr-flow-linux-helper-aarch64";
        hash = "sha256-azv26fd8PN5ysaybRocytdaQeOMd88ovaj7VZsOTbmU=";
      };
      betterSqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/better_sqlite3-aarch64.node";
        hash = "sha256-UMAJvqy2usjulV3Yk0GLS2ymNvuMXQsH2qXqdEAL+Vc=";
      };
      sqlite = {
        url = "https://github.com/wispr-flow-linux/native-modules/releases/download/native-v1/node_sqlite3-aarch64.node";
        hash = "sha256-olwTlEnNCFLyQs4qrPwEAzxin3RWazMdR2Ye61B7Pbw=";
      };
    };
  };
  selected =
    assets.${stdenv.hostPlatform.system}
      or (throw "wispr-flow: unsupported system ${stdenv.hostPlatform.system}");
in
{
  helper = fetchurl (selected.helper // { executable = true; });
  betterSqlite = fetchurl selected.betterSqlite;
  sqlite = fetchurl selected.sqlite;
}
