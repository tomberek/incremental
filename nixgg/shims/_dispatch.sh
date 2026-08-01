# Sourced by every shim (cc/gcc/c++/g++/ar/ranlib).
# Expands @rspfile arguments in-place so the shim can inspect real
# argv (need to see -c / -o / etc. before choosing a driver).

if printf '%s\0' "$@" | grep -qz '^@'; then
  _nixgg_args=()
  for _nixgg_a in "$@"; do
    if [[ "$_nixgg_a" == @* && -f "${_nixgg_a:1}" ]]; then
      while IFS= read -r _nixgg_line; do
        read -r -a _nixgg_words <<< "$_nixgg_line"
        for _nixgg_w in "${_nixgg_words[@]}"; do
          _nixgg_w="${_nixgg_w#\"}"; _nixgg_w="${_nixgg_w%\"}"
          _nixgg_w="${_nixgg_w#\'}"; _nixgg_w="${_nixgg_w%\'}"
          [[ -n "$_nixgg_w" ]] && _nixgg_args+=( "$_nixgg_w" )
        done
      done < "${_nixgg_a:1}"
    else
      _nixgg_args+=( "$_nixgg_a" )
    fi
  done
  set -- "${_nixgg_args[@]}"
  unset _nixgg_args _nixgg_a _nixgg_line _nixgg_words _nixgg_w
fi
