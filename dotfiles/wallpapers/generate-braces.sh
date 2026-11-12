#!/usr/bin/env bash
# Generate braces { } wallpapers with glowing echo effect
# Requires: ImageMagick 7 (magick command)
# Output: braces-{name}-4k.png files (3840x2160)
#
# Usage:
#   ./generate-braces.sh              # Generate all variants
#   ./generate-braces.sh emerald      # Generate single variant
#   ./generate-braces.sh --grub       # Generate 1024x768 pixelated GRUB version

set -euo pipefail
cd "$(dirname "$0")"

W=3840
H=2160
BRACE_SIZE=400
ECHO_LAYERS=6

# Color variants: name -> "foreground background"
declare -A VARIANTS=(
    [emerald]="#00cc44 #0a1a0a"
    [amber]="#cc8800 #1a140a"
    [crimson]="#cc2200 #1a0a0a"
    [crimson-blue]="#cc2200:#2244cc #1a0a10"
    [ocean]="#0066cc #0a0a1a"
    [purple-cyan]="#9933cc:#00cccc #100a1a"
)

generate_brace() {
    local name="$1"
    local spec="${VARIANTS[$name]}"
    local fg="${spec%% *}"
    local bg="${spec#* }"
    local fg1="${fg%%:*}"
    local fg2="${fg#*:}"
    [ "$fg1" = "$fg2" ] && fg2="$fg1"  # single color = both same
    local outfile="braces-${name}-4k.png"

    echo "Generating $outfile ($fg1/$fg2 on $bg)..."

    # Start with dark background + radial gradient
    magick -size ${W}x${H} \
        xc:"$bg" \
        \( -size ${W}x${H} radial-gradient:"${fg1}15"-"${bg}" \) \
        -compose screen -composite \
        /tmp/braces-bg.png

    # Generate left brace { with echo layers
    local cx_l=$((W/2 - BRACE_SIZE/2 - 40))
    local cx_r=$((W/2 + BRACE_SIZE/2 + 40))
    local cy=$((H/2))

    magick /tmp/braces-bg.png \
        $(for i in $(seq $ECHO_LAYERS -1 0); do
            local alpha=$((20 + (255-20) * (ECHO_LAYERS-i) / ECHO_LAYERS))
            local scale=$(echo "1 + $i * 0.3" | bc)
            local sz=$(printf "%.0f" "$(echo "$BRACE_SIZE * $scale" | bc)")
            local color
            if [ $((i % 2)) -eq 0 ]; then color="$fg1"; else color="$fg2"; fi
            local hex_alpha=$(printf "%02x" $alpha)
            echo "-fill ${color}${hex_alpha} -font DejaVu-Sans -pointsize $sz"
            echo "-gravity center -annotate +$((cx_l - W/2))+0 {"
            echo "-fill ${color}${hex_alpha} -font DejaVu-Sans -pointsize $sz"
            echo "-gravity center -annotate +$((cx_r - W/2))+0 }"
        done) \
        -blur 0x1 \
        "$outfile"

    echo "  -> $outfile ($(du -h "$outfile" | cut -f1))"
}

generate_grub() {
    local src="${1:-braces-emerald-4k.png}"
    local out="grub-background.png"
    echo "Generating pixelated GRUB background from $src..."
    magick "$src" -resize 128x72\! -scale 1024x768\! "$out"
    echo "  -> $out ($(du -h "$out" | cut -f1))"
}

# Main
if [ "${1:-}" = "--grub" ]; then
    generate_grub "${2:-braces-emerald-4k.png}"
elif [ -n "${1:-}" ]; then
    generate_brace "$1"
else
    for name in "${!VARIANTS[@]}"; do
        generate_brace "$name"
    done
fi
