#!/bin/bash
# Xcode supplies the target architectures and copies/signs the resulting helper.
set -euo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:/opt/local/bin"
if ! command -v go >/dev/null 2>&1; then
    echo "error: Install Go 1.26 or later to build Sightport’s Kubernetes client." >&2
    exit 1
fi

cd "$SRCROOT/Tools/kube-client"
export GOWORK=off GOOS=darwin CGO_ENABLED=0
work="$TARGET_TEMP_DIR/kube-client"
mkdir -p "$work" "$DERIVED_FILE_DIR"
architectures=()
for arch in $ARCHS; do
    case "$arch" in
        arm64) goarch=arm64 ;;
        x86_64) goarch=amd64 ;;
        *) echo "error: Unsupported Kubernetes client architecture: $arch" >&2; exit 1 ;;
    esac
    binary="$work/$arch/sightport-kube"
    mkdir -p "$work/$arch"
    GOARCH="$goarch" go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' -o "$binary" .
    architectures+=("$binary")
done
xcrun lipo -create "${architectures[@]}" -output "$DERIVED_FILE_DIR/sightport-kube"
# CodeSignOnCopy replaces this identity and preserves the identifier and runtime flags.
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --identifier "$PRODUCT_BUNDLE_IDENTIFIER.kube" "$DERIVED_FILE_DIR/sightport-kube"

# Include the notices of the Go toolchain and modules actually linked.
go list -mod=readonly -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}{{"\t"}}{{.Dir}}{{end}}{{end}}' . \
    | LC_ALL=C sort -u > "$work/modules"
notices="$DERIVED_FILE_DIR/Kubernetes-LICENSES.txt"
goroot=$(go env GOROOT)
go_license="$goroot/LICENSE"
# Homebrew moves the license one level above GOROOT in its package.
[[ -f "$go_license" ]] || go_license="$goroot/../LICENSE"
{
    echo "Go standard library"
    cat "$go_license" "$goroot/PATENTS"
    while IFS=$'\t' read -r module dir; do
        [[ -n "$dir" ]] || continue
        printf '\n%s\n' "$module"
        for file in "$dir"/LICENSE* "$dir"/COPYING* "$dir"/NOTICE* "$dir"/PATENTS; do
            [[ ! -f "$file" ]] || cat "$file"
        done
    done < "$work/modules"
} > "$notices"
