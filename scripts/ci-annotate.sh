#!/usr/bin/env bash
# Turns compiler and test output into GitHub annotations, which are readable
# through the API even when raw logs aren't. Usage: ci-annotate.sh <log>...
cat "$@" 2>/dev/null > /tmp/ci-all.log || true

# Compiler errors and failed assertions: file:line[:col]: error: message
grep -E "^/[^:]+:[0-9]+(:[0-9]+)?: error: " /tmp/ci-all.log | sort -u | head -40 \
  | sed -E 's#^(/[^:]+):([0-9]+):([0-9]+): error: (.*)#::error file=\1,line=\2,col=\3::\4#; s#^(/[^:]+):([0-9]+): error: (.*)#::error file=\1,line=\2::\3#'

# Warnings from our own sources only.
grep -E "^/[^:]+/(Sources|Tests)/[^:]+:[0-9]+:[0-9]+: warning: " /tmp/ci-all.log | sort -u | head -10 \
  | sed -E 's#^(/[^:]+):([0-9]+):([0-9]+): warning: (.*)#::warning file=\1,line=\2,col=\3::\4#'

# Live calls to Gemini and OpenAI (only when keys are in the repo).
grep -E "^LIVE " /tmp/ci-all.log | sort -u | head -4 | sed -E 's#^#::notice::#'

# Signing and setup lines first (GitHub keeps only 10 notices per step).
grep -E "^step: |Icon compiled|Icon from|prebuilt icon catalog|actool couldn|Assets.car |Signed |Created certificate|New signing|codesign (Authority|Signature)|Alarm clock|valid on disk|satisfies its Designated" /tmp/ci-all.log \
  | head -8 | sed -E 's#^#::notice::#'
# Skipped tests and why.
grep -E "Test skipped" /tmp/ci-all.log | sed -E 's#^.*\[[^ ]+ (test[A-Za-z]+)\] : Test skipped - #\1 skipped: #' | sort -u | head -4 | sed -E 's#^#::notice::#'
# A crash: name the test that was running.
awk '/Test Case .* started/ {last=$0} /Fatal error|fatal error:|Segmentation fault|signal code/ {print "crashed in: " last; exit}' /tmp/ci-all.log \
  | sed -E "s#^crashed in: .*\[[^ ]+ (test[A-Za-z]+)\].*#::notice::crashed in \1#"
# Crashes, fatal errors and test summaries.
grep -E "Fatal error|fatal error|Test Case .* failed|error: (exit|fatalError|signal)|Segmentation|unable to|No such file" /tmp/ci-all.log \
  | grep -vE "^/[^:]+:[0-9]+" | sort -u | head -4 | sed -E 's#^#::notice::#'
TOTAL=$(grep -oE "Executed [0-9]+ tests" /tmp/ci-all.log | awk '{print $2}' | sort -n | tail -1)
SKIPPED=$(grep -cE "Test Case .* skipped" /tmp/ci-all.log || true)
FAILED=$(grep -cE "Test Case .* failed" /tmp/ci-all.log || true)
[[ -n "$TOTAL" ]] && echo "::notice::Tests: ${TOTAL} run, ${SKIPPED} skipped, ${FAILED} failed"
grep -E "Test Case .* skipped" /tmp/ci-all.log | sed -E "s#.*\[[^ ]+ (test[A-Za-z]+)\].*#::notice::skipped \1#" | head -4
exit 0
