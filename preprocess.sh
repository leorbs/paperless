#!/bin/sh
# Preprocess a single scan image before handing it to paperless.
#
# JPG scans are normalized with ImageMagick. Two modes, selected by the
# source DPI (detected with `magick identify`):
#
#   * <= DPI_THRESHOLD (default 300): keep the native resolution, normalize.
#   * >  DPI_THRESHOLD:               downscale 50% (e.g. 600 -> 300 dpi),
#                                     tag the output 300 dpi, normalize.
#
# Normalization: white-balance, level 10%-85%, sharpen, JPEG quality 92.
# PDFs are not processed here - the client passes them straight through.
#
# Usage: preprocess <input> <output>
#
# Environment:
#   DPI_THRESHOLD   dpi above which a scan is downscaled (default 300)

set -eu

DPI_THRESHOLD="${DPI_THRESHOLD:-300}"

if [ "$#" -ne 2 ]; then
  echo "usage: preprocess <input> <output>" >&2
  exit 2
fi

input="$1"
output="$2"

# The caller stages the raw JPEG under a `.jpg` name, so ImageMagick detects
# the format from the extension.
dpi=$(magick identify -format '%x\n' "$input" 2>/dev/null | head -n 1)
case "$dpi" in
  ''|*[!0-9]*) dpi=0 ;;
esac

if [ "$dpi" -gt "$DPI_THRESHOLD" ]; then
  magick "$input" \
    -filter Lanczos -resize 50% -density 300 \
    -white-balance -level 10%,85% -sharpen 0x0.7 -quality 92 \
    "$output"
else
  magick "$input" \
    -white-balance -level 10%,85% -sharpen 0x0.7 -quality 92 \
    "$output"
fi
