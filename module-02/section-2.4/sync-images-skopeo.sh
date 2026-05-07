#!/usr/bin/env bash
# Синхронизация образов через Skopeo: из внешнего реестра в директорию и обратно в Harbor
# Использование:
#   На машине с интернетом:  sync-images-skopeo.sh export images.txt ./sync-bundle/
#   В закрытом контуре:      sync-images-skopeo.sh import ./sync-bundle/ harbor.internal.company.local
set -euo pipefail

MODE="${1:-}"           # export или import
IMAGES_OR_SRC="${2:-}"  # при export — файл со списком образов; при import — путь к директории
DEST="${3:-}"           # при export — директория; при import — целевой Harbor

usage() {
  echo "Использование:"
  echo "  $0 export images.txt ./sync-bundle/"
  echo "  $0 import ./sync-bundle/ harbor.internal.company.local"
  exit 1
}

[ -z "$MODE" ] || [ -z "$IMAGES_OR_SRC" ] || [ -z "$DEST" ] && usage

case "$MODE" in
  export)
    IMAGES_FILE="$IMAGES_OR_SRC"
    BUNDLE_DIR="$DEST"
    mkdir -p "$BUNDLE_DIR"
    echo "=== Экспорт образов в $BUNDLE_DIR ==="
    while IFS= read -r image; do
      [[ "$image" =~ ^#|^$ ]] && continue
      echo "Синхронизация: $image"
      skopeo sync \
        --src docker \
        --dest dir \
        "$image" \
        "$BUNDLE_DIR/"
    done < "$IMAGES_FILE"
    echo "Готово. Размер директории: $(du -sh "$BUNDLE_DIR" | cut -f1)"
    ;;

  import)
    BUNDLE_DIR="$IMAGES_OR_SRC"
    HARBOR="$DEST"
    echo "=== Импорт образов из $BUNDLE_DIR в $HARBOR ==="
    skopeo sync \
      --src dir \
      --dest docker \
      --dest-tls-verify=true \
      "$BUNDLE_DIR/" \
      "$HARBOR/"
    echo "Готово."
    ;;

  inspect)
    # Быстрая проверка дайджеста образа без загрузки
    IMAGE="${IMAGES_OR_SRC}"
    echo "Inspect: $IMAGE"
    skopeo inspect "docker://$IMAGE"
    ;;

  copy)
    # Прямое копирование между двумя Harbor-реестрами (если есть сетевой канал)
    SRC_IMAGE="$IMAGES_OR_SRC"
    DEST_IMAGE="$DEST"
    echo "Копирование: $SRC_IMAGE -> $DEST_IMAGE"
    skopeo copy \
      "docker://$SRC_IMAGE" \
      "docker://$DEST_IMAGE"
    ;;

  *)
    usage
    ;;
esac
