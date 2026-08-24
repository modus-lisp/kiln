# config.sh — read /etc/kiln/config into the environment.
#
# Sourced by boot/entrypoint.sh (inside the image) and by bin/kiln (on the host), so
# there is exactly ONE implementation of what the .config means.  It was briefly two,
# which is the arrangement that guarantees they eventually disagree about something
# small and load-bearing.
#
# POSIX sh on purpose: the entrypoint runs under dash.

# ---- the .config, applied ----------------------------------------------------
#
# `kiln config' (the menuconfig TUI, over ssh) writes /etc/kiln/config, and until now
# NOTHING READ IT AT BOOT.  The file recorded a choice that never took effect, which is
# worse than having no file at all: the setting is right there in the config, so the
# reasonable conclusion when the box does not do it is that the feature is broken.
#
# Kernel format, so "off" and "never mentioned" stay distinguishable: KEY=value for a
# setting, "# KEY is not set" for a disabled bool.  A commented key is simply not
# exported, which is exactly what makes a disabled bool false here.
#
# THE ENVIRONMENT WINS.  A value passed with -e is this run's explicit instruction and
# the file is the standing preference, so a flag on the command line is never silently
# overridden by something written weeks ago.
load_config() {
  cfg=${KILN_ETC:-/etc/kiln}/config
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|' '*) continue ;;
      [A-Z_]*=*) : ;;
      *) continue ;;
    esac
    k=${line%%=*}
    v=${line#*=}
    # A key is a key: anything else in this file is not ours to export.
    case "$k" in
      *[!A-Z0-9_]*) continue ;;
    esac
    # One layer of quotes, the way the writer emits them.
    case "$v" in
      \"*\") v=${v#\"}; v=${v%\"} ;;
      \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    [ -n "$v" ] || continue
    eval "cur=\${$k-}"
    [ -n "$cur" ] && continue
    export "$k=$v"
  done < "$cfg"
}
