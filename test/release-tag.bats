#!/usr/bin/env bats
# Escolha da tag de release. Tudo roda contra um remoto bare local, sem rede.

load helper/common

RELEASE_TAG="$INITC_ROOT/tools/release-tag.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/work"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"

  git init -q --bare "$REMOTE"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email tester@example.com
  git -C "$REPO" config user.name Tester
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" config tag.gpgsign false
  git -C "$REPO" commit -q --allow-empty -m primeiro
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push -q origin main

  # Data fixa: sem ela, um teste que rodasse na virada do dia em UTC veria
  # duas datas diferentes entre duas chamadas.
  export INITC_RELEASE_DATE=2026-10-20

  cd "$REPO" || return 1
}

# tag_local <nome> cria a tag só no repositório de trabalho.
tag_local() {
  git tag -a "$1" -m "release"
}

# tag_remota <nome> cria a tag apenas no remoto, como uma release publicada
# por outra pessoa.
tag_remota() {
  git tag -a "$1" -m "release"
  git push -q origin "$1"
  git tag -d "$1" >/dev/null
}

@test "sem tag do dia, a tag é a própria data" {
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20" ]
}

@test "com a tag do dia, o sufixo .1 é escolhido sozinho" {
  tag_local 2026-10-20
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.1" ]
}

@test "o sufixo continua a partir do maior em uso" {
  tag_local 2026-10-20
  tag_local 2026-10-20.1
  tag_local 2026-10-20.2
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.3" ]
}

# Uma tag já publicada não pode ser reaproveitada para outro commit: quem
# baixou aquela imagem continua com a dela.
@test "sufixo apagado não é reaproveitado" {
  tag_local 2026-10-20
  tag_local 2026-10-20.2
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.3" ]
}

@test "tag que existe só no remoto também ocupa o nome" {
  tag_remota 2026-10-20
  tag_remota 2026-10-20.1
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.2" ]
}

# O filtro do git tag e do ls-remote é glob: sem a conferência do formato,
# qualquer tag começada pela data entraria na contagem do sufixo.
@test "tag parecida não entra na contagem" {
  tag_local 2026-10-20-rascunho
  tag_local 2026-10-20x
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20" ]
}

@test "sufixo com zero à esquerda não é lido como octal" {
  tag_local 2026-10-20
  tag_local 2026-10-20.08
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.9" ]
}

@test "--print não cria tag nenhuma" {
  run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ -z "$(git tag --list)" ]
}

@test "a tag criada é anotada e aponta para HEAD" {
  run "$RELEASE_TAG"
  [ "$status" -eq 0 ]
  [ "$(git cat-file -t 2026-10-20)" = "tag" ]
  [ "$(git rev-list -n1 2026-10-20)" = "$(git rev-parse HEAD)" ]
}

@test "criar a tag não a publica: o push continua sendo explícito" {
  run "$RELEASE_TAG"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "git push origin 2026-10-20"
  [ -z "$(git ls-remote --tags --refs origin)" ]
}

# A tag é dado e vai para stdout; o resto é log e vai para stderr, igual ao
# init container. É o que deixa `tag="$(tools/release-tag.sh)"` funcionar no
# workflow que publica a tag.
@test "--print escreve só a tag no stdout" {
  run bash -c "'$RELEASE_TAG' --print 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20" ]
}

@test "criar a tag também escreve só o nome dela no stdout" {
  tag_local 2026-10-20
  run bash -c "'$RELEASE_TAG' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20.1" ]
}

@test "remoto inacessível vira aviso, não erro" {
  tag_local 2026-10-20
  run "$RELEASE_TAG" --print inexistente
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "não foi possível consultar as tags"
  helper::assert_contains "$output" "2026-10-20.1"
}

@test "commit fora do remoto vira aviso, não erro" {
  git commit -q --allow-empty -m "ainda não publicado"
  run "$RELEASE_TAG"
  [ "$status" -eq 0 ]
  helper::assert_contains "$output" "não está em nenhum branch"
  [ "$(git rev-list -n1 2026-10-20)" = "$(git rev-parse HEAD)" ]
}

@test "data sem formato de data falha com mensagem clara" {
  INITC_RELEASE_DATE=ontem run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "data de release inválida"
}

# A validação é a mesma do workflow: criar aqui uma tag que o release recusaria
# depois do push só adiaria o erro.
@test "dia que não existe no mês é recusado" {
  INITC_RELEASE_DATE=2026-02-30 run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "data de release inválida"
}

@test "29 de fevereiro passa em ano bissexto e falha fora dele" {
  INITC_RELEASE_DATE=2024-02-29 run "$RELEASE_TAG" --print
  [ "$status" -eq 0 ]
  [ "$output" = "2024-02-29" ]

  INITC_RELEASE_DATE=2026-02-29 run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
}

@test "mês e dia fora do intervalo são recusados" {
  INITC_RELEASE_DATE=2026-13-01 run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]

  INITC_RELEASE_DATE=2026-10-32 run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
}

# O workflow só dispara em tags 20xx; um ano fora disso viraria uma tag que
# nunca publicaria nada.
@test "ano fora do século é recusado" {
  INITC_RELEASE_DATE=1999-10-20 run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
}

@test "último dia de cada mês é aceito" {
  for d in 2026-01-31 2026-04-30 2026-06-30 2026-09-30 2026-12-31; do
    INITC_RELEASE_DATE="$d" run "$RELEASE_TAG" --print
    [ "$status" -eq 0 ]
    [ "$output" = "$d" ]
  done
}

@test "opção desconhecida falha com exit 1" {
  run "$RELEASE_TAG" --nao-existe
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "opção desconhecida"
}

@test "fora de um repositório git falha com exit 1" {
  mkdir -p "$BATS_TEST_TMPDIR/vazio"
  cd "$BATS_TEST_TMPDIR/vazio" || return 1
  run "$RELEASE_TAG" --print
  [ "$status" -eq 1 ]
  helper::assert_contains "$output" "não é um repositório git"
}
