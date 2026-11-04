#!/usr/bin/env bash
# Promote selected Fabric item folders from a source branch to a target branch
# through a new promotion branch and a pull request.
#
# Required environment variables:
#   SOURCE_BRANCH   feature branch that contains the change
#   TARGET_BRANCH   branch to promote into (e.g. develop)
#   ITEM_LIST       comma- or newline-separated item folder names or paths
# Optional:
#   DRY_RUN         "true" to preview without pushing or opening a pull request
#   WORKFLOW_RUN_URL, TRIGGERED_BY   used in the pull request description

set -euo pipefail

: "${SOURCE_BRANCH:?SOURCE_BRANCH is required}"
: "${TARGET_BRANCH:?TARGET_BRANCH is required}"
: "${ITEM_LIST:?ITEM_LIST is required}"
DRY_RUN="${DRY_RUN:-false}"
WORKFLOW_RUN_URL="${WORKFLOW_RUN_URL:-}"
TRIGGERED_BY="${TRIGGERED_BY:-unknown}"
STEP_SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "::error::$1"
  printf '### Promotion failed\n\n%s\n' "$1" >> "$STEP_SUMMARY_FILE"
  exit 1
}

# --- 0. Check the promotion path (e.g. test may only receive from develop) -
[[ "$SOURCE_BRANCH" != "$TARGET_BRANCH" ]] || fail "Source and target are both '$TARGET_BRANCH'. Pick two different branches."

if [[ "${ENFORCE_PROMOTION_ORDER:-false}" == "true" && -n "${PROMOTION_ORDER:-}" ]]; then
  allowed_source=""
  IFS=';' read -ra promotion_rules <<< "$PROMOTION_ORDER"
  for promotion_rule in "${promotion_rules[@]}"; do
    rule_target="${promotion_rule%%=*}"
    rule_source="${promotion_rule#*=}"
    [[ "$rule_target" == "$TARGET_BRANCH" ]] && allowed_source="$rule_source"
  done
  if [[ -z "$allowed_source" ]]; then
    fail "No promotion rule for target '$TARGET_BRANCH'. Allowed paths: $PROMOTION_ORDER"
  fi
  if [[ "$allowed_source" != "*" && "$allowed_source" != "$SOURCE_BRANCH" ]]; then
    fail "'$TARGET_BRANCH' can only receive items from '$allowed_source', not from '$SOURCE_BRANCH'. Promote in order: feature → develop → test → main."
  fi
  if [[ "$allowed_source" == "*" ]]; then
    for protected_target in $(printf '%s\n' "${promotion_rules[@]}" | cut -d= -f1); do
      if [[ "$SOURCE_BRANCH" == "$protected_target" && "$protected_target" != "$TARGET_BRANCH" ]]; then
        fail "'$SOURCE_BRANCH' cannot be promoted into '$TARGET_BRANCH' (that would go backwards). Promote in order: feature → develop → test → main."
      fi
    done
  fi
fi

# --- 1. Make sure both branches exist --------------------------------------
if ! git fetch --quiet origin "$SOURCE_BRANCH" "$TARGET_BRANCH"; then
  available_branches="$(git ls-remote --heads origin | sed 's#.*refs/heads/##' | sort | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  fail "Could not find branch '$SOURCE_BRANCH' or '$TARGET_BRANCH' (names are case-sensitive). Available branches: $available_branches"
fi
source_reference="origin/$SOURCE_BRANCH"
target_reference="origin/$TARGET_BRANCH"

# --- 2. Work out the item folders ------------------------------------------
# Every Fabric item folder contains a .platform file, so the folders holding a
# .platform file in either branch are the valid item folders.
all_item_folders="$(
  { git ls-tree -r --name-only "$source_reference"; git ls-tree -r --name-only "$target_reference"; } \
    | grep -E '(^|/)\.platform$' | sed -E 's#/?\.platform$##' | sort -u
)"

mapfile -t requested_items < <(
  printf '%s\n' "$ITEM_LIST" | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s#^/+##; s#/+$##' | grep -v '^$' || true
)
[[ ${#requested_items[@]} -gt 0 ]] || fail "No item names were given."

resolved_item_folders=()
for requested_item in "${requested_items[@]}"; do
  if grep -Fxq -- "$requested_item" <<< "$all_item_folders"; then
    resolved_item_folders+=("$requested_item")
    continue
  fi
  # Allow just the folder name (e.g. Sales_Load.Notebook) wherever it sits in the repo.
  mapfile -t matching_folders < <(awk -v wanted="$requested_item" -F/ '$NF == wanted' <<< "$all_item_folders")
  case ${#matching_folders[@]} in
    1) resolved_item_folders+=("${matching_folders[0]}") ;;
    0) fail "Item '$requested_item' was not found in '$SOURCE_BRANCH' or '$TARGET_BRANCH'. Use the folder name exactly as it appears in the repository, including the type suffix (e.g. Sales_Load.Notebook)." ;;
    *) fail "Item '$requested_item' matches more than one folder: ${matching_folders[*]}. Enter the full path instead." ;;
  esac
done

# --- 3. Create the promotion branch from the target ------------------------
safe_source_name="$(printf '%s' "$SOURCE_BRANCH" | tr -c 'A-Za-z0-9._-' '-')"
safe_target_name="$(printf '%s' "$TARGET_BRANCH" | tr -c 'A-Za-z0-9._-' '-')"
promotion_branch="promote/${safe_source_name}-to-${safe_target_name}-$(date -u +%Y%m%d-%H%M%S)"

git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git checkout --quiet -B "$promotion_branch" "$target_reference"

# --- 4. Copy each item folder exactly as it is on the source branch --------
for item_folder in "${resolved_item_folders[@]}"; do
  if git cat-file -e "$source_reference:$item_folder" 2>/dev/null; then
    # restore (unlike checkout) also removes files that were deleted on the source branch
    git restore --source="$source_reference" --staged --worktree -- "$item_folder"
    echo "Copied: $item_folder"
  else
    git rm -r --quiet -- "$item_folder"
    echo "Removed (item was deleted on $SOURCE_BRANCH): $item_folder"
  fi
done

if git diff --cached --quiet; then
  fail "Nothing to promote: the selected items in '$TARGET_BRANCH' are already identical to '$SOURCE_BRANCH'."
fi

changed_files="$(git diff --cached --stat)"
echo "$changed_files"

# --- 4b. Warn when the target has changes to an item that the source lacks --
# The promotion branch starts from the target, so the pull request is always a
# clean fast-forward: it cannot show that copying the source's folder undoes a
# newer change made on the target (e.g. a schedule edited in the workspace).
undo_report=""
for item_folder in "${resolved_item_folders[@]}"; do
  git diff --cached --quiet -- "$item_folder" && continue
  target_only_commits="$(git log -n 10 --no-merges --format='`%h` %s' "$source_reference..$target_reference" -- "$item_folder")"
  [[ -n "$target_only_commits" ]] || continue
  echo "::warning::$item_folder: '$TARGET_BRANCH' has changes that '$SOURCE_BRANCH' doesn't; promoting will undo them unless they're also on the source."
  undo_report+="- :warning: \`$item_folder\`: \`$TARGET_BRANCH\` has changes that \`$SOURCE_BRANCH\` doesn't. Promoting will undo them unless they're also on the source:"$'\n'
  undo_report+="$(sed 's/^/  - /' <<< "$target_only_commits")"$'\n'
done
[[ -n "$undo_report" ]] || undo_report="- None."$'\n'

# --- 5. Look for dependencies that are missing on the target ---------------
# Exit code 1 = a blocking error (missing %run notebook or library variable).
dependency_report_file="$(mktemp)"
if ! python3 "$script_directory/check_fabric_dependencies.py" \
  --source-reference "$source_reference" \
  --report-file "$dependency_report_file" \
  -- "${resolved_item_folders[@]}"; then
  fail "Blocked: the selected items depend on notebooks or library variables that '$TARGET_BRANCH' doesn't have. Add them to the item list and run again."$'\n\n'"$(cat "$dependency_report_file")"
fi

# --- 6. Build the pull request description ---------------------------------
item_bullets="$(printf -- '- `%s`\n' "${resolved_item_folders[@]}")"
pull_request_title="Promote to ${TARGET_BRANCH}: $(printf '%s, ' "${resolved_item_folders[@]##*/}" | sed 's/, $//')"
if [[ ${#pull_request_title} -gt 200 ]]; then
  pull_request_title="Promote to ${TARGET_BRANCH}: ${#resolved_item_folders[@]} items from ${SOURCE_BRANCH}"
fi
pull_request_body_file="$(mktemp)"
{
  echo "Promotes selected Fabric items from \`$SOURCE_BRANCH\` to \`$TARGET_BRANCH\`."
  echo
  echo "**Items**"
  echo "$item_bullets"
  echo
  echo "**Dependency check**"
  cat "$dependency_report_file"
  echo
  echo "**Changes on \`$TARGET_BRANCH\` that this promotion undoes**"
  printf '%s' "$undo_report"
  echo
  echo "**Files changed**"
  echo '```'
  echo "$changed_files"
  echo '```'
  echo
  echo "**Reviewer checklist**"
  echo "- [ ] Only the intended items are in the diff"
  echo "- [ ] Any dependency warnings above are handled"
  echo "- [ ] No :warning: 'undoes' entries above, or each one is intended"
  echo "- [ ] Any new variable these items use is in the Variable Library (\`variables.json\` and every value set) with the right value for each environment"
  echo
  echo "Triggered by @$TRIGGERED_BY${WORKFLOW_RUN_URL:+ via [workflow run]($WORKFLOW_RUN_URL)}."
} > "$pull_request_body_file"

{
  echo "### Promotion: \`$SOURCE_BRANCH\` → \`$TARGET_BRANCH\`"
  echo
  cat "$pull_request_body_file"
} >> "$STEP_SUMMARY_FILE"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run: no branch pushed and no pull request created."
  echo "---- Pull request preview ----"
  echo "Title: $pull_request_title"
  cat "$pull_request_body_file"
  exit 0
fi

# --- 7. Commit, push, open the pull request --------------------------------
git commit --quiet -m "$pull_request_title" -m "Promoted from $SOURCE_BRANCH by $TRIGGERED_BY."
git push --quiet -u origin "$promotion_branch"

if pull_request_url="$(gh pr create \
      --base "$TARGET_BRANCH" \
      --head "$promotion_branch" \
      --title "$pull_request_title" \
      --body-file "$pull_request_body_file" 2>/tmp/pull_request_error)"; then
  echo "Pull request created: $pull_request_url"
  printf '\n**Pull request:** %s\n' "$pull_request_url" >> "$STEP_SUMMARY_FILE"
  exit 0
fi

# GitHub can block the built-in token from opening pull requests (an organisation
# setting). The branch is already pushed, so give the user a one-click link to
# open the pull request themselves, with title and description pre-filled.
echo "Could not open the pull request automatically: $(cat /tmp/pull_request_error)"
repository_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
compare_url="$(python3 - "$repository_url" "$TARGET_BRANCH" "$promotion_branch" "$pull_request_title" "$pull_request_body_file" <<'PYTHON'
import sys
from pathlib import Path
from urllib.parse import quote, urlencode
repository_url, target_branch, promotion_branch, title, body_file = sys.argv[1:6]
body = Path(body_file).read_text(encoding="utf-8")
if len(body) > 5000:  # keep the link under browser URL limits
    body = body[:5000] + "\n\n(Description shortened; see the workflow run summary for the full details.)"
query = urlencode({"expand": "1", "title": title, "body": body}, quote_via=quote)
print(f"{repository_url}/compare/{quote(target_branch, safe='/')}...{quote(promotion_branch, safe='/')}?{query}")
PYTHON
)"

echo "::notice::Branch $promotion_branch is ready. Open the pull request here: $compare_url"
{
  echo
  echo "### Next step: create the pull request"
  echo
  echo "The branch \`$promotion_branch\` is ready, but GitHub does not allow this workflow to open pull requests in this repository."
  echo
  echo "**[Click here to create the pull request]($compare_url)**, then press **Create pull request**."
} >> "$STEP_SUMMARY_FILE"
