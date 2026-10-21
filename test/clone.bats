#!/usr/bin/env bats
# Clone e re-sincronização. Tudo roda contra repositórios bare locais via
# file://, sem rede.

load helper/common

setup() {
  REPO="$(helper::make_repo app)"
  WS="$BATS_TEST_TMPDIR/ws"
}

# cfg <json dos repositórios> monta uma configuração completa.
cfg() {
  printf '{"apiVersion":"init-containers/v1","repositories":[%s]}' "$1"
}

@test "clona o HEAD do remoto" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "dois" ]
  helper::assert_contains "$output" "repositório clonado"
}

@test "clona numa tag" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"v1.0.0\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "um" ]
  helper::assert_contains "$output" "tag:v1.0.0"
}

@test "clona num SHA" {
  local sha
  sha="$(helper::sha app HEAD~1)"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"$sha\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "um" ]
  [ "$(git -C "$WS/app" rev-parse HEAD)" = "$sha" ]
}

@test "depth é ignorado com aviso quando o ref é um SHA" {
  local sha
  sha="$(helper::sha app HEAD~1)"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"$sha\",\"depth\":1}")"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "depth ignorado"
}

@test "clone raso respeita o depth" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"depth\":1}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-list --count HEAD)" = "1" ]
}

@test "ref inexistente falha com exit 2" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"nao-existe\"}")"
  [ "$status" -eq 2 ]
  helper::assert_contains "$output" "ref não encontrado"
  [ ! -d "$WS/app" ]
}

@test "repositório opcional que falha não derruba o init" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"nada\",\"optional\":true}")"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "repositório opcional falhou"
}

@test "clone falho não deixa diretório temporário para trás" {
  helper::run_initc "$(cfg "{\"url\":\"file://$BATS_TEST_TMPDIR/inexistente.git\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 2 ]
  run bash -c "ls -d '$WS'/app.tmp.* 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "segunda execução é idempotente" {
  local config
  config="$(helper::write_config "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")")"
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "repositório já atualizado"
}

@test "traz commits novos do upstream numa nova execução" {
  local config
  config="$(helper::write_config "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")")"
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]

  helper::push_commit app tres
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "tres" ]
  helper::assert_contains "$output" "repositório atualizado"
}

@test "recupera de worktree suja e de arquivos não rastreados" {
  local config
  config="$(helper::write_config "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")")"
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]

  printf 'editado à mão\n' >"$WS/app/file.txt"
  printf 'lixo\n' >"$WS/app/nao-rastreado.txt"

  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "dois" ]
  [ ! -e "$WS/app/nao-rastreado.txt" ]
  [ -z "$(git -C "$WS/app" status --porcelain)" ]
}

@test "mantém HEAD no branch, não em detached" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "destino ocupado por outros dados falha e preserva os dados" {
  mkdir -p "$WS/app"
  printf 'importante\n' >"$WS/app/dados.txt"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 2 ]
  helper::assert_contains "$output" "não é um repositório git"
  [ -f "$WS/app/dados.txt" ]
}

@test "force sobrescreve destino ocupado" {
  mkdir -p "$WS/app"
  printf 'descartável\n' >"$WS/app/dados.txt"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"force\":true}")"
  [ "$status" -eq 0 ]
  [ -f "$WS/app/file.txt" ]
  [ ! -e "$WS/app/dados.txt" ]
}

@test "diretório vazio pré-existente é usado como destino" {
  mkdir -p "$WS/app"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  [ -f "$WS/app/file.txt" ]
}

@test "remoto divergente falha sem force" {
  local other
  other="$(helper::make_repo outro)"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  helper::run_initc "$(cfg "{\"url\":\"$other\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 2 ]
  helper::assert_contains "$output" "outro remoto"
}

@test "force substitui clone de remoto divergente" {
  local other
  other="$(helper::make_repo outro)"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  helper::run_initc "$(cfg "{\"url\":\"$other\",\"path\":\"$WS/app\",\"force\":true}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" remote get-url origin)" = "$other" ]
}

@test "URL com e sem sufixo .git são o mesmo remoto" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  helper::run_initc "$(cfg "{\"url\":\"${REPO%.git}\",\"path\":\"$WS/app\"}")"
  [ "$status" -eq 0 ]
  helper::refute_contains "$output" "outro remoto"
}

@test "vários repositórios são clonados em paralelo" {
  local outro
  outro="$(helper::make_repo outro)"
  helper::run_initc "{\"apiVersion\":\"init-containers/v1\",
    \"defaults\":{\"concurrency\":2},
    \"repositories\":[
      {\"url\":\"$REPO\",\"path\":\"$WS/a\"},
      {\"url\":\"$outro\",\"path\":\"$WS/b\"}]}"
  [ "$status" -eq 0 ]
  [ -f "$WS/a/file.txt" ]
  [ -f "$WS/b/file.txt" ]
}

@test "falha de um repositório não impede os outros nem as permissões" {
  mkdir -p "$WS/perm"
  helper::run_initc "{\"apiVersion\":\"init-containers/v1\",
    \"repositories\":[
      {\"url\":\"$REPO\",\"path\":\"$WS/ok\"},
      {\"url\":\"$REPO\",\"path\":\"$WS/falha\",\"ref\":\"nada\"}],
    \"permissions\":[{\"path\":\"$WS/perm\",\"mode\":\"0700\"}]}"
  [ "$status" -eq 2 ]
  [ -f "$WS/ok/file.txt" ]
  [ "$(helper::mode "$WS/perm")" = "700" ]
}

@test "owner e modo do repositório são aplicados ao destino" {
  if ((EUID != 0)); then
    skip "chown exige root"
  fi
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"owner\":4242,\"group\":4243,\"mode\":\"0750\"}")"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u:%g' "$WS/app")" = "4242:4243" ]
  [ "$(stat -c '%u:%g' "$WS/app/sub/nested.txt")" = "4242:4243" ]
  [ "$(helper::mode "$WS/app")" = "750" ]
}

@test "modo do repositório não altera o bit de execução dos arquivos" {
  # Aplicar o modo a cada arquivo faria o git ver a árvore inteira como
  # modificada.
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"mode\":\"0755\"}")"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$WS/app" status --porcelain)" ]
  [ ! -x "$WS/app/file.txt" ]
}

@test "submódulos são inicializados quando pedido" {
  local lib_repo
  lib_repo="$(helper::make_repo lib)"
  local src
  src="$(helper::repo_src app)"
  # O git bloqueia o protocolo file em submódulos por padrão (CVE-2022-39253);
  # a liberação fica no teste, não no código de produção.
  git -C "$src" -c protocol.file.allow=always submodule add -q "$lib_repo" vendor/lib
  git -C "$src" commit -qm "adiciona submódulo"
  git -C "$src" push -q "$BATS_TEST_TMPDIR/bare-app.git" main

  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"submodules\":true}")"
  [ "$status" -eq 0 ]
  [ -f "$WS/app/vendor/lib/file.txt" ]
}

# --- Regressões apontadas na revisão do PR #1 ---

@test "re-sync funciona depois do chown para owner diferente de root" {
  # O git >= 2.35.2 recusa um repositório de outro dono com "detected dubious
  # ownership". Na primeira execução o clone é feito como root e depois passa
  # para o owner configurado, que é o cenário principal do README.
  if ((EUID != 0)); then
    skip "chown exige root"
  fi
  local config
  config="$(helper::write_config "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"owner\":4242,\"group\":4243}")")"

  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u:%g' "$WS/app")" = "4242:4243" ]

  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "repositório já atualizado"
  helper::refute_contains "$output" "dubious"
  helper::refute_contains "$output" "outro remoto"
}

@test "trocar o ref para outro branch continua funcionando" {
  # Um clone com --branch/--single-branch grava um refspec que cobre só aquele
  # branch; sem refspec explícito no fetch, o novo ref nunca chegaria.
  local src
  src="$(helper::repo_src app)"
  git -C "$src" checkout -q -b develop
  printf 'do develop\n' >"$src/file.txt"
  git -C "$src" commit -qam "develop"
  git -C "$src" push -q "$BATS_TEST_TMPDIR/bare-app.git" develop
  git -C "$src" checkout -q main

  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "dois" ]

  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"develop\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "do develop" ]
  [ "$(git -C "$WS/app" rev-parse --abbrev-ref HEAD)" = "develop" ]
}

@test "trocar de branch para tag continua funcionando" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"depth\":1}")"
  [ "$status" -eq 0 ]
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"v1.0.0\"}")"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/app/file.txt")" = "um" ]
}

@test "trocar de clone raso para um SHA recupera o histórico" {
  local sha
  sha="$(helper::sha app HEAD~1)"
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"depth\":1}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-parse --is-shallow-repository)" = "true" ]

  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"$sha\"}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-parse HEAD)" = "$sha" ]
}

@test "depth voltando a 0 recupera o histórico completo" {
  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\",\"depth\":1}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-list --count HEAD)" = "1" ]

  helper::run_initc "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS/app" rev-list --count HEAD)" = "2" ]
  [ "$(git -C "$WS/app" rev-parse --is-shallow-repository)" = "false" ]
}

@test "com --log-level debug o commit logado é um hash, não log capturado" {
  local config
  config="$(helper::write_config "$(cfg "{\"url\":\"$REPO\",\"path\":\"$WS/app\",\"ref\":\"main\"}")")"
  run "$INITC_BIN" --config "$config"
  [ "$status" -eq 0 ]

  run "$INITC_BIN" --config "$config" --log-level debug
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "repositório já atualizado"
  # O commit precisa ser os 12 primeiros dígitos hex do HEAD.
  local head
  head="$(git -C "$WS/app" rev-parse HEAD)"
  helper::assert_contains "$output" "commit=${head:0:12}"
}
