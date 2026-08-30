{
  lib,
  stdenvNoCC,
  electron_42,
  p7zip,
  icoutils,
  imagemagick,
  nodejs,
  asar,
  makeDesktopItem,
  python3,
  bash,
  rsync,
  runtimeInputs,
  writeText,
  # Path to the Wispr Flow installer .exe you obtained yourself. This build never
  # fetches the proprietary app (see the Source block below for how to supply it).
  installerExe ? null,
}:
let
  pname = "wispr-flow";
  version = "1.6.7";

  #============================================================================
  # Source: the user-supplied Wispr Flow Windows installer (a Squirrel .exe).
  #
  # This build NEVER fetches the proprietary app — you provide the installer you
  # obtained yourself, mirroring `build.sh --exe`. Supply it either way:
  #
  #   * impure env var (the flake default):
  #       WISPR_FLOW_EXE="/abs/path/Wispr Flow Setup-v${version}.exe" \
  #         nix build .#wispr-flow-fhs --impure
  #
  #   * package override (overlay / non-flake callers):
  #       wispr-flow.override { installerExe = /abs/path/to/Setup.exe; }
  #
  # Wispr ships only a win32/x64 installer (no win32/arm64 variant is known), so
  # the aarch64 build reuses the same x64 .exe — the payload is the
  # cross-platform Electron app; the helper and native modules are selected per
  # architecture below, so one .exe drives both outputs.
  #============================================================================
  installerEnv = builtins.getEnv "WISPR_FLOW_EXE";
  installerProvided = installerExe != null || installerEnv != "";
  resolvedExe =
    if installerExe != null then
      installerExe
    else if installerEnv != "" then
      /. + installerEnv
    else
      null;

  # Copy the supplied .exe into the store under a fixed, space-free name so the
  # derivation hash is independent of where the file lived on disk.
  src =
    if installerProvided then
      builtins.path {
        path = resolvedExe;
        name = "wispr-flow-setup-${version}.exe";
      }
    else
      writeText "wispr-flow-missing-installer" ''
        wispr-flow: no installer supplied. This build never downloads the
        proprietary Wispr Flow app — provide the Setup .exe you obtained yourself:

          WISPR_FLOW_EXE="/abs/path/Wispr Flow Setup-v${version}.exe" \
          nix build .#wispr-flow-fhs --impure

        or override the package:
          wispr-flow.override { installerExe = /abs/path/to/Setup.exe; }
      '';

  # Repo root, used to reach scripts/ from the build.
  # build-reference / build-linux / extract / result are excluded so a dirty
  # working tree does not bust the derivation hash.
  sourceRoot = lib.cleanSourceWith {
    src = ./..;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ./.. + "/") path;
      in
      !(lib.hasPrefix "build-linux" rel)
      && !(lib.hasPrefix "extract" rel)
      && !(lib.hasPrefix "logs" rel)
      && !(lib.hasPrefix "tools" rel)
      && !(lib.hasPrefix "result" rel);
  };

  # The unwrapped electron derivation holds the real ELF + Chromium resources
  # (.pak files, locales/, etc.). We copy the ELF into our own tree so that
  # /proc/self/exe — and therefore process.resourcesPath — resolves to a dir
  # that contains the app's resources, not stock electron's.
  electronUnwrapped = electron_42.passthru.unwrapped or electron_42;
  electronDir = "${electronUnwrapped}/libexec/electron";

  desktopItem = makeDesktopItem {
    name = "wispr-flow";
    exec = "wispr-flow %U";
    icon = "wispr-flow";
    type = "Application";
    terminal = false;
    desktopName = "Wispr Flow";
    genericName = "Voice Dictation";
    comment = "Voice dictation that types into your focused app";
    startupWMClass = "Wispr Flow";
    categories = [
      "Utility"
      "AudioVideo"
      "Audio"
    ];
    keywords = [
      "voice"
      "dictation"
      "speech"
      "transcription"
    ];
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    p7zip
    nodejs
    asar
    icoutils
    imagemagick
    bash
    python3
    rsync
  ];

  # The installer is a Squirrel .exe, not a standard archive — unpack manually.
  dontUnpack = true;

  #==========================================================================
  # Build phase.
  #
  # COUPLING DECISION: this does NOT call `build.sh --build nix`. The Wispr
  # build.sh delegates staging to scripts/build-linux.sh, whose Electron
  # download, @electron/asar fetch, and better-sqlite3 native ABI rebuild are
  # network/toolchain steps that cannot run inside the Nix sandbox. Instead we
  # replicate the deterministic extract -> patch -> repack steps here using
  # nixpkgs tooling (p7zip, asar, nodejs) and the committed patch scripts under
  # scripts/patches/. The reference flake's `build.sh --build nix` works only
  # because its build.sh stages everything inline; ours doesn't, so calling the
  # staging scripts' deterministic parts directly is the cleaner path.
  #
  # Native modules and the helper follow the proven packaging pipeline: they are
  # clean-room, pinned release assets. The module release has a verified Electron
  # ABI and patch provenance; see nix/runtime-inputs.nix and runtime check.
  #==========================================================================
  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR

    if [[ ${lib.boolToString installerProvided} != true ]]; then
      cat "$src" >&2
      exit 1
    fi

    #-- 1. Extract the Squirrel .exe -> *-full.nupkg -> Electron payload -----
    7z x -y "$src" -oinstaller >/dev/null
    nupkg=$(find installer -iname '*-full.nupkg' | head -1)
    [[ -n "$nupkg" ]] || {
      echo 'installer has no *-full.nupkg payload; provide the full Squirrel' >&2
      echo 'installer, not a web bootstrapper.' >&2
      exit 1
    }
    7z x -y "$nupkg" -onupkg >/dev/null

    net45=nupkg/lib/net45
    resources_src="$net45/resources"
    [[ -f "$resources_src/app.asar" ]] || { echo "app.asar not found at $resources_src" >&2; exit 1; }

    #-- 2. Stage the resource tree (everything except the asar + Windows helper)
    mkdir -p stage
    rsync -a \
      --exclude 'app.asar' \
      --exclude 'app.asar.unpacked' \
      --exclude 'Release/Wispr Flow Helper.exe' \
      "$resources_src/" stage/

    #-- 3. Unpack app.asar, patch the main bundle, repack ---------------------
    asar extract "$resources_src/app.asar" asar-contents
    main_bundle=asar-contents/.webpack/main/index.js
    [[ -f "$main_bundle" ]] || { echo "main bundle not found at $main_bundle" >&2; exit 1; }

    # Apply the complete current Linux patch suite used by build-linux.sh.
    bash ${sourceRoot}/scripts/patches/helper-resolver.sh "$main_bundle"
    bash ${sourceRoot}/scripts/patches/helper-env.sh "$main_bundle"
    bash ${sourceRoot}/scripts/patches/mac-gates.sh "$main_bundle"
    bash ${sourceRoot}/scripts/patches/linux-window-frame.sh "$main_bundle"
    bash ${sourceRoot}/scripts/patches/linux-deeplink.sh "$main_bundle"

    webpack_root="${"$"}{main_bundle%/main/index.js}"
    hub_renderer="$webpack_root/renderer/hub/index.js"
    [[ -f "$hub_renderer" ]] || { echo "hub renderer not found" >&2; exit 1; }
    bash ${sourceRoot}/scripts/patches/linux-renderer-chrome.sh "$hub_renderer"
    renderer_count=0
    for renderer in "$webpack_root"/renderer/*/index.js; do
      [[ -f "$renderer" ]] || continue
      grep -qF 'platform?.isWindows' "$renderer" || continue
      bash ${sourceRoot}/scripts/patches/linux-renderer-treat-as-windows.sh "$renderer"
      renderer_count=$((renderer_count + 1))
    done
    (( renderer_count > 0 )) || { echo "no Windows-gated renderer found" >&2; exit 1; }

    # Stage and replace the Windows modules in BOTH locations Electron may load.
    if [[ -d "$resources_src/app.asar.unpacked" ]]; then
      mkdir -p stage/app.asar.unpacked
      cp -a "$resources_src/app.asar.unpacked/." stage/app.asar.unpacked/
    fi
    native_rel=.webpack/main/native_modules/build/Release
    mkdir -p "asar-contents/$native_rel" "stage/app.asar.unpacked/$native_rel"
    install -m644 ${runtimeInputs.betterSqlite} \
      "asar-contents/$native_rel/better_sqlite3.node"
    install -m644 ${runtimeInputs.sqlite} \
      "asar-contents/$native_rel/node_sqlite3.node"
    install -m644 ${runtimeInputs.betterSqlite} \
      "stage/app.asar.unpacked/$native_rel/better_sqlite3.node"
    install -m644 ${runtimeInputs.sqlite} \
      "stage/app.asar.unpacked/$native_rel/node_sqlite3.node"
    rm -f stage/app.asar.unpacked/.webpack/main/native_modules/lib/crypt32-*.node

    # Repack with native modules left unpacked, then verify every Linux marker.
    asar pack asar-contents stage/app.asar --unpack '**/*.node'
    bash ${sourceRoot}/scripts/verify-patches.sh stage/app.asar

    #-- 4. Stage the clean-room Linux helper (mode 0755 — the app does not chmod)
    mkdir -p stage/Release
    cp ${runtimeInputs.helper} stage/Release/wispr-flow-linux-helper
    chmod 0755 stage/Release/wispr-flow-linux-helper
    rm -f "stage/Release/Wispr Flow Helper.exe" || true

    runHook postBuild
  '';

  #==========================================================================
  # Install phase — reproduces the FHS layout the deb/rpm makers build, under
  # $out, with the Electron ELF copied (not symlinked) into the store tree so
  # /proc/self/exe resolves here.
  #==========================================================================
  installPhase = ''
        runHook preInstall

        #-- Custom Electron tree with app resources co-located -------------------
        # (Same rationale as the reference: Chromium derives resourcesPath from
        # /proc/self/exe, so the binary must live next to the app's resources.)
        electron_tree=$out/lib/wispr-flow/electron
        mkdir -p $electron_tree/resources

        # Copy the ELF as a REAL file named 'wispr-flow' (not 'electron') — both for
        # /proc/self/exe and because Electron sets app.isPackaged=false when the
        # binary is named 'electron', which breaks the 92 DB migrations.
        cp ${electronDir}/electron $electron_tree/wispr-flow
        chmod +x $electron_tree/wispr-flow

        # Symlink everything else from electron-unwrapped.
        for item in ${electronDir}/*; do
          name=$(basename "$item")
          [[ "$name" = "electron" ]] && continue
          [[ "$name" = "resources" ]] && continue
          ln -s "$item" "$electron_tree/$name"
        done

        # Start resources/ from Electron's own (default_app.asar, etc.).
        for item in ${electronDir}/resources/*; do
          ln -s "$item" "$electron_tree/resources/$(basename "$item")"
        done

        # Merge the staged Wispr resource tree (app.asar, app.asar.unpacked,
        # Release/, migrations/, assets/, *.mcpb, ...) into resources/.
        cp -r stage/* $electron_tree/resources/

        # Convenience symlink used by the launcher.
        ln -s $electron_tree/resources $out/lib/wispr-flow/resources

        #-- Electron wrapper: retain the stock GTK/GIO/GDK environment setup -----
        # The nixpkgs wrapper is more than a shebang; copying only its first line
        # loses GIO modules, schemas, pixbuf loaders, and CHROME_DEVEL_SANDBOX.
        # Retarget its final exec to our renamed ELF instead.
        cp ${electron_42}/bin/electron $electron_tree/electron-wrapper
        chmod +x $electron_tree/electron-wrapper
        substituteInPlace $electron_tree/electron-wrapper \
          --replace-fail "${electronUnwrapped}/libexec/electron/electron" \
            "$electron_tree/wispr-flow" \
          --replace-quiet "${electron_42}/libexec/electron/chrome-sandbox" \
            "$electron_tree/chrome-sandbox"

        #-- Icons ----------------------------------------------------------------
        icon_png=$electron_tree/resources/assets/logos/wispr-logo.png
        if [[ -f "$icon_png" ]]; then
          install -Dm644 "$icon_png" \
            $out/share/icons/hicolor/256x256/apps/wispr-flow.png
        fi
        icon_svg=$electron_tree/resources/assets/logos/wispr-flow.svg
        if [[ -f "$icon_svg" ]]; then
          install -Dm644 "$icon_svg" \
            $out/share/icons/hicolor/scalable/apps/wispr-flow.svg
        fi

        #-- Shared launcher library + doctor (launcher-common.sh sources doctor.sh
        #   from the same dir, so both must be co-located) ------------------------
        install -Dm755 ${sourceRoot}/scripts/launcher-common.sh \
          $out/lib/wispr-flow/launcher-common.sh
        install -Dm755 ${sourceRoot}/scripts/doctor.sh \
          $out/lib/wispr-flow/doctor.sh

        #-- .desktop file --------------------------------------------------------
        mkdir -p $out/share/applications
        install -Dm644 ${desktopItem}/share/applications/* $out/share/applications/

        #-- input access udev rule ------------------------------------------------
        # A user package cannot install into /etc/udev or /usr/lib/udev at runtime.
        # We emit the rule to $out/lib/udev/rules.d/; on NixOS wire it up with:
        #
        #   services.udev.packages = [ pkgs.wispr-flow ];   # or the fhs wrapper
        #
        # which symlinks it into the active rules set. Without it, keystroke
        # injection (/dev/uinput) and push-to-talk (/dev/input read) need the user
        # in the 'input' group + a matching rule. Keep in sync with deb.sh, rpm.sh,
        # and the launcher's _wispr_udev_rules_content (scripts/launcher-common.sh).
        mkdir -p $out/lib/udev/rules.d
        cat > $out/lib/udev/rules.d/70-wispr-flow-uinput.rules <<'UDEV'
    # Wispr Flow: grant the active-session user the input access the helper needs.
    #  - write /dev/uinput        — keystroke injection (PasteText/SimulateKeyPress)
    #  - read  /dev/input/event*  — global key monitor for push-to-talk and the
    #                               in-app shortcut recorder
    # TAG+="uaccess" scopes the grant to the active logind session; the input group
    # + 0660 is the cross-distro fallback (then `usermod -aG input $USER` + re-login).
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
    SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess", GROUP="input", MODE="0660"
    UDEV

        #-- Launcher /bin/wispr-flow ---------------------------------------------
        mkdir -p $out/bin
        cat > $out/bin/wispr-flow <<'LAUNCHER'
    #!/usr/bin/env bash
    # Wispr Flow launcher for NixOS. Sources the shared launcher library, runs the
    # doctor on --doctor, sets up logging + Electron env, then exec's our custom
    # Electron wrapper (which sets GTK/GIO env then runs the merged ELF).

    set -uo pipefail

    electron_exec="ELECTRON_PLACEHOLDER"
    helper_bin="RESOURCES_PLACEHOLDER/Release/wispr-flow-linux-helper"

    # shellcheck source=/dev/null
    source "LAUNCHER_LIB_PLACEHOLDER"

    # Handle --doctor before anything else.
    if [[ "''${1:-}" == '--doctor' ]]; then
    	run_doctor "$helper_bin"
    	exit $?
    fi

    setup_logging || exit 1
    setup_electron_env
    cleanup_stale_lock

    log_message '--- Wispr Flow Launcher Start (NixOS) ---'
    log_message "Timestamp: $(date)"
    log_message "Arguments: $*"
    log_session_env

    if ! check_display; then
    	log_message 'No display detected (TTY session)'
    	echo 'Error: Wispr Flow requires a graphical desktop environment.' >&2
    	echo 'Run from within a Wayland or X11 session, not a TTY.' >&2
    	echo 'Tip: run "wispr-flow --doctor" to diagnose your setup.' >&2
    	exit 1
    fi

    detect_display_backend
    build_electron_args 'nix'

    log_message "Executing: $electron_exec ''${electron_args[*]} $*"
    exec "$electron_exec" "''${electron_args[@]}" "$@" >> "$log_file" 2>&1
    LAUNCHER
        substituteInPlace $out/bin/wispr-flow \
          --replace-fail "ELECTRON_PLACEHOLDER" "$electron_tree/electron-wrapper" \
          --replace-fail "RESOURCES_PLACEHOLDER" "$electron_tree/resources" \
          --replace-fail "LAUNCHER_LIB_PLACEHOLDER" "$out/lib/wispr-flow/launcher-common.sh"
        chmod +x $out/bin/wispr-flow

        runHook postInstall
  '';

  meta = with lib; {
    description = "Wispr Flow voice dictation for Linux (unofficial build)";
    homepage = "https://wisprflow.ai";
    license = licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "wispr-flow";
  };
}
