#!/usr/bin/env bash
# sweeper_test.sh — titan-incus installs the same guest-log sweeper as the production-like cluster.
#
# The sweeper's text is owned by OpenViCloud/titan-ops's singapore01 cloud-init template; mac/provision/incus.sh carries a
# copy so the local cluster is tested on the same text (mac/tests/incus-log-sweeper_test.sh tests that copy). This
# compares the copy with the template on titan-ops's main, read through `gh api` so a private titan-ops reads the same. The template is a Terraform template: `$${` is a literal `${`
# there, and a bare `${` would be a template variable, which this cannot compare.
#
# Run:  bash tests/sweeper_test.sh [template]     (from the repo root; needs network and gh signed in unless a template
#       file is given)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LOCAL="$HERE/../mac/provision/incus.sh"
TEMPLATE="repos/OpenViCloud/titan-ops/contents/terraform/ovh-incus-cluster-singapore01/cloud-init/incus.sh.tpl?ref=main"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ $# -ge 1 ]; then
  cp "$1" "$WORK/incus.sh.tpl"
elif ! gh api -H "Accept: application/vnd.github.raw" "$TEMPLATE" > "$WORK/incus.sh.tpl"; then
  echo "FAIL could not fetch $TEMPLATE"
  exit 1
fi

if ! python3 - "$WORK/incus.sh.tpl" "$LOCAL" > "$WORK/diff" <<'PY'
import re, sys
def block(path):
    lines = open(path).read().splitlines()
    try:
        start = lines.index("cat > /usr/local/sbin/incus-log-sweeper <<'SWEEPER'")
        end = lines.index("systemctl enable --now incus-log-sweeper.timer", start)
    except ValueError:
        return None
    return lines[start:end + 1]
template, local = block(sys.argv[1]), block(sys.argv[2])
if template is None or local is None:
    print("sweeper block missing in %s" % ("the titan-ops template" if template is None else "mac/provision/incus.sh"))
    sys.exit()
variables = [line for line in template if re.search(r"(?<!\$)\$\{|(?<!%)%\{", line)]
if variables:
    print("the titan-ops block has a template variable, cannot compare: %r" % variables[0])
    sys.exit()
template = [line.replace("$${", "${").replace("%%{", "%{") for line in template]
if template != local:
    for a, b in zip(template, local):
        if a != b:
            print("first difference: %r vs %r" % (a, b))
            break
    else:
        print("lengths differ: %d vs %d lines" % (len(template), len(local)))
PY
then
  echo "FAIL the comparison itself failed (see the error above)"
  exit 1
fi
diff=$(cat "$WORK/diff")
if [ -z "$diff" ]; then
  echo "PASS log sweeper, its service and its timer are titan-ops's text, line for line"
else
  echo "FAIL log sweeper differs from titan-ops's template: $diff"
  exit 1
fi
