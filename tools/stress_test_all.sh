#!/bin/bash

IMAGES_BASE=https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.1.0-stress

# | `:new_cm`    | New Computer Modern Math      | CM / serif         |
# | `:pagella`   | TeX Gyre Pagella Math         | Palatino           |
# | `:luciole`   | Luciole Math                  | Humanist sans      |
# | `:stix_two`  | STIX Two Math v2.0.2          | Times              |
# | `:fira_math` | Fira Math + Fira Sans v0.3.4  | Geometric sans     |
# | `:schola`    | TeX Gyre Schola Math          | Century Schoolbook |
# | `:termes`    | TeX Gyre Termes Math          | Times New Roman    |
# | `:bonum`     | TeX Gyre Bonum Math           | ITC Bookman        |

mkdir -p images_new
mkdir -p images_old
mkdir -p images_comparison

if [ $# -gt 0 ]; then
    FONT_NAMES=("$@")
else
    FONT_NAMES=(new_cm pagella luciole stix_two fira_math schola termes bonum)
fi

for name in "${FONT_NAMES[@]}"; do
    echo "# Testing font: ${name}"
    julia stress_test_sheet.jl :${name} images_new/stress_test_output_${name}.png
    if [ ! -f images_old/stress_test_output_${name}.png ]; then
        curl -sL ${IMAGES_BASE}/stress_test_output_${name}.png -o images_old/stress_test_output_${name}.png
    fi
    julia png_diff.jl images_old/stress_test_output_${name}.png images_new/stress_test_output_${name}.png images_comparison/diff_${name}.png
    echo
done
