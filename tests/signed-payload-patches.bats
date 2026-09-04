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
	grep -qF 'WISPR_LINUX_STATUS_DICTATION_RESHOW_SUPPRESSED' "$main"
	grep -qF 'if("linux"===process.platform)return;/*WISPR_LINUX_STATUS_DICTATION_RESHOW_SUPPRESSED*/const t=ie.RA.statusWindow' "$main"
	grep -qF 'globalThis.__wisprStatusBridge?.setToggleHandsFree' "$main"
	grep -qF 'await(0,z.Qw)(c.SB.Deeplink)' "$main"
	grep -qF 'await(0,z.US)(c.SB.Deeplink)' "$main"
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$main"
}

@test "status patch rejects a one-line bundle containing every marker" {
	local fake="$BATS_TEST_TMPDIR/all-markers.js"
	printf '%s\n' '/*WISPR_LINUX_STATUS_BRIDGE WISPR_LINUX_STATUS_BOOTSTRAP WISPR_LINUX_STATUS_LIFECYCLE WISPR_LINUX_STATUS_PUBLICATION WISPR_LINUX_STATUS_CONTROL WISPR_LINUX_STATUS_WINDOW_SUPPRESSED WISPR_LINUX_STATUS_DICTATION_RESHOW_SUPPRESSED*/' > "$fake"
	run bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$fake"
	[[ $status -ne 0 ]]
}

@test "status patch leaves its current input intact when a later anchor fails" {
	[[ -n ${WISPR_FLOW_AUDIT_APP:-} && -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" ]] || skip 'set WISPR_FLOW_AUDIT_APP to verified extracted 1.6.774 app'
	local fake="$BATS_TEST_TMPDIR/rollback.js"
	cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" "$fake"
	[[ ! -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" ]] || cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" "$fake"
	sed -i 's/y.H8&&!J&&F.setEnabled(!0),e.showInactive(),y.H8&&/missing-status-window-anchor/' "$fake"
	local before
	before=$(sha256sum "$fake")
	run bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$fake"
	[[ $status -ne 0 ]]
	[[ "$before" == "$(sha256sum "$fake")" ]]
}
