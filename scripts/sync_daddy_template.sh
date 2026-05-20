#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_ROOT="${DADDY_TEMPLATE_PATH:-}"
PATHS_CSV="docs,scripts"
DRY_RUN=false
DELETE_MODE=false

usage() {
  cat <<'EOF'
Usage:
  sync_daddy_template.sh -s <daddy_template_path> [options]

Options:
  -s, --source PATH   Path to daddy_template root (required unless DADDY_TEMPLATE_PATH is set)
  -p, --paths LIST    Comma-separated relative paths to sync
                      Default: docs,scripts
  -n, --dry-run       Show what would change without copying
  --delete            Delete files in destination not present in source (dirs only)
  -h, --help          Show this help

Examples:
  ./scripts/sync_daddy_template.sh -s /path/to/daddy_template
  ./scripts/sync_daddy_template.sh -s /path/to/daddy_template -p docs,scripts
  ./scripts/sync_daddy_template.sh -s /path/to/daddy_template -p scripts -n
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)
      SOURCE_ROOT="$2"
      shift 2
      ;;
    -p|--paths)
      PATHS_CSV="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --delete)
      DELETE_MODE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_ROOT" ]]; then
  echo "Error: source path is required. Use -s or set DADDY_TEMPLATE_PATH."
  exit 1
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "Error: source path does not exist: $SOURCE_ROOT"
  exit 1
fi

IFS=',' read -r -a PATHS <<< "$PATHS_CSV"

RSYNC_ARGS=(-a)
if [[ "$DRY_RUN" == "true" ]]; then
  RSYNC_ARGS+=(-n -v)
fi

for rel_path in "${PATHS[@]}"; do
  rel_path="${rel_path#/}"
  src="$SOURCE_ROOT/$rel_path"
  dst="$DEST_ROOT/$rel_path"

  if [[ ! -e "$src" ]]; then
    echo "Skip (missing): $src"
    continue
  fi

  mkdir -p "$(dirname "$dst")"

  if [[ -d "$src" ]]; then
    if [[ "$DELETE_MODE" == "true" ]]; then
      rsync "${RSYNC_ARGS[@]}" --delete "$src/" "$dst/"
    else
      rsync "${RSYNC_ARGS[@]}" "$src/" "$dst/"
    fi
  else
    rsync "${RSYNC_ARGS[@]}" "$src" "$dst"
  fi
done

echo "Done."
