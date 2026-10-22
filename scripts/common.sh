# Shared helpers. Source this file; don't run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_NAME="Dowlio"
APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"
SIGN_IDENTITY_NAME="Dowlio Self Signed"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# The version lives in project.yml only.
project_version() {
  sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$ROOT/project.yml" | head -n1
}
