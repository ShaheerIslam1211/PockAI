#!/usr/bin/env bash
# Builds the Linux packages into ../build/linux using Docker (works from macOS or Linux):
#   pockai-touchbar_<v>_all.deb      Ubuntu, Linux Mint, Debian, Pop!_OS
#   pockai-touchbar-<v>-1.noarch.rpm Fedora, openSUSE
#   pockai-touchbar-<v>-linux.tar.gz any distro (contains install.sh)
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' pockai-touchbar)
OUT=../build/linux
rm -rf "$OUT"; mkdir -p "$OUT"

# Plain archive with the installer.
STAGE=$(mktemp -d)
mkdir -p "$STAGE/pockai-touchbar-$VERSION"
cp -R install.sh pockai-touchbar layouts README.md "$STAGE/pockai-touchbar-$VERSION/"
tar -C "$STAGE" -czf "$OUT/pockai-touchbar-$VERSION-linux.tar.gz" "pockai-touchbar-$VERSION"
rm -rf "$STAGE"

# .deb and .rpm with fpm.
docker run --rm -v "$PWD":/src -v "$(cd "$OUT" && pwd)":/out -w /src ruby:3.3 bash -ec "
  apt-get update -qq >/dev/null && apt-get install -y -qq rpm >/dev/null
  gem install --no-document fpm >/dev/null
  common=(-s dir -n pockai-touchbar -v $VERSION -a all --license MIT
          --description 'PockAI Touch Bar layouts for Linux on MacBook Pro (tiny-dfr)'
          --url 'https://github.com/AsahiLinux/tiny-dfr' --maintainer 'PockAI'
          --after-install packaging/after-install.sh --before-remove packaging/before-remove.sh
          pockai-touchbar=/usr/bin/pockai-touchbar layouts/=/usr/share/pockai-touchbar/layouts/)
  fpm -t deb -p /out/ --deb-recommends tiny-dfr \"\${common[@]}\"
  fpm -t rpm -p /out/ -d tiny-dfr --rpm-os linux \"\${common[@]}\"
"
ls -l "$OUT"
