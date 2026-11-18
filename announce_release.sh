#!/usr/bin/env bash
# Posts the current release to Discord: the version, the download page, and the Firefox xpi,
# Chrome zip and Chrome install guide as attachments. Run by the "announce release" workflow
# on a release push; needs DISCORD_RELEASE_WEBHOOK_URL (a Discord channel webhook).
#
#   ./announce_release.sh [--dry-run]
set -euo pipefail

dry_run=false
if [[ ${1:-} == "--dry-run" ]]; then
  dry_run=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--dry-run]" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

download_page="https://apps.legendaryupside.com/download-extension-landing"
install_guide="sidekick-chrome-install-guide.pdf"

version="$(python3 -c '
import json
addons = json.load(open("update_manifest.json"))["addons"]
versions = {addons[k]["updates"][0]["version"] for k in ("@legUpSidekickBackup", "chrome")}
if len(versions) != 1:
    raise SystemExit(f"update_manifest.json lists different versions: {sorted(versions)}")
print(versions.pop())
')"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected version in update_manifest.json: $version" >&2
  exit 1
fi

xpi="legupsidekick-${version}-firefox.xpi"
zip="legupsidekick-${version}-chrome.zip"
for file in "$xpi" "$zip" "$install_guide"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing $file; not announcing ${version}." >&2
    exit 1
  fi
done

payload="$(python3 -c '
import json, sys
print(json.dumps({"content": f"{sys.argv[1]}\n\n{sys.argv[2]}", "allowed_mentions": {"parse": []}}))
' "$version" "$download_page")"

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run: would post to Discord:"
  echo "$payload"
  printf ' - %s\n' "$xpi" "$zip" "$install_guide"
  exit 0
fi

if [[ -z "${DISCORD_RELEASE_WEBHOOK_URL:-}" ]]; then
  echo "DISCORD_RELEASE_WEBHOOK_URL is not set." >&2
  exit 1
fi

# wait=true makes Discord answer with the message, so a rejected post fails the run.
curl --silent --show-error --fail-with-body \
  --form-string "payload_json=${payload}" \
  -F "files[0]=@${xpi}" \
  -F "files[1]=@${zip}" \
  -F "files[2]=@${install_guide}" \
  "${DISCORD_RELEASE_WEBHOOK_URL}?wait=true" > /dev/null

echo "Announced ${version} on Discord."
