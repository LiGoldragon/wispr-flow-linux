{
  binutils,
  file,
  jq,
  runCommand,
  runtimeInputs,
}:
runCommand "wispr-flow-runtime-inputs-check"
  {
    nativeBuildInputs = [
      binutils
      file
      jq
    ];
  }
  ''
    test -x ${runtimeInputs.helper}
    ${binutils}/bin/readelf -l ${runtimeInputs.helper} | grep -F \
      'Requesting program interpreter: ${runtimeInputs.helperInterpreter}'

    for module in ${runtimeInputs.betterSqlite} ${runtimeInputs.sqlite}; do
      test "$(file -Lb "$module" | cut -d, -f1)" = 'ELF 64-bit LSB shared object'
    done

    jq -e --arg abi '${runtimeInputs.electronAbi}' \
      --arg electron '${runtimeInputs.electronVersion}' '
        .abi == $abi and .electron_version == $electron
      ' ${runtimeInputs.provenance} >/dev/null

    mkdir -p "$out/Release" \
      "$out/app.asar.unpacked/.webpack/main/native_modules/build/Release"
    install -m755 ${runtimeInputs.helper} "$out/Release/wispr-flow-linux-helper"
    install -m644 ${runtimeInputs.betterSqlite} \
      "$out/app.asar.unpacked/.webpack/main/native_modules/build/Release/better_sqlite3.node"
    install -m644 ${runtimeInputs.sqlite} \
      "$out/app.asar.unpacked/.webpack/main/native_modules/build/Release/node_sqlite3.node"
  ''
