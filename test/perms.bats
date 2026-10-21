#!/usr/bin/env bats
# Permissões: modos, recursão e o cuidado com symlinks.

load helper/common

setup() {
  helper::load_libs
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/sub"
  printf 'a\n' >"$TREE/file.txt"
  printf 'b\n' >"$TREE/sub/nested.txt"
}

@test "resolve_uid aceita uid numérico sem consultar /etc/passwd" {
  run perms::resolve_uid 4242
  [ "$status" -eq 0 ]
  [ "$output" = "4242" ]
}

@test "resolve_uid resolve nome de usuário existente" {
  run perms::resolve_uid root
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "resolve_uid falha em nome inexistente" {
  run perms::resolve_uid usuario-que-nao-existe
  [ "$status" -ne 0 ]
}

@test "resolve_gid resolve nome de grupo existente" {
  run perms::resolve_gid root
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "chmod não recursivo altera só o diretório alvo" {
  run perms::apply "$TREE" "" "" "0700" "" "" false
  [ "$status" -eq 0 ]
  [ "$(helper::mode "$TREE")" = "700" ]
  [ "$(helper::mode "$TREE/file.txt")" != "700" ]
}

@test "chmod recursivo com mode único cobre a árvore inteira" {
  run perms::apply "$TREE" "" "" "0744" "" "" true
  [ "$status" -eq 0 ]
  [ "$(helper::mode "$TREE")" = "744" ]
  [ "$(helper::mode "$TREE/file.txt")" = "744" ]
  [ "$(helper::mode "$TREE/sub/nested.txt")" = "744" ]
}

@test "dirMode e fileMode aplicam modos distintos a diretórios e arquivos" {
  run perms::apply "$TREE" "" "" "" "0750" "0640" true
  [ "$status" -eq 0 ]
  [ "$(helper::mode "$TREE")" = "750" ]
  [ "$(helper::mode "$TREE/sub")" = "750" ]
  [ "$(helper::mode "$TREE/file.txt")" = "640" ]
  [ "$(helper::mode "$TREE/sub/nested.txt")" = "640" ]
}

@test "chmod recursivo não segue symlink para fora da árvore" {
  local outside="$BATS_TEST_TMPDIR/fora.txt"
  printf 'intocado\n' >"$outside"
  chmod 0600 "$outside"
  ln -s "$outside" "$TREE/link"

  run perms::apply "$TREE" "" "" "0777" "" "" true
  [ "$status" -eq 0 ]
  [ "$(helper::mode "$outside")" = "600" ]
}

@test "chmod não recursivo num symlink é ignorado com aviso" {
  local outside="$BATS_TEST_TMPDIR/fora2.txt"
  printf 'intocado\n' >"$outside"
  chmod 0600 "$outside"
  ln -s "$outside" "$TREE/link2"

  run perms::apply "$TREE/link2" "" "" "0777" "" "" false
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "symlink ignorado"
  [ "$(helper::mode "$outside")" = "600" ]
}

@test "caminho inexistente falha com mensagem clara" {
  run perms::apply "$BATS_TEST_TMPDIR/nao-existe" "" "" "0755" "" "" false
  [ "$status" -ne 0 ]
  helper::assert_contains "$output" "caminho não existe"
}

@test "symlink quebrado é tratado como existente, não como ausente" {
  ln -s "$BATS_TEST_TMPDIR/alvo-inexistente" "$TREE/quebrado"
  run perms::apply "$TREE/quebrado" "" "" "0755" "" "" false
  [ "$status" -eq 0 ]
  helper::refute_contains "$output" "caminho não existe"
}

@test "entrada sem owner, group nem modo não faz nada e não falha" {
  local before
  before="$(helper::mode "$TREE")"
  run perms::apply "$TREE" "" "" "" "" "" false
  [ "$status" -eq 0 ]
  [ "$(helper::mode "$TREE")" = "$before" ]
}

@test "dry-run não altera modos" {
  export INITC_DRY_RUN=true
  local before
  before="$(helper::mode "$TREE")"
  run perms::apply "$TREE" "" "" "0700" "" "" true
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "[dry-run]"
  [ "$(helper::mode "$TREE")" = "$before" ]
}

@test "chown recursivo aplica owner e group" {
  if ((EUID != 0)); then
    skip "chown exige root"
  fi
  run perms::apply "$TREE" 4242 4243 "" "" "" true
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u:%g' "$TREE")" = "4242:4243" ]
  [ "$(stat -c '%u:%g' "$TREE/sub/nested.txt")" = "4242:4243" ]
}

@test "chown só de group preserva o owner" {
  if ((EUID != 0)); then
    skip "chown exige root"
  fi
  chown 1000:1000 "$TREE"
  run perms::chown "$TREE" "" 4243 false
  [ "$status" -eq 0 ]
  [ "$(stat -c '%u:%g' "$TREE")" = "1000:4243" ]
}

@test "chown com usuário inexistente falha com mensagem acionável" {
  run perms::chown "$TREE" usuario-que-nao-existe "" false
  [ "$status" -ne 0 ]
  helper::assert_contains "$output" "usuário não encontrado"
}
