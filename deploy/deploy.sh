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
SIGN_ID="${MENUY_SIGN_IDENTITY:-Developer ID Application: Weifeng Luo (BDH2HLQA9V)}"

mkdir -p "$ROOT/landing/download" "$ROOT/dist"

echo ">> Building Release bundle with Developer ID signature and Hardened Runtime..."
bash "$ROOT/scripts/build.sh"
APP_SRC="$ROOT/build/DerivedData/Build/Products/Release/MacMenuY.app"

rm -rf "$ROOT/dist/Tuckbar.app" "$ROOT/dist/$ZIP_FILE" "$ROOT/dist/notarize-upload.zip"
cp -R "$APP_SRC" "$ROOT/dist/Tuckbar.app"
xattr -cr "$ROOT/dist/Tuckbar.app" 2>/dev/null || true

# Re-sign inside-out after copying to Tuckbar.app so the outer bundle name and seal match
sign_nested() {
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,flags --sign "$SIGN_ID" "$@"
}
SP="$ROOT/dist/Tuckbar.app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
  [ -d "$SP/XPCServices/Installer.xpc" ] && sign_nested "$SP/XPCServices/Installer.xpc"
  [ -d "$SP/XPCServices/Downloader.xpc" ] && sign_nested "$SP/XPCServices/Downloader.xpc"
  [ -f "$SP/Autoupdate" ] && sign_nested "$SP/Autoupdate"
  [ -d "$SP/Updater.app" ] && sign_nested "$SP/Updater.app"
  sign_nested "$ROOT/dist/Tuckbar.app/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --options runtime --timestamp --entitlements "$ROOT/Ice/Ice.entitlements" --sign "$SIGN_ID" "$ROOT/dist/Tuckbar.app"
codesign --verify --deep --strict "$ROOT/dist/Tuckbar.app"

# Notarize and staple with Apple Notary Service
ASC_P8="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_YXVJ8YF5QJ.p8}"
ASC_KEY_ID="${ASC_KEY_ID:-YXVJ8YF5QJ}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-38bb7382-e1d7-4fa2-8bf5-56c8c967ffb4}"

echo ">> Submitting Tuckbar.app for Apple Notarization (Key ID: $ASC_KEY_ID)..."
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/Tuckbar.app" "$ROOT/dist/notarize-upload.zip"
xcrun notarytool submit "$ROOT/dist/notarize-upload.zip" \
  --key "$ASC_P8" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait
rm -f "$ROOT/dist/notarize-upload.zip"

echo ">> Stapling notarization ticket to Tuckbar.app and MacMenuY.app..."
xcrun stapler staple "$ROOT/dist/Tuckbar.app"
xcrun stapler validate "$ROOT/dist/Tuckbar.app"
spctl -a -vvv -t exec "$ROOT/dist/Tuckbar.app"

# Also staple the local build bundle so local runs are notarized too
xcrun stapler staple "$APP_SRC" || true

# Package the stapled Tuckbar.app into final distribution zip
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/Tuckbar.app" "$ROOT/dist/$ZIP_FILE"
cp "$ROOT/dist/$ZIP_FILE" "$ROOT/landing/download/$ZIP_FILE"
cp "$ROOT/dist/$ZIP_FILE" "$ROOT/landing/download/Tuckbar-latest.zip"

SHA=$(shasum -a 256 "$ROOT/landing/download/$ZIP_FILE" | awk '{print $1}')
SIZE=$(awk -v b="$(stat -f%z "$ROOT/landing/download/$ZIP_FILE")" 'BEGIN{printf "%.1f MB", b/1048576}')
printf '{"name":"Tuckbar","version":"%s","file":"%s","size":"%s","sha256":"%s","date":"%s","notarized":true,"url":"https://tuckbar.novarock.io/download/%s"}\n' \
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

echo ">> Deployed notarized $TAG -> https://tuckbar.novarock.io (SHA256: $SHA)"
