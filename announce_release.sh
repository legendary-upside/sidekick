#!/usr/bin/env bash
# Posts the current release to Discord: the version, the download page, and the Firefox xpi,
# Chrome zip and Chrome install guide as attachments. Run by the "announce release" workflow
# on a release push; needs DISCORD_RELEASE_WEBHOOK_URL (a Discord channel webhook).
#
# Once the new post is up, the posts listed in ANNOUNCE_STATE_FILE (one Discord message id per
# line) are deleted and the file is rewritten with the new post's id. A webhook cannot read
# channel history, so that file is the only record of what it posted; the workflow keeps it on
# the announce-state branch.
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

webhook_url="${DISCORD_RELEASE_WEBHOOK_URL%%\?*}"
state_file="${ANNOUNCE_STATE_FILE:-}"

# wait=true makes Discord answer with the message, so a rejected post fails the run.
response="$(curl --silent --show-error --fail-with-body \
  --form-string "payload_json=${payload}" \
  -F "files[0]=@${xpi}" \
  -F "files[1]=@${zip}" \
  -F "files[2]=@${install_guide}" \
  "${webhook_url}?wait=true")"
message_id="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' <<<"$response")"
if [[ ! "$message_id" =~ ^[0-9]+$ ]]; then
  echo "Discord did not return a message id." >&2
  exit 1
fi
echo "Announced ${version} on Discord."

if [[ -z "$state_file" ]]; then
  exit 0
fi

# Delete the earlier posts. One that is already gone (404) counts as deleted; any other failure
# keeps the id so the next release tries again.
keep=("$message_id")
if [[ -f "$state_file" ]]; then
  while IFS= read -r old_id; do
    [[ "$old_id" =~ ^[0-9]+$ && "$old_id" != "$message_id" ]] || continue
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      -X DELETE "${webhook_url}/messages/${old_id}" || true)"
    if [[ "$status" == "204" || "$status" == "404" ]]; then
      echo "Deleted previous post ${old_id}."
    else
      echo "Could not delete previous post ${old_id} (HTTP ${status}); will retry next release." >&2
      keep+=("$old_id")
    fi
  done < "$state_file"
fi
printf '%s\n' "${keep[@]}" > "$state_file"
