#!/usr/bin/env bash
# Runs the image as prod does (uid 65532, read-only root, no capabilities)
# and converts one document per engine. Usage: smoke-test.sh <image>
set -euo pipefail
image=$1
dir=$(mktemp -d)
trap 'docker rm -f smoke >/dev/null 2>&1 || true; rm -rf "$dir"' EXIT

docker run -d --name smoke -p 127.0.0.1:3000:3000 \
  --read-only --user 65532:65532 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:uid=65532,gid=65532 --tmpfs /home/nonroot:uid=65532,gid=65532 \
  "$image" >/dev/null

for _ in $(seq 60); do
  curl -sf localhost:3000/health >/dev/null && break
  sleep 1
done
curl -sf localhost:3000/health && echo

cat >"$dir/index.html" <<'HTML'
<html><head><meta charset="utf-8"></head>
<body><h1>Invoice €1,234.56</h1><p>日本語 中文 العربية</p></body></html>
HTML
printf 'a,b\n1,2\n' >"$dir/sheet.csv"

convert() {
  local route=$1 file=$2
  curl -sf -o "$dir/out.pdf" -F "files=@$dir/$file" "localhost:3000$route"
  [[ $(head -c 5 "$dir/out.pdf") == %PDF- ]] || { echo "$route: not a PDF" >&2; exit 1; }
  echo "$route ($file): OK"
}
convert /forms/chromium/convert/html index.html
convert /forms/libreoffice/convert sheet.csv
