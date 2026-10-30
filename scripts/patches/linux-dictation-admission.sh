#!/usr/bin/env bash
# Serialize production dictations until the preceding completion pipeline has
# finished all shared-state cleanup.

BUNDLE=${1:-}
MARKER='WISPR_LINUX_DICTATION_ADMISSION'

if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo 'usage: linux-dictation-admission.sh <main-bundle.js>' >&2
	exit 2
fi

if grep -q "$MARKER" "$BUNDLE"; then
	grep -qF 'globalThis.__wisprDictationBusy' "$BUNDLE" \
		&& grep -qF 'globalThis.__wisprMarkDictationTail' "$BUNDLE" \
		&& grep -qF 'globalThis.__wisprAbortDictationOwner' "$BUNDLE" \
		&& grep -qF 'globalThis.__wisprReleaseDictationOwner?.(n)' "$BUNDLE" \
		&& node --check "$BUNDLE" \
		&& exit 0
	echo 'ERROR: partial dictation admission marker set' >&2
	exit 1
fi

BEFORE="$BUNDLE.dictation-admission-before"
cp "$BUNDLE" "$BEFORE"

if ! python3 - "$BUNDLE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = path.read_text()


def replace_once(anchor: str, replacement: str, label: str) -> None:
    global data
    count = data.count(anchor)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected one {label} anchor, found {count}."
        )
    data = data.replace(anchor, replacement, 1)


module_head = '63205(e,t,n){"use strict"'
if data.count(module_head) != 1:
    raise SystemExit(
        f"ERROR: expected one dictation module, found {data.count(module_head)}."
    )
module_start = data.index(module_head)
module_tail = re.search(
    r'},\d+\(e,t,n\)\{"use strict"', data[module_start + len(module_head):]
)
if module_tail is None:
    raise SystemExit('ERROR: dictation module end not found.')
module_end = module_start + len(module_head) + module_tail.start() + 1
module = data[module_start:module_end]


def module_replace_once(anchor: str, replacement: str, label: str) -> None:
    global module
    count = module.count(anchor)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected one {label} anchor in dictation module, "
            f"found {count}."
        )
    module = module.replace(anchor, replacement, 1)


# The owner is separate from lifecycle status and the persisted sentinel. Idle
# is deferred while an owner exists, so every ordinary UI entry point continues
# to see Processing until the matching completion pipeline has fully cleaned up.
status_setter = 'qe=(e,t=!0,n={})=>{/*WISPR_LINUX_STATUS_LIFECYCLE*/'
status_guard = status_setter + '''if(e===O._W.Idle&&globalThis.__wisprDictationAdmission?.owner)return globalThis.__wisprDictationAdmission.pendingIdle=()=>qe(e,t,n),void 0;if((e===O._W.Error||e===O._W.Dismissed)&&globalThis.__wisprDictationAdmission?.owner)globalThis.__wisprDictationAdmission.pendingIdle=null;'''
module_replace_once(status_setter, status_guard, 'status setter')

processing_predicate = 'Pe=()=>O.cD.includes(p.ZZ.status),'
admission = '''_wisprDictationAdmissionInit=(/*WISPR_LINUX_DICTATION_ADMISSION*/globalThis.__wisprDictationAdmission??={owner:null,pendingIdle:null},globalThis.__wisprDictationBusy??=()=>null!==globalThis.__wisprDictationAdmission.owner,globalThis.__wisprReserveDictationOwner??=(e=>{const t=globalThis.__wisprDictationAdmission;return null===t.owner&&(t.owner={uuid:e,phase:"capture"},!0)}),globalThis.__wisprMarkDictationTail??=(e=>{const t=globalThis.__wisprDictationAdmission;return t.owner?.uuid===e&&(t.owner.phase="tail",!0)}),globalThis.__wisprReleaseDictationOwner??=(e=>{const t=globalThis.__wisprDictationAdmission;if(t.owner?.uuid!==e)return!1;t.owner=null;const n=t.pendingIdle;return t.pendingIdle=null,n?.(),!0}),globalThis.__wisprAbortDictationOwner??=(e=>{const t=globalThis.__wisprDictationAdmission;return t.owner?.uuid===e&&"capture"===t.owner.phase&&globalThis.__wisprReleaseDictationOwner(e)}),0),Pe=()=>O.cD.includes(p.ZZ.status),'''
module_replace_once(processing_predicate, admission, 'processing predicate')

# These are the four user-facing wrappers. The refusal precedes their mode,
# lock, shortcut and UI mutations.
for anchor, label in (
    ('Qe=(e=O.SB.Keyboard,t,n)=>{', 'PTT entry'),
    ('He=(e,t)=>{', 'Lens entry'),
    ('Ve=(e,t)=>{', 'Instruct entry'),
    ('Ze=(e,t,n)=>{', 'POPO entry'),
):
    module_replace_once(
        anchor,
        anchor + 'if(globalThis.__wisprDictationBusy())return{accepted:!1,error:"busy"};',
        label,
    )

# CO is the single capture provider. It independently refuses direct callers.
provider = 'it=(e,t,n)=>{'
module_replace_once(
    provider,
    provider + 'if(globalThis.__wisprDictationBusy())return{accepted:!1,error:"busy"};const c=crypto.randomUUID();if(!globalThis.__wisprReserveDictationOwner(c))return{accepted:!1,error:"busy"};let _wisprAdmissionAccepted=!1;try{',
    'capture provider',
)

# The real UUID already owns admission before any provider mutation. Reuse it
# when resetTranscriptState has completed instead of minting a second identity.
reset_and_uuid = ',(0,p.f4)(),B.ActivationNotificationManager.dismissNotification(y.tY.FirstDictation);const c=crypto.randomUUID();var d;if('
owned_reset = ';(0,p.f4)(),B.ActivationNotificationManager.dismissNotification(y.tY.FirstDictation);var d;if('
module_replace_once(reset_and_uuid, owned_reset, 'UUID ownership')

# Both dictionary reads are asynchronous writes to shared session state. They
# may land only while the UUID they were started for is still current.
dictionary_write = 'q.e.getDictionaryContext().then(e=>{p.ZZ.dictionaryContext=e.phrases,p.ZZ.starredDictionaryContext=e.starredPhrases,p.ZZ.teamDictionaryContext=e.teamPhrases,p.ZZ.starredTeamDictionaryContext=e.starredTeamPhrases})'
dictionary_guarded = 'q.e.getDictionaryContext().then(e=>{if(p.ZZ.uuid!==c)return;p.ZZ.dictionaryContext=e.phrases,p.ZZ.starredDictionaryContext=e.starredPhrases,p.ZZ.teamDictionaryContext=e.teamPhrases,p.ZZ.starredTeamDictionaryContext=e.starredTeamPhrases})'
if module.count(dictionary_write) != 2:
    raise SystemExit(
        'ERROR: expected two dictionary-context writes in capture provider, '
        f'found {module.count(dictionary_write)}.'
    )
module = module.replace(dictionary_write, dictionary_guarded)

# CO reports acceptance to direct callers and wrappers.
provider_end = 'st()},st=(e=M.H8)=>{'
module_replace_once(
    provider_end,
    'st();return _wisprAdmissionAccepted=!0,{accepted:!0,uuid:c}}catch(e){throw Xe(O.W5.UserActionEscape),e}finally{_wisprAdmissionAccepted||globalThis.__wisprAbortDictationOwner?.(c)}},st=(e=M.H8)=>{',
    'capture provider return',
)

data = data[:module_start] + module + data[module_end:]

# Dismissal closes capture, the streaming client and the transcription task.
# It may release a capture-phase owner, including getUserMedia abort/failure.
# A completion-tail owner remains held until the completion's outer finally.
dismiss_end = '(0,c.RH)(e)}},12005(e,t,n){"use strict"'
replace_once(
    dismiss_end,
    '(0,c.RH)(e),globalThis.__wisprAbortDictationOwner?.(p.ZZ.uuid)}},12005(e,t,n){"use strict"',
    'dismissal owner cleanup',
)

# Production completion must carry the admitted UUID and still own the gate.
# Testing retains its isolated no-owner path. A missing UUID cannot finish or
# release a production owner.
completion_admission = 'if(c.ZZ.status===Le._W.Testing||void 0===n||n===c.ZZ.uuid)if(Lt)'
replace_once(
    completion_admission,
    'if(c.ZZ.status===Le._W.Testing?!globalThis.__wisprDictationBusy():void 0!==n&&n===c.ZZ.uuid&&globalThis.__wisprDictationAdmission?.owner?.uuid===n)if(Lt)',
    'completion admission',
)

completion_start = 'Ignoring duplicate.`);else{Lt=!0;try{'
replace_once(
    completion_start,
    'Ignoring duplicate.`);else{globalThis.__wisprMarkDictationTail?.(n),Lt=!0;try{',
    'completion tail ownership',
)

# Release only the owner named by the recording-done event, after every success,
# error, dismissal and cleanup path has left the outermost finally.
completion_release = '}}finally{Lt=!1}}else s().warn("Dropping recording-done from a stale session"'
replace_once(
    completion_release,
    '}}finally{globalThis.__wisprReleaseDictationOwner?.(n),Lt=!1}}else s().warn("Dropping recording-done from a stale session"',
    'completion release',
)

# Extension route starts mutate mode/lock state before calling CO; refuse first.
route_start = 'if(!Ti.KB.includes(ci.ZZ.status))break;ci.ZZ.isInstructMode='
if data.count(route_start) != 2:
    raise SystemExit(
        'ERROR: expected two extension route start anchors, found '
        f'{data.count(route_start)}.'
    )
data = data.replace(
    route_start,
    'if(!Ti.KB.includes(ci.ZZ.status)||globalThis.__wisprDictationBusy())break;ci.ZZ.isInstructMode=',
)

# BLE has local capture state of its own; refuse before touching it.
ble_start = 'R=()=>{N(),E=!0,_=Date.now(),u.ZZ.micSwitchedToName=null;'
replace_once(
    ble_start,
    'R=()=>{if(globalThis.__wisprDictationBusy())return{accepted:!1,error:"busy"};N(),E=!0,_=Date.now(),u.ZZ.micSwitchedToName=null;',
    'BLE start',
)

path.write_text(data)
PY
then
	cp "$BEFORE" "$BUNDLE"
	rm -f "$BEFORE"
	exit 1
fi

if ! node --check "$BUNDLE"; then
	cp "$BEFORE" "$BUNDLE"
	rm -f "$BEFORE"
	exit 1
fi
rm -f "$BEFORE"
echo 'Patched production dictation admission serialization.'
