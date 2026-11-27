# Default folders of vmq, per host operating system. lib/vmq.zsh and bin/vmq-main source this file, and the mod reads the
# values through `vmq paths --json`, so the defaults are written here only.
#   VMQ_DATA   target list, hosts.tsv, queue, reservations.tsv, the vmq-main lock
#   VMQ_CACHE  the mod's shared read cache (status.json)
# macOS: ~/Library/Application Support/vmq and ~/Library/Caches/vmq.
# Linux and others: $XDG_DATA_HOME/vmq (default ~/.local/share/vmq) and $XDG_CACHE_HOME/vmq (default ~/.cache/vmq), the XDG Base
# Directory locations. A value already in the environment is kept.
if [[ $OSTYPE == darwin* ]]; then
  VMQ_DATA=${VMQ_DATA:-$HOME/Library/Application Support/vmq}
  VMQ_CACHE=${VMQ_CACHE:-$HOME/Library/Caches/vmq}
else
  VMQ_DATA=${VMQ_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/vmq}
  VMQ_CACHE=${VMQ_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/vmq}
fi
