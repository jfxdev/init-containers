#!/usr/bin/env bats
# Interface de linha de comando, logging e tratamento de credenciais.

load helper/common

@test "--help documenta as opções e sai com 0" {
  run "$INITC_BIN" --help
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "--config"
  helper::assert_contains "$output" "--dry-run"
}

@test "--version imprime a versão" {
  run "$INITC_BIN" --version
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "init-containers"
}

@test "opção desconhecida falha com exit 1" {
  run "$INITC_BIN" --nao-existe
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "opção desconhecida"
}

@test "--config sem valor falha" {
  run "$INITC_BIN" --config
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "faltou o valor"
}

@test "--config=CAMINHO também é aceito" {
  local config
  config="$(helper::write_config '{"apiVersion":"init-containers/v1"}')"
  run "$INITC_BIN" "--config=$config"
  [ "$status" -eq 0 ]
}

@test "INITC_CONFIG define o caminho padrão" {
  local config
  config="$(helper::write_config '{"apiVersion":"init-containers/v1"}')"
  INITC_CONFIG="$config" run "$INITC_BIN"
  [ "$status" -eq 0 ]
}

@test "--log-format inválido falha" {
  run "$INITC_BIN" --log-format xml
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "--log-format inválido"
}

@test "--log-level inválido falha" {
  run "$INITC_BIN" --log-level verboso
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "--log-level inválido"
}

@test "log em json produz uma linha JSON válida por evento" {
  local repo="$BATS_TEST_TMPDIR/x"
  mkdir -p "$repo"
  helper::run_initc "{\"apiVersion\":\"init-containers/v1\",
    \"permissions\":[{\"path\":\"$repo\",\"mode\":\"0700\"}]}" --log-format json
  [ "$status" -eq 0 ]
  # Toda linha precisa parsear, e os campos estruturais precisam estar lá.
  run bash -c "printf '%s\n' \"\$1\" | jq -e -s 'all(has(\"ts\") and has(\"level\") and has(\"msg\"))'" _ "$output"
  [ "$status" -eq 0 ]
}

@test "mensagens acentuadas não são destruídas no log em texto" {
  helper::run_initc '{"apiVersion":"init-containers/v1","permissions":[{"path":"/nao/existe","mode":"0700"}]}'
  [ "$status" -eq 2 ]
  helper::assert_contains "$output" "caminho não existe"
}

@test "configuração vazia avisa e sai com 0" {
  helper::run_initc '{"apiVersion":"init-containers/v1"}'
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "nada a fazer"
}

@test "dry-run imprime a configuração efetiva e não altera nada" {
  local repo tree
  repo="$(helper::make_repo app)"
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree"
  chmod 0755 "$tree"

  helper::run_initc "{\"apiVersion\":\"init-containers/v1\",
    \"defaults\":{\"mode\":\"0700\"},
    \"repositories\":[{\"url\":\"$repo\",\"path\":\"$BATS_TEST_TMPDIR/ws/app\"}],
    \"permissions\":[{\"path\":\"$tree\"}]}" --dry-run
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "[dry-run]"
  # O default precisa aparecer já resolvido na configuração efetiva.
  helper::assert_contains "$output" '"mode": "0700"'
  [ ! -d "$BATS_TEST_TMPDIR/ws/app" ]
  [ "$(helper::mode "$tree")" = "755" ]
}

@test "token vindo de variável de ambiente é resolvido" {
  helper::load_libs
  config::load "$(helper::write_config \
    '{"apiVersion":"init-containers/v1","auth":{"gh":{"tokenEnv":"MEU_TOKEN"}}}')"
  export MEU_TOKEN=segredo-123
  clone::resolve_credentials gh
  [ "$CRED_TOKEN" = "segredo-123" ]
  [ "$CRED_USERNAME" = "x-access-token" ]
}

@test "variável de ambiente do token ausente falha com mensagem clara" {
  helper::load_libs
  config::load "$(helper::write_config \
    '{"apiVersion":"init-containers/v1","auth":{"gh":{"tokenEnv":"TOKEN_INEXISTENTE"}}}')"
  run clone::resolve_credentials gh
  [ "$status" -ne 0 ]
  helper::assert_contains "$output" "vazia ou não definida"
}

@test "token vindo de arquivo é lido sem a quebra de linha final" {
  helper::load_libs
  local token_file="$BATS_TEST_TMPDIR/token"
  printf 'segredo-de-arquivo\n' >"$token_file"
  config::load "$(helper::write_config \
    "{\"apiVersion\":\"init-containers/v1\",\"auth\":{\"gh\":{\"tokenFile\":\"$token_file\",\"username\":\"oauth2\"}}}")"
  clone::resolve_credentials gh
  [ "$CRED_TOKEN" = "segredo-de-arquivo" ]
  [ "$CRED_USERNAME" = "oauth2" ]
}

@test "arquivo de token vazio falha" {
  helper::load_libs
  local token_file="$BATS_TEST_TMPDIR/token-vazio"
  : >"$token_file"
  config::load "$(helper::write_config \
    "{\"apiVersion\":\"init-containers/v1\",\"auth\":{\"gh\":{\"tokenFile\":\"$token_file\"}}}")"
  run clone::resolve_credentials gh
  [ "$status" -ne 0 ]
  helper::assert_contains "$output" "está vazio"
}

@test "auth none deixa as credenciais vazias" {
  helper::load_libs
  config::load "$(helper::write_config '{"apiVersion":"init-containers/v1"}')"
  clone::resolve_credentials none
  [ -z "$CRED_TOKEN" ]
}

@test "o token é redigido nas mensagens" {
  helper::load_libs
  CRED_TOKEN="ghp_segredo"
  run clone::_redact "falhou ao autenticar com ghp_segredo no remoto"
  [ "$status" -eq 0 ]
  helper::refute_contains "$output" "ghp_segredo"
  helper::assert_contains "$output" "<redacted>"
}

@test "o token não aparece na saída quando o clone falha" {
  export GHP_TESTE=ghp_token_muito_secreto
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "auth":{"gh":{"tokenEnv":"GHP_TESTE"}},
    "repositories":[{"url":"https://127.0.0.1:1/r.git","path":"/tmp/initc-teste-auth","auth":"gh"}]}'
  [ "$status" -eq 2 ]
  helper::refute_contains "$output" "ghp_token_muito_secreto"
}

@test "o diretório de trabalho com o token é removido na saída" {
  export GHP_TESTE=ghp_token_muito_secreto
  # TMPDIR explícito para poder afirmar sobre o diretório que o script cria.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "auth":{"gh":{"tokenEnv":"GHP_TESTE"}},
    "repositories":[{"url":"https://127.0.0.1:1/r.git","path":"/tmp/initc-teste-auth","auth":"gh"}]}'
  [ "$status" -eq 2 ]
  # Nada do diretório de trabalho sobrevive, nem o askpass nem o segredo.
  run find "$TMPDIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dry-run avisa, sem falhar, quando o caminho ainda não existe" {
  helper::run_initc "{\"apiVersion\":\"init-containers/v1\",
    \"permissions\":[{\"path\":\"$BATS_TEST_TMPDIR/ainda-nao-existe\",\"mode\":\"0700\"}]}" --dry-run
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "caminho não existe (dry-run)"
}

@test "dry-run avisa, sem falhar, quando o token não está disponível" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "auth":{"gh":{"tokenEnv":"TOKEN_QUE_NAO_EXISTE"}},
    "repositories":[{"url":"https://h/r.git","path":"/ws/r","auth":"gh"}]}' --dry-run
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "WARN"
  helper::assert_contains "$output" "vazia ou não definida"
}

@test "os exemplos versionados passam no dry-run" {
  run "$INITC_BIN" --config "$INITC_ROOT/examples/init-config.json" --dry-run
  [ "$status" -eq 0 ]
  run "$INITC_BIN" --config "$INITC_ROOT/examples/init-config.minimal.json" --dry-run
  [ "$status" -eq 0 ]
}

# --- Regressões apontadas na revisão do PR #1 ---

# O helper de askpass é herdado por todo subprocesso do git, incluindo clones de
# submódulos, cujas URLs vêm do .gitmodules do repositório clonado. Ele só pode
# responder para o host do repositório configurado.
@test "askpass responde ao host configurado" {
  helper::load_libs
  clone::init
  CRED_USERNAME=x-access-token
  CRED_TOKEN=ghp_segredo
  CLONE_ORIGIN=https://github.com
  local secret
  secret="$(clone::_write_askpass_file)"

  run env INITC_ASKPASS_FILE="$secret" INITC_ASKPASS_ORIGIN="$CLONE_ORIGIN" \
    "$CLONE_ASKPASS" "Username for 'https://github.com': "
  [ "$status" -eq 0 ]
  [ "$output" = "x-access-token" ]
}

@test "askpass responde à senha mesmo com userinfo no prompt" {
  # O git inclui o usuário no prompt de senha: comparar a string inteira da
  # origem falharia justamente no prompt que entrega o token.
  helper::load_libs
  clone::init
  CRED_USERNAME=x-access-token
  CRED_TOKEN=ghp_segredo
  CLONE_ORIGIN=https://github.com
  local secret
  secret="$(clone::_write_askpass_file)"

  run env INITC_ASKPASS_FILE="$secret" INITC_ASKPASS_ORIGIN="$CLONE_ORIGIN" \
    "$CLONE_ASKPASS" "Password for 'https://x-access-token@github.com': "
  [ "$status" -eq 0 ]
  [ "$output" = "ghp_segredo" ]
}

@test "askpass não entrega o token para outro host" {
  helper::load_libs
  clone::init
  CRED_USERNAME=x-access-token
  CRED_TOKEN=ghp_segredo
  CLONE_ORIGIN=https://github.com
  local secret
  secret="$(clone::_write_askpass_file)"

  local prompt
  for prompt in \
    "Username for 'https://atacante.example': " \
    "Password for 'https://x-access-token@atacante.example': " \
    "Username for 'http://github.com': " \
    "Username for 'https://github.com.atacante.example': " \
    "Password for 'https://github.com@atacante.example': "; do
    run env INITC_ASKPASS_FILE="$secret" INITC_ASKPASS_ORIGIN="$CLONE_ORIGIN" \
      "$CLONE_ASKPASS" "$prompt"
    [ "$status" -ne 0 ]
    helper::refute_contains "$output" "ghp_segredo"
    helper::refute_contains "$output" "x-access-token"
  done
}

@test "askpass falha fechado em prompt sem URL" {
  helper::load_libs
  clone::init
  CRED_USERNAME=x-access-token
  CRED_TOKEN=ghp_segredo
  CLONE_ORIGIN=https://github.com
  local secret
  secret="$(clone::_write_askpass_file)"

  run env INITC_ASKPASS_FILE="$secret" INITC_ASKPASS_ORIGIN="$CLONE_ORIGIN" \
    "$CLONE_ASKPASS" "Password: "
  [ "$status" -ne 0 ]
  helper::refute_contains "$output" "ghp_segredo"
}

@test "a origem é derivada sem userinfo, path nem credenciais" {
  helper::load_libs
  [ "$(clone::_origin https://github.com/org/repo.git)" = "https://github.com" ]
  [ "$(clone::_origin https://user@github.com/org/repo.git)" = "https://github.com" ]
  [ "$(clone::_origin https://git.example.com:8443/org/repo.git)" = "https://git.example.com:8443" ]
  [ "$(clone::_origin http://h/r)" = "http://h" ]
}
