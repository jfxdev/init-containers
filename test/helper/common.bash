# shellcheck shell=bash
# Helpers compartilhados pelos testes bats.

INITC_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export INITC_ROOT
INITC_BIN="$INITC_ROOT/bin/init-containers"
export INITC_BIN

# helper::load_libs carrega as libs no shell do teste, para exercitar funções
# isoladamente.
helper::load_libs() {
  export INITC_LIB_DIR="$INITC_ROOT/lib"
  export INITC_WORK_DIR="$BATS_TEST_TMPDIR/initc-work"
  mkdir -p "$INITC_WORK_DIR"
  export INITC_LOG_FORMAT=text
  export INITC_LOG_LEVEL=info
  export INITC_DRY_RUN=false

  # shellcheck source=log.sh
  source "$INITC_LIB_DIR/log.sh"
  # shellcheck source=run.sh
  source "$INITC_LIB_DIR/run.sh"
  # shellcheck source=config.sh
  source "$INITC_LIB_DIR/config.sh"
  # shellcheck source=perms.sh
  source "$INITC_LIB_DIR/perms.sh"
  # shellcheck source=clone.sh
  source "$INITC_LIB_DIR/clone.sh"
}

# helper::write_config <json> ecoa o caminho do arquivo criado.
helper::write_config() {
  local file="$BATS_TEST_TMPDIR/config.$RANDOM.json"
  printf '%s\n' "$1" >"$file"
  printf '%s' "$file"
}

# helper::run_initc <json> [args...]
helper::run_initc() {
  local config
  config="$(helper::write_config "$1")"
  shift
  run "$INITC_BIN" --config "$config" "$@"
}

# helper::make_repo ecoa a URL file:// de um repositório bare com dois commits
# e a tag v1.0.0 no primeiro.
#
# Os commits usam datas e autor fixos para que os SHAs sejam estáveis.
helper::make_repo() {
  local name="${1:-app}"
  local src="$BATS_TEST_TMPDIR/src-$name"
  local bare="$BATS_TEST_TMPDIR/bare-$name.git"

  mkdir -p "$src/sub"
  git -C "$src" init -q -b main
  git -C "$src" config user.email tester@example.com
  git -C "$src" config user.name Tester
  git -C "$src" config commit.gpgsign false

  printf 'um\n' >"$src/file.txt"
  printf 'aninhado\n' >"$src/sub/nested.txt"
  git -C "$src" add -A
  git -C "$src" commit -qm "primeiro"
  git -C "$src" tag v1.0.0

  printf 'dois\n' >"$src/file.txt"
  git -C "$src" add -A
  git -C "$src" commit -qm "segundo"

  git clone -q --bare "$src" "$bare"
  printf 'file://%s' "$bare"
}

# helper::repo_src <nome> ecoa o diretório de trabalho de origem, para criar
# novos commits e simular mudanças upstream.
helper::repo_src() {
  printf '%s' "$BATS_TEST_TMPDIR/src-${1:-app}"
}

# helper::push_commit <nome> <conteúdo> adiciona um commit em main e publica no
# bare correspondente.
helper::push_commit() {
  local name="${1:-app}" content="$2"
  local src="$BATS_TEST_TMPDIR/src-$name"
  printf '%s\n' "$content" >"$src/file.txt"
  git -C "$src" add -A
  git -C "$src" commit -qm "atualiza"
  git -C "$src" push -q "$BATS_TEST_TMPDIR/bare-$name.git" main
}

# helper::sha <nome> <revisão>
helper::sha() {
  git -C "$BATS_TEST_TMPDIR/src-${1:-app}" rev-parse "$2"
}

# helper::mode <caminho> ecoa o modo octal.
helper::mode() {
  stat -c '%a' "$1"
}

helper::assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf 'esperado conter: %s\nrecebido:\n%s\n' "$2" "$1" >&2
    return 1
  fi
}

helper::refute_contains() {
  if [[ "$1" == *"$2"* ]]; then
    printf 'esperado NÃO conter: %s\nrecebido:\n%s\n' "$2" "$1" >&2
    return 1
  fi
}
