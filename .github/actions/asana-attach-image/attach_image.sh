#!/usr/bin/env bash
set -euo pipefail

: "${ASANA_ACCESS_TOKEN:?Missing ASANA_ACCESS_TOKEN}"
: "${ASANA_TASK_URL:?Missing ASANA_TASK_URL}"
: "${FILENAME:?Missing FILENAME}"
CONTENT_TYPE="${CONTENT_TYPE:-image/png}"
HIDE_ATTACHMENT_STORY="${HIDE_ATTACHMENT_STORY:-true}"

api="https://app.asana.com/api/1.0"
auth="Authorization: Bearer ${ASANA_ACCESS_TOKEN}"

# The task GID is the last long number in the URL (works for /0/<project>/<task>,
# /1/<workspace>/project/<project>/task/<task> and /1/<workspace>/task/<task>).
task_gid="$(grep -oE '[0-9]{10,}' <<< "${ASANA_TASK_URL}" | tail -1 || true)"
if [[ -z "${task_gid}" ]]; then
  echo "::error::Could not extract an Asana task GID from the task URL."
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

if [[ -n "${IMAGE_PATH:-}" ]]; then
  image_file="${IMAGE_PATH}"
elif [[ -n "${IMAGE_URL:-}" ]]; then
  image_file="${work_dir}/image"
  curl -sfL --retry 3 "${IMAGE_URL}" -o "${image_file}"
else
  echo "::error::Either image-url or image-path must be provided."
  exit 1
fi

# Upload the image as an attachment on the task
upload_response="$(curl -sS --retry 3 -H "${auth}" \
  --form-string "parent=${task_gid}" \
  -F "file=@${image_file};filename=${FILENAME};type=${CONTENT_TYPE}" \
  "${api}/attachments")"
attachment_gid="$(jq -r '.data.gid // empty' <<< "${upload_response}" 2>/dev/null || true)"
if [[ -z "${attachment_gid}" ]]; then
  echo "::error::Failed to upload the attachment: $(jq -c '.errors // empty' <<< "${upload_response}" 2>/dev/null || echo 'unexpected response')"
  exit 1
fi
echo "Uploaded attachment ${attachment_gid}"

# Remove the automatic "attached" activity entry for this upload only.
# The attachment itself stays, so it can still be referenced inline.
if [[ "${HIDE_ATTACHMENT_STORY}" == "true" ]]; then
  story_gid="$(curl -sfS --retry 3 -H "${auth}" \
    "${api}/tasks/${task_gid}/stories?opt_fields=resource_subtype,text" \
    | jq -r --arg filename "${FILENAME}" \
      '[.data[] | select(.resource_subtype == "attachment_added" and ((.text // "") | contains($filename)))] | last | .gid // empty')"

  if [[ -n "${story_gid}" ]]; then
    if curl -sfS -X DELETE -H "${auth}" "${api}/stories/${story_gid}" > /dev/null; then
      echo "Removed attachment activity entry ${story_gid}"
    else
      echo "::warning::Could not remove the attachment activity entry; the image is still attached."
    fi
  else
    echo "::warning::Attachment activity entry not found; nothing to remove."
  fi
fi

echo "attachment-gid=${attachment_gid}" >> "${GITHUB_OUTPUT}"
