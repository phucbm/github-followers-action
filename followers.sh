#!/usr/bin/env bash
# Compares a GitHub user's followers with the last known list (STATE_FILE),
# posts each new follower and unfollower to Discord, then saves the new list.
# Settings come from the environment (see action.yml).
set -euo pipefail

: "${GH_USERNAME:?username is required}"
: "${DISCORD_WEBHOOK_URL:?discord-webhook-url is required}"
STATE_FILE="${STATE_FILE:-.github/followers.json}"
NOTIFY_FOLLOWS="${NOTIFY_FOLLOWS:-true}"
NOTIFY_UNFOLLOWS="${NOTIFY_UNFOLLOWS:-true}"
MAX_MESSAGES="${MAX_MESSAGES:-10}"
COMMIT_STATE="${COMMIT_STATE:-true}"
DRY_RUN="${DRY_RUN:-false}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

GREEN=3066993   # #2ecc71
RED=15158332    # #e74c3c
BLUE=3447003    # #3498db

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Current followers
echo "👀 Fetching followers of @${GH_USERNAME}..."
expected=$(gh api "users/${GH_USERNAME}" --jq '.followers')
gh api --paginate "users/${GH_USERNAME}/followers?per_page=100" --jq '.[].login' | sort -u > "$tmp/now"
count=$(wc -l < "$tmp/now" | tr -d ' ')
echo "📋 ${count} followers (profile says ${expected})"

# An empty list from the API while the profile has followers is a bad response, not a mass unfollow
if [ "$count" -eq 0 ] && [ "$expected" -gt 0 ]; then
  echo "::warning::GitHub returned no followers while the profile shows ${expected}. Nothing changed."
  echo "followers=${expected}" >> "$OUTPUT"
  exit 0
fi

echo "followers=${count}" >> "$OUTPUT"

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -n --arg user "$GH_USERNAME" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --rawfile list "$tmp/now" \
    '{username: $user, updated: $updated, count: ($list | split("\n") | map(select(. != "")) | length),
      followers: ($list | split("\n") | map(select(. != "")))}' > "$STATE_FILE"
}

commit_state() {
  local message="$1"
  if [ "$COMMIT_STATE" != "true" ] || [ "$DRY_RUN" = "true" ]; then
    echo "⏭️ Not committing ${STATE_FILE}"
    return
  fi
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "::warning::Not a git checkout, so ${STATE_FILE} was not committed. Add actions/checkout before this action."
    return
  fi
  git config --local user.email "github-actions[bot]@users.noreply.github.com"
  git config --local user.name "github-actions[bot]"
  git add "$STATE_FILE"
  if git diff --staged --quiet; then
    echo "No changes to commit"
    return
  fi
  git commit -m "$message"
  git push origin "HEAD:${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
  echo "✅ Committed ${STATE_FILE}"
}

# 2. First run: save the starting list, post nothing
if [ ! -f "$STATE_FILE" ]; then
  echo "🆕 No ${STATE_FILE} yet: saving ${count} followers as the starting list, nothing posted"
  save_state
  {
    echo "first-run=true"
    echo "new-followers="
    echo "unfollowers="
  } >> "$OUTPUT"
  commit_state "👥 Start tracking followers of @${GH_USERNAME} (${count})"
  exit 0
fi
echo "first-run=false" >> "$OUTPUT"

# 3. Differences
jq -r '.followers[]' "$STATE_FILE" | sort -u > "$tmp/before"
comm -13 "$tmp/before" "$tmp/now" > "$tmp/new"
comm -23 "$tmp/before" "$tmp/now" > "$tmp/gone"
[ "$NOTIFY_FOLLOWS" = "true" ] || : > "$tmp/new_post"
[ "$NOTIFY_UNFOLLOWS" = "true" ] || : > "$tmp/gone_post"
[ -f "$tmp/new_post" ] || cp "$tmp/new" "$tmp/new_post"
[ -f "$tmp/gone_post" ] || cp "$tmp/gone" "$tmp/gone_post"

joined() { paste -sd, "$1"; }
added=$(wc -l < "$tmp/new" | tr -d ' ')
removed=$(wc -l < "$tmp/gone" | tr -d ' ')
{
  echo "new-followers=$(joined "$tmp/new")"
  echo "unfollowers=$(joined "$tmp/gone")"
} >> "$OUTPUT"
echo "🟢 +${added} new · 🔴 -${removed} gone"

if [ "$added" -eq 0 ] && [ "$removed" -eq 0 ]; then
  echo "✅ No changes"
  exit 0
fi

# 4. Discord
post() {
  local payload="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "🧪 Dry run, would post:"
    echo "$payload" | jq .
    return
  fi
  local attempt status
  for attempt in 1 2 3; do
    status=$(curl -sS -o "$tmp/response" -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "$payload" "${DISCORD_WEBHOOK_URL}?wait=true")
    if [ "$status" = "429" ]; then
      sleep "$(jq -r '.retry_after // 2' "$tmp/response" | cut -d. -f1)"
      continue
    fi
    if [ "${status:0:1}" = "2" ]; then
      sleep 1  # stay under Discord's webhook rate limit
      return
    fi
    break
  done
  echo "::error::Discord answered ${status}: $(cat "$tmp/response")"
  exit 1
}

footer="@${GH_USERNAME} now has ${count} followers"

card() {
  local login="$1" title="$2" color="$3" profile
  if profile=$(gh api "users/${login}" 2> /dev/null); then
    echo "$profile" | jq --arg title "$title" --argjson color "$color" --arg footer "$footer" '{
      embeds: [{
        title: $title, url: .html_url, color: $color,
        description: ([.name, .bio] | map(select(. != null and . != "")) | join(" · ")),
        thumbnail: {url: .avatar_url},
        fields: [
          {name: "Followers", value: (.followers | tostring), inline: true},
          {name: "Repos", value: (.public_repos | tostring), inline: true}
        ],
        footer: {text: $footer}
      }]}'
  else
    # A deleted or renamed account has no profile any more
    jq -n --arg title "$title" --argjson color "$color" --arg footer "$footer" --arg login "$login" '{
      embeds: [{title: $title, url: ("https://github.com/" + $login), color: $color,
        description: "This account no longer exists or was renamed.", footer: {text: $footer}}]}'
  fi
}

to_post=$(( $(wc -l < "$tmp/new_post") + $(wc -l < "$tmp/gone_post") ))
if [ "$to_post" -gt "$MAX_MESSAGES" ]; then
  echo "📦 ${to_post} changes, posting one summary"
  links() { sed 's#.*#[@&](https://github.com/&)#' "$1" | paste -sd' ' -; }
  jq -n --argjson color "$BLUE" --arg footer "$footer" --arg user "$GH_USERNAME" \
    --arg new "$(links "$tmp/new_post")" --arg gone "$(links "$tmp/gone_post")" \
    --arg added "$(wc -l < "$tmp/new_post" | tr -d ' ')" --arg removed "$(wc -l < "$tmp/gone_post" | tr -d ' ')" '{
      embeds: [{title: ("Follower changes for @" + $user), url: ("https://github.com/" + $user + "?tab=followers"),
        color: $color, footer: {text: $footer},
        fields: ([
          (if $new != "" then {name: ("🟢 " + $added + " new"), value: ($new | .[0:1024])} else empty end),
          (if $gone != "" then {name: ("🔴 " + $removed + " gone"), value: ($gone | .[0:1024])} else empty end)
        ])}]}' > "$tmp/summary"
  post "$(cat "$tmp/summary")"
else
  while read -r login; do
    [ -n "$login" ] && post "$(card "$login" "🟢 @${login} followed you" "$GREEN")"
  done < "$tmp/new_post"
  while read -r login; do
    [ -n "$login" ] && post "$(card "$login" "🔴 @${login} unfollowed you" "$RED")"
  done < "$tmp/gone_post"
fi

# 5. Save
save_state
commit_state "👥 Followers of @${GH_USERNAME}: +${added} -${removed} (${count})"
