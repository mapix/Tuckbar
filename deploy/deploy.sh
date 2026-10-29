#!/usr/bin/env bash
set -euo pipefail

if [ -z "${HOST:-}" ]; then
  if ssh -o ConnectTimeout=2 novarocks true 2>/dev/null; then HOST=novarocks; else HOST=novarocks-public; fi
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR="tuckbar-landing-build"
TAG="tuckbar-landing:$(date +%Y%m%d-%H%M%S)"
VERSION="${VERSION:-1.0.0}"
ZIP_FILE="Tuckbar-${VERSION}.zip"

mkdir -p "$ROOT/landing/download" "$ROOT/dist"

APP_SRC="$ROOT/build/DerivedData/Build/Products/Release/MacMenuY.app"
if [ ! -d "$APP_SRC" ]; then
  echo "Building Release bundle..."
  bash "$ROOT/scripts/build.sh"
fi

rm -rf "$ROOT/dist/Tuckbar.app" "$ROOT/dist/$ZIP_FILE"
cp -R "$APP_SRC" "$ROOT/dist/Tuckbar.app"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/Tuckbar.app" "$ROOT/dist/$ZIP_FILE"
cp "$ROOT/dist/$ZIP_FILE" "$ROOT/landing/download/$ZIP_FILE"
cp "$ROOT/dist/$ZIP_FILE" "$ROOT/landing/download/Tuckbar-latest.zip"

SHA=$(shasum -a 256 "$ROOT/landing/download/$ZIP_FILE" | awk '{print $1}')
SIZE=$(awk -v b="$(stat -f%z "$ROOT/landing/download/$ZIP_FILE")" 'BEGIN{printf "%.1f MB", b/1048576}')
printf '{"name":"Tuckbar","version":"%s","file":"%s","size":"%s","sha256":"%s","date":"%s","url":"https://tuckbar.novarock.io/download/%s"}\n' \
  "$VERSION" "$ZIP_FILE" "$SIZE" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ZIP_FILE" > "$ROOT/landing/download/latest.json"

echo ">> Syncing landing/ and deploy/ to $HOST:~/$REMOTE_DIR..."
ssh "$HOST" "mkdir -p ~/$REMOTE_DIR"
rsync -az --delete --chmod=Da+rx,Fa+r "$ROOT/landing/" "$HOST:~/$REMOTE_DIR/landing/"
rsync -az --delete --chmod=Da+rx,Fa+r "$ROOT/deploy/" "$HOST:~/$REMOTE_DIR/deploy/"

echo ">> Building container image $TAG and rolling out on $HOST k8s..."
ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
cd ~/$REMOTE_DIR
docker build -f deploy/Dockerfile -t "$TAG" .
docker save "$TAG" | ctr -n k8s.io images import -
kubectl apply -f deploy/k8s.yaml
kubectl -n tuckbar set image deployment/landing web="docker.io/library/$TAG"
kubectl -n tuckbar rollout status deployment/landing --timeout=180s
REMOTE

echo ">> Deployed $TAG -> https://tuckbar.novarock.io"
