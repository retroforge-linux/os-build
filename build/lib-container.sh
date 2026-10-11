# Container runtime for the host-side build scripts — sourced, not run.
#
# docker where it is installed, otherwise podman (the Fedora build box runs rootless podman).
# QFORGE_CONTAINER=docker|podman overrides; the Makefile derives and exports the same choice.
#
# Call the runtime as `ctr <subcommand> ...`. Under podman two subcommands are adjusted:
#   run     gets --security-opt label=disable. On an SELinux host (Fedora, enforcing) a container
#           cannot read an unlabelled bind mount; relabelling it instead (:z) would rewrite the
#           SELinux labels of the user's checkout.
#   import  takes --os/--arch, not docker's --platform os/arch.
QFORGE_CONTAINER="${QFORGE_CONTAINER:-$(command -v docker >/dev/null 2>&1 && echo docker || echo podman)}"

ctr() {
  if [ "$QFORGE_CONTAINER" != podman ]; then
    "$QFORGE_CONTAINER" "$@"
    return
  fi
  case "${1:-}" in
    run)
      shift
      podman run --security-opt label=disable "$@"
      ;;
    import)
      shift
      local a args=()
      while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$a" = --platform ] && [ $# -gt 0 ]; then
          args+=(--os "${1%%/*}" --arch "${1#*/}"); shift
        else
          args+=("$a")
        fi
      done
      podman import "${args[@]}"
      ;;
    *)
      podman "$@"
      ;;
  esac
}

# What `ctr run` expands to, for printing a command the user can paste.
ctr_run_cmdline() {
  if [ "$QFORGE_CONTAINER" = podman ]; then
    printf 'podman run --security-opt label=disable'
  else
    printf '%s run' "$QFORGE_CONTAINER"
  fi
}

# Fail early, naming the runtime, when it is not installed.
ctr_require() {
  command -v "$QFORGE_CONTAINER" >/dev/null 2>&1 \
    || { echo "$QFORGE_CONTAINER required${1:+ for $1} (QFORGE_CONTAINER=docker|podman)" >&2; exit 1; }
}
