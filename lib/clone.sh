# shellcheck shell=bash
# Clone e sincronização de repositórios git via HTTPS.

CRED_USERNAME=""
CRED_TOKEN=""
CLONE_ASKPASS=""

# clone::init cria o helper de askpass usado para entregar o token ao git sem
# colocá-lo na linha de comando (visível em ps) nem na URL (que vaza em logs do
# servidor remoto e no próprio .git/config).
clone::init() {
  CLONE_ASKPASS="$INITC_WORK_DIR/askpass.sh"
  cat >"$CLONE_ASKPASS" <<'ASKPASS'
#!/bin/sh
# O git chama este helper com o prompt como primeiro argumento.
# INITC_ASKPASS_FILE aponta para um arquivo 0600 com usuário na linha 1 e
# token na linha 2.
case "$1" in
  Username*) sed -n '1p' "$INITC_ASKPASS_FILE" ;;
  *) sed -n '2p' "$INITC_ASKPASS_FILE" ;;
esac
ASKPASS
  chmod 0700 "$CLONE_ASKPASS"
}

# clone::_problem registra uma falha como erro, ou como aviso em dry-run, onde
# a ausência de uma credencial não deve derrubar a conferência do plano.
clone::_problem() {
  if [[ "$INITC_DRY_RUN" == "true" ]]; then
    log::warn "$@"
  else
    log::error "$@"
  fi
}

# clone::resolve_credentials <nome do bloco auth>
#
# Preenche CRED_USERNAME e CRED_TOKEN, ou os deixa vazios para clone anônimo.
clone::resolve_credentials() {
  local name="$1"
  CRED_USERNAME=""
  CRED_TOKEN=""

  [[ -z "$name" || "$name" == "none" ]] && return 0

  local auth_username="" auth_token_env="" auth_token_file=""
  eval "$(config::auth_vars "$name")"
  CRED_USERNAME="$auth_username"

  if [[ -n "$auth_token_env" ]]; then
    CRED_TOKEN="${!auth_token_env-}"
    if [[ -z "$CRED_TOKEN" ]]; then
      clone::_problem "variável de ambiente do token está vazia ou não definida" \
        auth="$name" env="$auth_token_env"
      return 1
    fi
  elif [[ -n "$auth_token_file" ]]; then
    if [[ ! -r "$auth_token_file" ]]; then
      clone::_problem "arquivo de token não legível" auth="$name" file="$auth_token_file"
      return 1
    fi
    # Secrets montados costumam terminar em newline; read descarta a quebra.
    IFS= read -r CRED_TOKEN <"$auth_token_file" || true
    CRED_TOKEN="${CRED_TOKEN%"${CRED_TOKEN##*[![:space:]]}"}"
    if [[ -z "$CRED_TOKEN" ]]; then
      clone::_problem "arquivo de token está vazio" auth="$name" file="$auth_token_file"
      return 1
    fi
  fi
  return 0
}

# clone::_redact remove o token de uma mensagem antes de registrá-la.
clone::_redact() {
  local text="$1"
  if [[ -n "$CRED_TOKEN" ]]; then
    text="${text//"$CRED_TOKEN"/<redacted>}"
  fi
  printf '%s' "$text"
}

# clone::_write_askpass_file grava usuário e token num arquivo só legível pelo
# processo atual e ecoa o caminho.
clone::_write_askpass_file() {
  local file="$INITC_WORK_DIR/askpass.$BASHPID.secret"
  local previous_umask
  previous_umask="$(umask)"
  umask 077
  printf '%s\n%s\n' "$CRED_USERNAME" "$CRED_TOKEN" >"$file"
  umask "$previous_umask"
  printf '%s' "$file"
}

# clone::_git <descrição> <args do git...>
#
# Roda git com as credenciais correntes, captura a saída combinada e a redige
# antes de logar. Devolve o status do git.
clone::_git() {
  local desc="$1"
  shift

  local -a env_args=(GIT_TERMINAL_PROMPT=0)
  local secret_file=""
  if [[ -n "$CRED_TOKEN" ]]; then
    secret_file="$(clone::_write_askpass_file)"
    env_args+=(GIT_ASKPASS="$CLONE_ASKPASS" INITC_ASKPASS_FILE="$secret_file")
  fi

  log::debug "$desc" cmd="git $*"

  local output status=0
  output="$(env "${env_args[@]}" git "$@" 2>&1)" || status=$?

  [[ -n "$secret_file" ]] && rm -f "$secret_file"

  if ((status != 0)); then
    log::error "$desc falhou" status="$status" erro="$(clone::_redact "$output")"
  elif [[ -n "$output" ]]; then
    log::debug "$desc" saida="$(clone::_redact "$output")"
  fi
  return "$status"
}

# clone::_resolve_ref <url> <ref>
#
# Ecoa "<tipo> <nome>" com tipo em head, branch, tag ou sha. Uma consulta
# ls-remote resolve a ambiguidade entre branch, tag e SHA de forma determinística,
# em vez de descobrir isso por tentativa e erro no meio do clone.
clone::_resolve_ref() {
  local url="$1" ref="$2"

  if [[ -z "$ref" ]]; then
    printf 'head '
    return 0
  fi

  local -a env_args=(GIT_TERMINAL_PROMPT=0)
  local secret_file=""
  if [[ -n "$CRED_TOKEN" ]]; then
    secret_file="$(clone::_write_askpass_file)"
    env_args+=(GIT_ASKPASS="$CLONE_ASKPASS" INITC_ASKPASS_FILE="$secret_file")
  fi

  local listing status=0
  listing="$(env "${env_args[@]}" git ls-remote "$url" \
    "refs/heads/$ref" "refs/tags/$ref" 2>&1)" || status=$?

  [[ -n "$secret_file" ]] && rm -f "$secret_file"

  if ((status != 0)); then
    log::error "ls-remote falhou" url="$url" erro="$(clone::_redact "$listing")"
    return 1
  fi

  if grep -q "refs/heads/$ref\$" <<<"$listing"; then
    printf 'branch %s' "$ref"
    return 0
  fi
  if grep -q "refs/tags/$ref\$" <<<"$listing"; then
    printf 'tag %s' "$ref"
    return 0
  fi
  # Nenhum branch ou tag com esse nome: só resta ser um commit.
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    printf 'sha %s' "$ref"
    return 0
  fi

  log::error "ref não encontrado no remoto como branch, tag ou SHA" url="$url" ref="$ref"
  return 1
}

# clone::_is_repo <path>
clone::_is_repo() {
  [[ -d "$1/.git" ]] || git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# clone::_same_remote <path> <url>
clone::_same_remote() {
  local current
  current="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  # Trata https://h/r e https://h/r.git como o mesmo remoto.
  [[ "${current%.git}" == "${2%.git}" ]]
}

# clone::_fresh <url> <path> <tipo> <nome> <depth> <submodules>
clone::_fresh() {
  local url="$1" path="$2" ref_type="$3" ref_name="$4" depth="$5" submodules="$6"

  local parent tmp
  parent="$(dirname "$path")"
  mkdir -p "$parent" || return 1
  tmp="$path.tmp.$BASHPID"
  rm -rf "$tmp"

  local -a args=(clone --quiet)
  case "$ref_type" in
    branch | tag)
      args+=(--branch "$ref_name" --single-branch)
      ((depth > 0)) && args+=(--depth "$depth")
      ;;
    sha)
      # Um clone raso não conteria um commit arbitrário.
      if ((depth > 0)); then
        log::warn "depth ignorado: ref é um SHA e exige histórico completo" \
          path="$path" ref="$ref_name" depth="$depth"
      fi
      ;;
    head)
      ((depth > 0)) && args+=(--depth "$depth")
      ;;
  esac
  [[ "$submodules" == "true" ]] && args+=(--recurse-submodules)
  args+=("$url" "$tmp")

  if ! clone::_git "clone $url" "${args[@]}"; then
    rm -rf "$tmp"
    return 1
  fi

  if [[ "$ref_type" == "sha" ]]; then
    if ! clone::_git "checkout $ref_name" -C "$tmp" checkout --quiet --detach "$ref_name"; then
      rm -rf "$tmp"
      return 1
    fi
    if [[ "$submodules" == "true" ]]; then
      clone::_git "submodule update" -C "$tmp" submodule update --init --recursive --quiet || {
        rm -rf "$tmp"
        return 1
      }
    fi
  fi

  # O destino pode existir como diretório vazio (um subPath montado, por
  # exemplo); nesse caso mv moveria o clone para dentro dele.
  if [[ -d "$path" ]] && ! rmdir "$path" 2>/dev/null; then
    log::error "destino existe e não está vazio" path="$path"
    rm -rf "$tmp"
    return 1
  fi

  if ! mv "$tmp" "$path"; then
    log::error "falha ao mover o clone para o destino" path="$path"
    rm -rf "$tmp"
    return 1
  fi
  return 0
}

# clone::_update <url> <path> <tipo> <nome> <depth> <submodules>
clone::_update() {
  local url="$1" path="$2" ref_type="$3" ref_name="$4" depth="$5" submodules="$6"

  local -a fetch_args=(-C "$path" fetch --quiet --prune --tags --force origin)
  ((depth > 0)) && fetch_args+=(--depth "$depth")
  clone::_git "fetch $url" "${fetch_args[@]}" || return 1

  local target
  case "$ref_type" in
    branch) target="refs/remotes/origin/$ref_name" ;;
    tag) target="refs/tags/$ref_name" ;;
    sha) target="$ref_name" ;;
    head) target="refs/remotes/origin/HEAD" ;;
  esac

  local hash
  if ! hash="$(git -C "$path" rev-parse --verify --quiet "$target^{commit}")"; then
    log::error "não foi possível resolver o ref após o fetch" path="$path" target="$target"
    return 1
  fi

  if [[ "$ref_type" == "branch" ]]; then
    # Mantém HEAD no branch, em vez de detached, para que o volume se pareça
    # com um checkout normal.
    clone::_git "checkout $ref_name" -C "$path" checkout --quiet --force -B "$ref_name" "$hash" || return 1
  else
    clone::_git "checkout $target" -C "$path" checkout --quiet --force --detach "$hash" || return 1
  fi

  clone::_git "reset --hard" -C "$path" reset --quiet --hard "$hash" || return 1
  # reset não remove arquivos não rastreados deixados por uma execução anterior.
  clone::_git "clean" -C "$path" clean --quiet -ffd || return 1

  if [[ "$submodules" == "true" ]]; then
    clone::_git "submodule update" -C "$path" submodule update --init --recursive --quiet || return 1
  fi
  printf '%s' "$hash"
  return 0
}

# clone::sync <url> <path> <ref> <depth> <submodules> <auth> <force>
#
# Idempotente: init containers reiniciam junto com o Pod, então estado parcial
# de uma execução anterior é esperado e não pode virar erro.
clone::sync() {
  local url="$1" path="$2" ref="$3" depth="$4" submodules="$5" auth="$6" force="$7"

  if [[ "$INITC_DRY_RUN" == "true" ]]; then
    # Sem contato com o remoto em dry-run: a ideia é conferir o plano, não
    # exigir rede e credenciais. A resolução ainda é tentada, para avisar sobre
    # um token ausente, mas a falha não derruba a execução.
    clone::resolve_credentials "$auth" || true
    log::info "[dry-run] clone" url="$url" path="$path" ref="${ref:-<HEAD>}" \
      depth="$depth" submodules="$submodules" auth="${auth:-none}"
    return 0
  fi

  clone::resolve_credentials "$auth" || return 1

  local resolved ref_type ref_name
  resolved="$(clone::_resolve_ref "$url" "$ref")" || return 1
  read -r ref_type ref_name <<<"$resolved"

  # Destino ocupado por algo que não é um repositório git.
  if [[ -e "$path" || -L "$path" ]] && ! clone::_is_repo "$path"; then
    if [[ -d "$path" ]] && [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
      : # diretório vazio: clone normal
    elif [[ "$force" == "true" ]]; then
      log::warn "destino não é um repositório git, removendo por force: true" path="$path"
      rm -rf "$path" || return 1
    else
      log::error "destino existe e não é um repositório git; use force: true para sobrescrever" path="$path"
      return 1
    fi
  fi

  if clone::_is_repo "$path"; then
    if ! clone::_same_remote "$path" "$url"; then
      if [[ "$force" != "true" ]]; then
        local current
        current="$(git -C "$path" remote get-url origin 2>/dev/null || printf '<nenhum>')"
        log::error "repositório existente aponta para outro remoto; use force: true para substituir" \
          path="$path" esperado="$url" atual="$current"
        return 1
      fi
      log::warn "remoto divergente, substituindo o clone por force: true" path="$path"
      rm -rf "$path"
      clone::_fresh "$url" "$path" "$ref_type" "$ref_name" "$depth" "$submodules" || return 1
      log::info "repositório clonado" url="$url" path="$path" ref="$ref_type:${ref_name:-HEAD}"
      return 0
    fi

    local before after
    before="$(git -C "$path" rev-parse HEAD 2>/dev/null || printf '')"
    after="$(clone::_update "$url" "$path" "$ref_type" "$ref_name" "$depth" "$submodules")" || return 1
    if [[ "$before" == "$after" ]]; then
      log::info "repositório já atualizado" path="$path" ref="$ref_type:${ref_name:-HEAD}" commit="${after:0:12}"
    else
      log::info "repositório atualizado" path="$path" ref="$ref_type:${ref_name:-HEAD}" commit="${after:0:12}"
    fi
    return 0
  fi

  clone::_fresh "$url" "$path" "$ref_type" "$ref_name" "$depth" "$submodules" || return 1
  local commit
  commit="$(git -C "$path" rev-parse HEAD 2>/dev/null || printf '')"
  log::info "repositório clonado" url="$url" path="$path" \
    ref="$ref_type:${ref_name:-HEAD}" commit="${commit:0:12}"
  return 0
}
