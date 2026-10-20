# shellcheck shell=bash
# Carga, validação e leitura do arquivo de configuração JSON.
#
# O arquivo cru é validado por lib/jq/validate.jq e depois normalizado por
# lib/jq/normalize.jq para um arquivo temporário onde todo campo existe com tipo
# previsível. As funções de leitura operam sobre esse arquivo normalizado, então
# nenhuma lógica de default é repetida em shell.

CONFIG_NORMALIZED=""

config::_jq_program() {
  cat "$INITC_LIB_DIR/jq/defs.jq" "$INITC_LIB_DIR/jq/$1.jq"
}

# config::load <caminho>
config::load() {
  local path="$1"

  [[ -e "$path" ]] || log::fatal 1 "arquivo de configuração não encontrado" path="$path"
  [[ -r "$path" ]] || log::fatal 1 "arquivo de configuração não legível" path="$path"

  if ! jq -e 'type' "$path" >/dev/null 2>&1; then
    local parse_error
    parse_error="$(jq 'type' "$path" 2>&1 >/dev/null || true)"
    log::fatal 1 "JSON inválido: ${parse_error:-conteúdo vazio ou malformado}" path="$path"
  fi

  local problems
  problems="$(jq -r -f <(config::_jq_program validate) "$path")"
  if [[ -n "$problems" ]]; then
    local problem
    while IFS= read -r problem; do
      log::error "configuração inválida" problem="$problem"
    done <<<"$problems"
    log::fatal 1 "configuração inválida" path="$path" \
      problemas="$(printf '%s\n' "$problems" | wc -l | tr -d ' ')"
  fi

  CONFIG_NORMALIZED="$INITC_WORK_DIR/config.normalized.json"
  jq -f <(config::_jq_program normalize) "$path" >"$CONFIG_NORMALIZED" ||
    log::fatal 1 "falha ao normalizar a configuração" path="$path"

  log::debug "configuração carregada" path="$path" \
    repositories="$(config::count repositories)" \
    permissions="$(config::count permissions)"
}

# config::count <repositories|permissions>
config::count() {
  jq -r --arg key "$1" '.[$key] | length' "$CONFIG_NORMALIZED"
}

config::concurrency() {
  jq -r '.concurrency' "$CONFIG_NORMALIZED"
}

# config::dump imprime a configuração efetiva, já com defaults aplicados.
config::dump() {
  jq '.' "$CONFIG_NORMALIZED"
}

# config::repo_vars <índice>
#
# Emite atribuições shell para eval. jq @sh faz o quoting, então valores com
# espaços ou metacaracteres são seguros.
config::repo_vars() {
  jq -r --argjson i "$1" '
    .repositories[$i]
    | "repo_url=\(.url | @sh)",
      "repo_path=\(.path | @sh)",
      "repo_ref=\(.ref | @sh)",
      "repo_depth=\(.depth | tostring | @sh)",
      "repo_submodules=\(.submodules | tostring | @sh)",
      "repo_auth=\(.auth | @sh)",
      "repo_optional=\(.optional | tostring | @sh)",
      "repo_force=\(.force | tostring | @sh)",
      "repo_owner=\(.owner | @sh)",
      "repo_group=\(.group | @sh)",
      "repo_mode=\(.mode | @sh)"
  ' "$CONFIG_NORMALIZED"
}

# config::perm_vars <índice>
config::perm_vars() {
  jq -r --argjson i "$1" '
    .permissions[$i]
    | "perm_path=\(.path | @sh)",
      "perm_owner=\(.owner | @sh)",
      "perm_group=\(.group | @sh)",
      "perm_mode=\(.mode | @sh)",
      "perm_dir_mode=\(.dirMode | @sh)",
      "perm_file_mode=\(.fileMode | @sh)",
      "perm_recursive=\(.recursive | tostring | @sh)",
      "perm_optional=\(.optional | tostring | @sh)"
  ' "$CONFIG_NORMALIZED"
}

# config::auth_vars <nome>
config::auth_vars() {
  jq -r --arg name "$1" '
    .auth[$name]
    | "auth_username=\(.username | @sh)",
      "auth_token_env=\(.tokenEnv | @sh)",
      "auth_token_file=\(.tokenFile | @sh)"
  ' "$CONFIG_NORMALIZED"
}
