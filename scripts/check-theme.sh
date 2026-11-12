#!/usr/bin/env bash
# Lists the places that still use literal design values instead of Theme
# tokens: font sizes, corner radii, opacities and spring/ease curves.
#   scripts/check-theme.sh           -> report per file, always exits 0
#   scripts/check-theme.sh --strict  -> exits 1 if anything is left
# Theme.swift itself is skipped. Run it before and after migrating a view.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
  'size: [0-9]'                      # .system(size: 11) and .custom(_, size: 11)
  'cornerRadius: [0-9]'
  '\.opacity\(0?\.[0-9]'
  '\.spring\(response:'
  '\.ease(In|Out|InOut)\(duration:'
)

total=0
printf '%-44s %6s %6s %8s %8s %6s\n' file fonts radii opacity springs eases
while IFS= read -r file; do
  counts=()
  sum=0
  for p in "${patterns[@]}"; do
    n=$(grep -cE "$p" "$file" || true)
    counts+=("$n")
    sum=$((sum + n))
  done
  if ((sum > 0)); then
    printf '%-44s %6s %6s %8s %8s %6s\n' "${file#Sources/Margin/}" "${counts[@]}"
    total=$((total + sum))
  fi
done < <(find Sources/Margin -name '*.swift' ! -name 'Theme.swift' | sort)

echo
echo "$total literal values left outside Theme.swift"
if [[ "${1:-}" == "--strict" && $total -gt 0 ]]; then
  exit 1
fi
