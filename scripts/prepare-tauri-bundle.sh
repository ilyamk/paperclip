#!/bin/bash
set -euo pipefail

# Prepare a self-contained app directory for Tauri bundling.
# This script creates bundle-app/ inside src-tauri/ with:
#   - Node.js binary (macOS arm64)
#   - Server dist + production node_modules (via pnpm deploy)
#   - UI dist (pre-built static files)
#   - Embedded PostgreSQL (via @embedded-postgres/darwin-arm64)
#   - All workspace packages compiled to JS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$PROJECT_ROOT/src-tauri/bundle-app"
NODE_VERSION="20.19.0"
ARCH="$(uname -m)"

# Map architecture
if [ "$ARCH" = "arm64" ]; then
  NODE_ARCH="arm64"
elif [ "$ARCH" = "x86_64" ]; then
  NODE_ARCH="x64"
else
  echo "Unsupported architecture: $ARCH"
  exit 1
fi

echo "==> Preparing Tauri bundle (arch=$NODE_ARCH)"

# Clean previous bundle
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# --- Step 1: Download Node.js binary ---
NODE_TAR="node-v${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
NODE_CACHE="/tmp/$NODE_TAR"
if [ ! -f "$NODE_CACHE" ]; then
  echo "==> Downloading Node.js v${NODE_VERSION} for darwin-${NODE_ARCH}..."
  curl -fSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}" -o "$NODE_CACHE"
fi

echo "==> Extracting Node.js binary..."
tar -xzf "$NODE_CACHE" -C /tmp
cp "/tmp/node-v${NODE_VERSION}-darwin-${NODE_ARCH}/bin/node" "$BUNDLE_DIR/node"
chmod +x "$BUNDLE_DIR/node"
rm -rf "/tmp/node-v${NODE_VERSION}-darwin-${NODE_ARCH}"

# --- Step 2: Build the project ---
echo "==> Building project..."
cd "$PROJECT_ROOT"
pnpm run build

# --- Step 3: Deploy server with production dependencies ---
echo "==> Running pnpm deploy for server (production deps only)..."
DEPLOY_DIR="$BUNDLE_DIR/app"
pnpm --filter @paperclipai/server deploy "$DEPLOY_DIR"

# --- Step 4: Copy UI dist into the server deploy ---
echo "==> Copying UI dist..."
mkdir -p "$DEPLOY_DIR/ui-dist"
cp -r "$PROJECT_ROOT/ui/dist/"* "$DEPLOY_DIR/ui-dist/"

# --- Step 5: Fix workspace package exports to use dist/ instead of src/ ---
echo "==> Patching workspace package exports for production..."
for pkg_dir in "$DEPLOY_DIR/node_modules/@paperclipai/"*/; do
  pkg_json="$pkg_dir/package.json"
  if [ -f "$pkg_json" ]; then
    # Replace "./src/index.ts" -> "./dist/index.js" and "./src/*.ts" -> "./dist/*.js"
    if command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
with open('$pkg_json', 'r') as f:
    data = json.load(f)
exports = data.get('exports', {})
changed = False
for key in list(exports.keys()):
    val = exports[key]
    if isinstance(val, str) and val.startswith('./src/') and val.endswith('.ts'):
        exports[key] = val.replace('./src/', './dist/').replace('.ts', '.js')
        changed = True
if changed:
    data['exports'] = exports
    with open('$pkg_json', 'w') as f:
        json.dump(data, f, indent=2)
    print(f'  Patched: {\"$pkg_json\".split(\"/\")[-2]}')
"
    fi
  fi
done

# Also patch the server's own package.json exports
python3 -c "
import json
pkg = '$DEPLOY_DIR/package.json'
with open(pkg, 'r') as f:
    data = json.load(f)
exports = data.get('exports', {})
for key in list(exports.keys()):
    val = exports[key]
    if isinstance(val, str) and val.startswith('./src/') and val.endswith('.ts'):
        exports[key] = val.replace('./src/', './dist/').replace('.ts', '.js')
data['exports'] = exports
with open(pkg, 'w') as f:
    json.dump(data, f, indent=2)
print('  Patched: server package.json')
"

# --- Step 6: Copy DB migrations ---
echo "==> Ensuring DB migrations are included..."
MIGRATIONS_SRC="$DEPLOY_DIR/node_modules/@paperclipai/db/dist/migrations"
if [ ! -d "$MIGRATIONS_SRC" ]; then
  echo "  Copying migrations from project source..."
  cp -r "$PROJECT_ROOT/packages/db/dist/migrations" "$MIGRATIONS_SRC" 2>/dev/null || \
  cp -r "$PROJECT_ROOT/packages/db/src/migrations" "$MIGRATIONS_SRC" 2>/dev/null || \
  echo "  WARNING: Could not find migrations directory"
fi

# --- Step 7: Create a launcher script for the server ---
cat > "$DEPLOY_DIR/start.sh" << 'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../node" "$DIR/dist/index.js" "$@"
LAUNCHER
chmod +x "$DEPLOY_DIR/start.sh"

# --- Step 8: Clean up unnecessary files to reduce size ---
echo "==> Cleaning up unnecessary files..."
# Remove TypeScript source maps and declaration files from dependencies
find "$DEPLOY_DIR/node_modules" -name "*.d.ts" -delete 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "*.d.ts.map" -delete 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "*.js.map" -delete 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "*.ts.map" -delete 2>/dev/null || true
# Remove docs and tests from deps
find "$DEPLOY_DIR/node_modules" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -type d -name "__tests__" -exec rm -rf {} + 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "CHANGELOG.md" -delete 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "CHANGELOG" -delete 2>/dev/null || true
find "$DEPLOY_DIR/node_modules" -name "README.md" -not -path "*embedded-postgres*" -delete 2>/dev/null || true

# --- Report ---
BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
NODE_SIZE=$(du -sh "$BUNDLE_DIR/node" | cut -f1)
APP_SIZE=$(du -sh "$DEPLOY_DIR" | cut -f1)
PG_SIZE=$(du -sh "$DEPLOY_DIR/node_modules/.pnpm/@embedded-postgres+darwin-"*/node_modules/@embedded-postgres/*/native/ 2>/dev/null | cut -f1 || echo "N/A")

echo ""
echo "==> Bundle prepared successfully!"
echo "    Location:   $BUNDLE_DIR"
echo "    Total size:  $BUNDLE_SIZE"
echo "    Node.js:     $NODE_SIZE"
echo "    App:         $APP_SIZE"
echo "    PostgreSQL:  $PG_SIZE"
echo ""
