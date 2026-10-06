#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
trap 'result=$?; if [ "$result" -ne 0 ]; then echo; echo "ビルドに失敗しました。上のエラーを確認してください。"; read -r -p "Enterで閉じる…" answer; fi' EXIT
if [ "$(uname -s)" != "Darwin" ]; then
    echo "このスクリプトはMac上で実行してください。"
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Xcode 15以降、またはSwift 5.9以降のCommand Line Toolsをインストールしてください。"
    echo "Command Line Toolsのインストール: xcode-select --install"
    exit 1
fi
echo "GrowthFilmのビルドと目の位置合わせテストを実行します…"
swift test -c release
swift build -c release --product GrowthFilm
binary_dir="$(swift build -c release --show-bin-path)"
output_dir="$PWD/dist"
app_dir="$output_dir/GrowthFilm.app"
staging_dir="$(mktemp -d "$PWD/.app-stage.XXXXXX")"
trap 'result=$?; rm -rf -- "$staging_dir"; if [ "$result" -ne 0 ]; then echo "ビルドに失敗しました。上のエラーを確認してください。"; read -r -p "Enterで閉じる…" answer; fi' EXIT
mkdir -p "$staging_dir/GrowthFilm.app/Contents/MacOS" "$staging_dir/GrowthFilm.app/Contents/Resources" "$output_dir"
cp "$binary_dir/GrowthFilm" "$staging_dir/GrowthFilm.app/Contents/MacOS/GrowthFilm"
cp Info.plist "$staging_dir/GrowthFilm.app/Contents/Info.plist"
chmod +x "$staging_dir/GrowthFilm.app/Contents/MacOS/GrowthFilm"
codesign --force --sign - "$staging_dir/GrowthFilm.app"
codesign --verify --verbose "$staging_dir/GrowthFilm.app"
if [ -e "$app_dir" ]; then
    backup_dir="$output_dir/GrowthFilm-previous-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$app_dir" "$backup_dir"
    echo "前のアプリを保存: $backup_dir"
fi
mv "$staging_dir/GrowthFilm.app" "$app_dir"
echo "完成: $app_dir"
echo "このアプリをApplicationsフォルダにドラッグして使えます。"
open -R "$app_dir"
open "$app_dir"
