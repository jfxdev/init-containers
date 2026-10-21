#!/usr/bin/env bash
# Cria a tag de release do dia.
#
# As releases são por data (AAAA-MM-DD). Quando a tag do dia já existe, o
# sufixo sequencial é escolhido automaticamente: 2026-10-20, depois
# 2026-10-20.1, depois 2026-10-20.2.
#
# A tag não é publicada aqui. O push é o que dispara o workflow de release, e
# essa continua sendo uma decisão explícita de quem está publicando.
set -euo pipefail

release::usage() {
  cat <<'EOF'
uso: tools/release-tag.sh [opções] [remoto]

Cria a tag de release do dia, com sufixo sequencial se já existir uma.
O remoto padrão é origin.

  -p, --print   imprime a tag que seria criada, sem criar nada
  -h, --help    esta ajuda

Variáveis:
  INITC_RELEASE_DATE   usa esta data (AAAA-MM-DD) em vez de hoje em UTC
EOF
}

# release::existing <data> <remoto>
#
# As tags do dia que já existem, locais e no remoto: uma tag local ainda não
# publicada também ocupa o nome.
release::existing() {
  local date="$1" remote="$2"

  local remote_tags=""
  if ! remote_tags="$(git ls-remote --tags --refs "$remote" "$date*" 2>/dev/null)"; then
    printf 'aviso: não foi possível consultar as tags em %s; considerando só as locais\n' \
      "$remote" >&2
    remote_tags=""
  fi

  # O filtro do ls-remote e do git tag é glob; aqui as formas aceitas são
  # conferidas de verdade, para que uma tag como "2026-10-20-rascunho" não
  # entre na contagem do sufixo.
  {
    git tag --list "$date*"
    printf '%s' "$remote_tags" | sed -n 's|.*refs/tags/||p'
  } | grep -E "^${date}(\.[0-9]+)?$" | sort -u
}

# release::next <data> <remoto>
#
# A tag sem sufixo conta como sequência 0, então a segunda release do dia é
# .1. O próximo sufixo vem do maior em uso, não da contagem: com .1 apagada,
# depois de .2 vem .3, e uma tag já publicada nunca é reaproveitada.
release::next() {
  local date="$1" remote="$2"
  local tag suffix highest=-1

  while read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ "$tag" == "$date" ]]; then
      suffix=0
    else
      # 10# evita que um sufixo com zero à esquerda seja lido como octal.
      suffix=$((10#${tag##*.}))
    fi
    if ((suffix > highest)); then
      highest=$suffix
    fi
  done < <(release::existing "$date" "$remote")

  if ((highest < 0)); then
    printf '%s\n' "$date"
  else
    printf '%s.%d\n' "$date" "$((highest + 1))"
  fi
}

main() {
  local remote="origin" print_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --print)
        print_only=1
        ;;
      -h | --help)
        release::usage
        return 0
        ;;
      -*)
        printf 'opção desconhecida: %s\n' "$1" >&2
        release::usage >&2
        return 1
        ;;
      *)
        remote="$1"
        ;;
    esac
    shift
  done

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'erro: não é um repositório git\n' >&2
    return 1
  fi

  # UTC: duas pessoas em fusos diferentes chegam na mesma data do calendário.
  # INITC_RELEASE_DATE existe para os testes e para datar uma release à mão.
  local date tag
  date="${INITC_RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
  if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'erro: INITC_RELEASE_DATE inválida: %s (esperado AAAA-MM-DD)\n' "$date" >&2
    return 1
  fi
  tag="$(release::next "$date" "$remote")"

  # Nos dois modos a tag é dado e vai sozinha para stdout; o resto é log e vai
  # para stderr. Assim `tag="$(tools/release-tag.sh)"` serve tanto para um
  # script quanto para o workflow que publica a tag.
  if ((print_only)); then
    printf '%s\n' "$tag"
    return 0
  fi

  if [[ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]]; then
    printf 'aviso: o commit de HEAD não está em nenhum branch de %s\n' "$remote" >&2
  fi

  git tag -a "$tag" -m "Release $tag"
  printf 'tag %s criada em %s\n' "$tag" "$(git rev-parse --short HEAD)" >&2
  printf 'publique com: git push %s %s\n' "$remote" "$tag" >&2
  printf '%s\n' "$tag"
}

main "$@"
