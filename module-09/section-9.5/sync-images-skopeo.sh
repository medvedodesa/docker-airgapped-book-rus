#!/usr/bin/env bash
# Синхронизация образов между реестрами через skopeo (без Docker daemon)
# Использование: bash sync-images-skopeo.sh <sync_list_file> [src_registry] [dst_registry]
set -euo pipefail

SYNC_LIST="${1:-images-to-sync.txt}"
SRC_REGISTRY="${2:-}"     # пусто = из файла списка
DST_REGISTRY="${3:-harbor.internal.company.local}"
DST_USER="${HARBOR_USER:-admin}"
DST_PASS="${HARBOR_PASS:-}"
SRC_CA="${SRC_CA:-}"
DST_CA="${DST_CA:-/etc/ssl/certs/ca-certificates.crt}"

echo "=== Синхронизация образов через skopeo ==="
echo "  Список: $SYNC_LIST"
echo "  Цель:   $DST_REGISTRY"

command -v skopeo &>/dev/null || { echo "[FAIL] skopeo не установлен"; exit 1; }
[ -n "$DST_PASS" ] || { echo "[FAIL] HARBOR_PASS не установлен"; exit 1; }
[ -f "$SYNC_LIST" ] || { echo "[FAIL] Файл списка не найден: $SYNC_LIST"; exit 1; }

SUCCESS=0; FAILED=0

echo ""
echo "--- Синхронизация ---"

while IFS= read -r line || [ -n "$line" ]; do
  # Пропуск комментариев и пустых строк
  [[ "$line" =~ ^#.*$ ]] || [ -z "$line" ] && continue

  # Формат строки: src_image dst_project/repo:tag
  src_image=$(echo "$line" | awk '{print $1}')
  dst_ref=$(echo "$line"  | awk '{print $2}')

  [ -n "$src_image" ] || continue
  [ -n "$dst_ref" ] || dst_ref="$src_image"

  dst_image="docker://${DST_REGISTRY}/${dst_ref}"
  [ -n "$SRC_REGISTRY" ] && src_full="docker://${SRC_REGISTRY}/${src_image}" || \
    src_full="docker://${src_image}"

  echo -n "  $src_image → $dst_ref ... "

  skopeo_args=(
    "--dest-creds" "${DST_USER}:${DST_PASS}"
    "--dest-tls-verify=true"
  )
  [ -n "$SRC_CA" ] && skopeo_args+=("--src-cert-dir" "$SRC_CA")
  [ -n "$DST_CA" ] && skopeo_args+=("--dest-cert-dir" "$(dirname $DST_CA)")

  if skopeo copy \
    "${skopeo_args[@]}" \
    "$src_full" "$dst_image" \
    2>/dev/null; then
    echo "OK"
    ((SUCCESS++))
  else
    echo "FAIL"
    ((FAILED++))
  fi

done < "$SYNC_LIST"

echo ""
echo "=== Синхронизация завершена: OK=$SUCCESS  FAIL=$FAILED ==="

[ "$FAILED" -eq 0 ] || exit 1
