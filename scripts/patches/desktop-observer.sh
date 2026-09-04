#!/usr/bin/env bash
# Add an opt-in gRPC observer at the already-patched Linux helper startup.
set -uo pipefail

bundle="${1:-}"
if [[ -z "$bundle" || ! -f "$bundle" ]]; then
	echo "usage: $0 <.webpack/main/index.js>" >&2
	exit 2
fi

marker="WISPR_DESKTOP_GRPC_OBSERVER"
if grep -q "$marker" "$bundle"; then
	echo "Already patched ($marker present in $bundle) - nothing to do."
	exit 0
fi

python3 - "$bundle" "$marker" <<'PY'
import io, re, sys

path, marker = sys.argv[1:]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as source:
    data = source.read()

anchor = re.compile(
    r'if\("linux"===process\.platform\)\{'
    r'(?P<branch>/\*WISPR_LINUX_HELPER_BRANCH\*/)' )
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(f"ERROR: expected exactly one patched Linux helper branch, found {len(matches)}.")

insertion = (
    'if(process.env.WISPR_DESKTOP_OBSERVER_DIR){try{'
    'require("./wispr-desktop-observer.js").install(require("@grpc/grpc-js"))'
    '}catch(_wdo){}}/*' + marker + '*/'
)
data = anchor.sub(lambda m: 'if("linux"===process.platform){' + insertion + m.group('branch'), data, count=1)
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as output:
    output.write(data)
PY

if command -v node >/dev/null && ! node --check "$bundle"; then
	echo "ERROR: observer patch made invalid JavaScript." >&2
	exit 1
fi
echo "OK: opt-in gRPC observer loader inserted into $bundle"
