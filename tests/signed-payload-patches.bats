#!/usr/bin/env bats

@test "signed 1.6.774 payload accepts complete Linux patch suite" {
	[[ -n ${WISPR_FLOW_AUDIT_APP:-} && -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" ]] || skip 'set WISPR_FLOW_AUDIT_APP to verified extracted 1.6.774 app'
	local copy="$BATS_TEST_TMPDIR/app"
	cp -a "$WISPR_FLOW_AUDIT_APP" "$copy"
	local main="$copy/.webpack/main/index.js"
	[[ ! -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" ]] \
		|| cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" "$main"
	for patch in helper-resolver.sh mac-gates.sh helper-env.sh linux-window-frame.sh linux-hub-viewport.sh linux-deeplink.sh linux-status-bridge.sh; do
		bash "$BATS_TEST_DIRNAME/../scripts/patches/$patch" "$main"
	done
	for renderer in "$copy"/.webpack/renderer/*/index.js; do
		[[ -f $renderer ]] && grep -qF 'platform?.isWindows' "$renderer" && bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-treat-as-windows.sh" "$renderer"
	done
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-chrome.sh" "$copy/.webpack/renderer/hub/index.js"
	node --check "$main"
	grep -qF 'WISPR_LINUX_STATUS_BRIDGE' "$main"
	grep -qF 'WISPR_LINUX_STATUS_WINDOW_SUPPRESSED' "$main"
	grep -qF 'globalThis.__wisprStatusBridge?.setToggleHandsFree' "$main"
}
