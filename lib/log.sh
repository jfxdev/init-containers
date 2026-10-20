# shellcheck shell=bash
# Logging estruturado. Formato controlado por INITC_LOG_FORMAT (text|json) e
# nível por INITC_LOG_LEVEL (debug|info|warn|error).

: "${INITC_LOG_FORMAT:=text}"
: "${INITC_LOG_LEVEL:=info}"

log::_level_num() {
  case "$1" in
    debug) printf '10' ;;
    info) printf '20' ;;
    warn) printf '30' ;;
    error) printf '40' ;;
    *) printf '20' ;;
  esac
}

# log::_quote cita um valor no estilo logfmt: entre quotes apenas quando
# necessário. printf %q escaparia cada byte de caractere acentuado, deixando as
# mensagens em português ilegíveis.
log::_quote() {
  local value="$1"
  if [[ -z "$value" || "$value" == *[[:space:]\"\\]* ]]; then
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

# log::_emit <nível> <mensagem> [chave=valor ...]
log::_emit() {
  local level="$1" msg="$2"
  shift 2

  local threshold current
  threshold="$(log::_level_num "$INITC_LOG_LEVEL")"
  current="$(log::_level_num "$level")"
  ((current < threshold)) && return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$INITC_LOG_FORMAT" == "json" ]]; then
    local -a jq_args=(-n -c --arg ts "$ts" --arg level "$level" --arg msg "$msg")
    # shellcheck disable=SC2016 # $ts etc. são variáveis do jq, não do shell
    local filter='{ts: $ts, level: $level, msg: $msg}'
    local pair key value idx=0
    for pair in "$@"; do
      key="${pair%%=*}"
      value="${pair#*=}"
      jq_args+=(--arg "k${idx}" "$key" --arg "v${idx}" "$value")
      filter+=" + {(\$k${idx}): \$v${idx}}"
      idx=$((idx + 1))
    done
    jq "${jq_args[@]}" "$filter"
  else
    local line
    line="$(printf '%s %-5s %s' "$ts" "${level^^}" "$msg")"
    local pair
    for pair in "$@"; do
      line+=" ${pair%%=*}=$(log::_quote "${pair#*=}")"
    done
    printf '%s\n' "$line"
  fi
}

log::debug() { log::_emit debug "$@"; }
log::info() { log::_emit info "$@"; }
log::warn() { log::_emit warn "$@" >&2; }
log::error() { log::_emit error "$@" >&2; }

# log::fatal <código> <mensagem> [chave=valor ...]
log::fatal() {
  local code="$1"
  shift
  log::error "$@"
  exit "$code"
}
