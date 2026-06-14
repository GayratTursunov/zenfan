#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Zenfan lint gate. Run from anywhere: bash tools/lint.sh
#
# Hard gate (fails the run): bash -n syntax, python compile, JSON validity,
#                            JS syntax (node), and shellcheck *errors*.
# Advisory (printed, never fails): shellcheck warnings/info.
#
# Optional tools (shellcheck, node) are skipped gracefully when absent, so the
# script never fails just because a linter is not installed locally — CI installs
# them for the authoritative gate (.github/workflows/ci.yml).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
fail=0

BASH_SCRIPTS=(
    bin/zenbook-fan.sh bin/zenfan bin/zenfan-night bin/zenfan-night-effective
    bin/zenfan-write-conf install.sh uninstall.sh tools/lint.sh
)
PY_SCRIPTS=(bin/zenfan-config-gui)
JS_FILES=(applet/applet.js)
JSON_FILES=(applet/metadata.json applet/settings-schema.json)

echo "== bash -n (syntax) =="
for f in "${BASH_SCRIPTS[@]}"; do
    [[ -f "$f" ]] || continue
    if bash -n "$f"; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "== python compile =="
for f in "${PY_SCRIPTS[@]}"; do
    [[ -f "$f" ]] || continue
    if python3 -m py_compile "$f"; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "== JSON validity =="
for f in "${JSON_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f"; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "== JS syntax =="
if command -v node >/dev/null 2>&1; then
    for f in "${JS_FILES[@]}"; do
        [[ -f "$f" ]] || continue
        if node --check "$f"; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
    done
else
    echo "  (node not installed — JS syntax check skipped)"
fi

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck --severity=error "${BASH_SCRIPTS[@]}"; then
        echo "  no errors"
    else
        echo "  FAIL shellcheck reported errors"; fail=1
    fi
    echo "  -- advisory (warnings, non-gating): --"
    shellcheck --severity=warning "${BASH_SCRIPTS[@]}" || true
else
    echo "  (shellcheck not installed — skipped; install: sudo apt install shellcheck)"
fi

echo ""
if [[ $fail -eq 0 ]]; then echo "lint: PASS"; else echo "lint: FAIL"; fi
exit $fail
