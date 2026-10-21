#!/usr/bin/env bats
# Validação da configuração: a mensagem precisa dizer qual campo está errado.

load helper/common

@test "configuração mínima válida é aceita" {
  helper::run_initc '{"apiVersion":"init-containers/v1","permissions":[{"path":"/tmp","mode":"0755"}]}' --dry-run
  [ "$status" -eq 0 ]
}

@test "arquivo ausente falha com exit 1" {
  run "$INITC_BIN" --config "$BATS_TEST_TMPDIR/nao-existe.json"
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "não encontrado"
}

@test "JSON malformado falha com exit 1" {
  helper::run_initc '{"apiVersion": '
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "JSON inválido"
}

@test "apiVersion ausente é reportado" {
  helper::run_initc '{"permissions":[{"path":"/tmp","mode":"0755"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "apiVersion: obrigatório"
}

@test "apiVersion desconhecida é reportada" {
  helper::run_initc '{"apiVersion":"init-containers/v2"}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "apiVersion: esperado"
  helper::assert_contains "$output" "init-containers/v1"
}

@test "campo desconhecido num repositório é reportado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"https://h/r.git","path":"/ws/r","brunch":"main"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "campo desconhecido"
  helper::assert_contains "$output" "brunch"
}

@test "path relativo é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"https://h/r.git","path":"ws/r"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "deve ser absoluto"
}

@test "path na raiz do filesystem é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"https://h/r.git","path":"/"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "não pode ser a raiz"
}

@test "URL SSH é rejeitada com mensagem explícita" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"git@github.com:o/r.git","path":"/ws/r"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "SSH não é suportado"
}

@test "credencial embutida na URL é rejeitada" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"https://user:token@h/r.git","path":"/ws/r"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "não embuta credenciais na URL"
}

@test "destinos aninhados são rejeitados" {
  helper::run_initc '{"apiVersion":"init-containers/v1","repositories":[
    {"url":"https://h/a.git","path":"/ws/a"},
    {"url":"https://h/b.git","path":"/ws/a/b"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" 'contém repositories[1].path'
}

@test "destinos duplicados são rejeitados mesmo escritos de formas diferentes" {
  helper::run_initc '{"apiVersion":"init-containers/v1","repositories":[
    {"url":"https://h/a.git","path":"/ws/a"},
    {"url":"https://h/b.git","path":"/ws/x/../a/"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "mesmo path"
}

@test "modo fora da notação octal em string é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "permissions":[{"path":"/ws/a","mode":"0899"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "modo deve ser string octal"
}

@test "modo como número é rejeitado: JSON não tem octal" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "permissions":[{"path":"/ws/a","mode":755}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "modo deve ser string octal"
}

@test "mode junto com dirMode é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1","permissions":[
    {"path":"/ws/a","mode":"0755","dirMode":"0755","recursive":true}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "mutuamente exclusivo"
}

@test "dirMode sem recursive é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "permissions":[{"path":"/ws/a","dirMode":"0755"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "só fazem sentido com recursive"
}

@test "entrada de permissão sem nada a aplicar é rejeitada" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "permissions":[{"path":"/ws/a","recursive":true}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "nada a aplicar"
}

@test "defaults.owner satisfaz a exigência de ter algo a aplicar" {
  helper::run_initc '{"apiVersion":"init-containers/v1","defaults":{"owner":1000},
    "permissions":[{"path":"/tmp","recursive":true}]}' --dry-run
  [ "$status" -eq 0 ]
}

@test "bloco auth inexistente é reportado" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "repositories":[{"url":"https://h/r.git","path":"/ws/r","auth":"gh"}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "não existe em auth"
  helper::assert_contains "$output" "gh"
}

@test "tokenEnv e tokenFile juntos são rejeitados" {
  helper::run_initc '{"apiVersion":"init-containers/v1",
    "auth":{"gh":{"tokenEnv":"T","tokenFile":"/t"}}}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "mutuamente exclusivos"
}

@test "bloco auth sem token é rejeitado" {
  helper::run_initc '{"apiVersion":"init-containers/v1","auth":{"gh":{}}}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "informe tokenEnv ou tokenFile"
}

@test "auth: none dispensa bloco de credenciais" {
  helper::run_initc '{"apiVersion":"init-containers/v1","defaults":{"auth":"gh"},
    "auth":{"gh":{"tokenEnv":"T"}},
    "repositories":[{"url":"https://h/r.git","path":"/ws/r","auth":"none"}]}' --dry-run
  [ "$status" -eq 0 ]
}

@test "todos os problemas são reportados de uma vez" {
  helper::run_initc '{"apiVersion":"v2","repositories":[
    {"url":"git@h:o/r.git","path":"rel","depth":-1}]}'
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "apiVersion"
  helper::assert_contains "$output" "SSH não é suportado"
  helper::assert_contains "$output" "deve ser absoluto"
  helper::assert_contains "$output" "depth"
}
