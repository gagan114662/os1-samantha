#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
configured_hooks_path="$(git config --path core.hooksPath || true)"
if [[ -n "$configured_hooks_path" ]]; then
  case "$configured_hooks_path" in
    /*) hook_dir="$configured_hooks_path" ;;
    *) hook_dir="$repo_root/$configured_hooks_path" ;;
  esac
  hook_path="$hook_dir/pre-commit"
else
  hook_path="$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)"
  hook_dir="$(dirname "$hook_path")"
fi

mkdir -p "$hook_dir"

tmp_hook="$(mktemp "$hook_path.tmp.XXXXXX")"
cat >"$tmp_hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# OS1 build artifact guard: refuse staged SwiftPM scratch directories.
blocked=()
while IFS= read -r -d '' path; do
  case "$path" in
    .build|.build/*|.build-*|.build-*/*|*/.build|*/.build/*|*/.build-*|*/.build-*/*)
      blocked+=("$path")
      ;;
  esac
done < <(git diff --cached --name-only -z --diff-filter=ACMR)

if ((${#blocked[@]})); then
  echo "Refusing to commit SwiftPM build artifacts:" >&2
  printf '  %s\n' "${blocked[@]}" >&2
  echo "Remove them from the index with: git restore --staged -- <path>" >&2
  exit 1
fi
HOOK

if [[ -e "$hook_path" ]] && ! grep -q "OS1 build artifact guard" "$hook_path"; then
  backup_path="$hook_path.os1-backup.$(date +%Y%m%d%H%M%S)"
  cp "$hook_path" "$backup_path"
  echo "Backed up existing pre-commit hook to $backup_path"
fi

mv "$tmp_hook" "$hook_path"
chmod +x "$hook_path"
echo "Installed SwiftPM build artifact pre-commit guard at $hook_path"
