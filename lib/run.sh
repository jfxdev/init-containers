# shellcheck shell=bash
# Execução de comandos que alteram o filesystem, com suporte a --dry-run.

: "${INITC_DRY_RUN:=false}"

# run::cmd <descrição> <comando> [args...]
run::cmd() {
  local desc="$1"
  shift
  if [[ "$INITC_DRY_RUN" == "true" ]]; then
    log::info "[dry-run] $desc" cmd="$*"
    return 0
  fi
  log::debug "$desc" cmd="$*"
  "$@"
}
