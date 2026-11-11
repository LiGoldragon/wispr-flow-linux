# better-sqlite3-multiple-ciphers, compiled from its published npm source
# against the headers of the very Electron the package runs on, so the addon's
# V8 ABI always equals the Electron it is loaded into.  The output holds the one
# file `better_sqlite3.node`.
#
# The source-compat patch (scripts/patches/v8-14.8-*.patch) is guarded by
# V8_MAJOR_VERSION and covers the V8 API breaks of V8 13 and later; it applies
# to the V8 of every Electron this package has targeted (14.8 and 15.0).
{
  lib,
  stdenv,
  fetchurl,
  nodejs,
  python3,
  electron_43,
}:
let
  version = "12.5.0";
  electronVersion = electron_43.passthru.unwrapped.version;
in
stdenv.mkDerivation {
  pname = "better-sqlite3-multiple-ciphers-electron";
  version = "${version}+electron${electronVersion}";

  src = fetchurl {
    url = "https://registry.npmjs.org/better-sqlite3-multiple-ciphers/-/better-sqlite3-multiple-ciphers-${version}.tgz";
    hash = "sha256-OEHRfPobATdtMx6Qh/3NBvflXiLXyPEmoT8ATvEugDU=";
  };
  sourceRoot = "package";

  patches = [ ../scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch ];

  nativeBuildInputs = [
    nodejs
    python3
  ];

  # Electron's own headers (node + V8), not the system Node's.
  nodeDirectory = electron_43.passthru.unwrapped.headers;
  nodeGyp = "${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js";

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    node "$nodeGyp" rebuild --release --nodedir="$nodeDirectory" -j"$NIX_BUILD_CORES"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm 0644 build/Release/better_sqlite3.node "$out/better_sqlite3.node"
    runHook postInstall
  '';

  # The addon must load in the Electron it was built for and open an encrypted
  # database: this asserts the ABI rather than trusting the header path.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # The unpacked source tree still holds build/Release/better_sqlite3.node,
    # which the package's own loader resolves.
    export EXPECTED_ABI=$(sed -n 's/^#define NODE_MODULE_VERSION \([0-9]*\)$/\1/p' "$nodeDirectory/include/node/node_version.h")
    test -n "$EXPECTED_ABI"
    ELECTRON_RUN_AS_NODE=1 ${electron_43.passthru.unwrapped}/libexec/electron/electron - <<'JS'
    const Database = require("./lib");
    if (process.versions.modules !== process.env.EXPECTED_ABI) process.exit(2);
    const addon = require("path").resolve("build/Release/better_sqlite3.node");
    const path = require("path").join(process.env.TMPDIR, "check.db");
    let db = new Database(path, { nativeBinding: addon });
    db.pragma("cipher='sqlcipher'");
    db.pragma("key='abi-check'");
    db.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('ok')");
    db.close();
    db = new Database(path, { nativeBinding: addon });
    db.pragma("cipher='sqlcipher'");
    db.pragma("key='abi-check'");
    if (db.prepare("SELECT v FROM t").get().v !== "ok") process.exit(1);
    JS
    runHook postInstallCheck
  '';

  meta = {
    description = "better-sqlite3-multiple-ciphers built for Electron ${electronVersion}";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
