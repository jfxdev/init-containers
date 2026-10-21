# shellcheck shell=bash
# Aplicação de owner/group e modo em diretórios e arquivos.

# perms::resolve_uid <uid|nome>
#
# Lê /etc/passwd diretamente em vez de usar id/getent: funciona igual no
# busybox do alpine e numa imagem distroless, onde os utilitários não existem.
perms::resolve_uid() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  awk -F: -v name="$value" '$1 == name { print $3; found = 1 } END { exit !found }' /etc/passwd
}

# perms::resolve_gid <gid|nome>
perms::resolve_gid() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  awk -F: -v name="$value" '$1 == name { print $3; found = 1 } END { exit !found }' /etc/group
}

# perms::chown <path> <owner> <group> <recursive>
#
# Os dois campos são opcionais: "" significa não mexer naquele lado.
perms::chown() {
  local path="$1" owner="$2" group="$3" recursive="$4"

  [[ -z "$owner" && -z "$group" ]] && return 0

  local uid="" gid=""
  if [[ -n "$owner" ]]; then
    uid="$(perms::resolve_uid "$owner")" || {
      log::error "usuário não encontrado (em imagens mínimas prefira o uid numérico)" owner="$owner" path="$path"
      return 1
    }
  fi
  if [[ -n "$group" ]]; then
    gid="$(perms::resolve_gid "$group")" || {
      log::error "grupo não encontrado (em imagens mínimas prefira o gid numérico)" group="$group" path="$path"
      return 1
    }
  fi

  # "uid:" faria o chown do GNU usar o grupo primário do usuário; especificar
  # apenas um dos lados exige as formas "uid" e ":gid".
  local spec
  if [[ -n "$uid" && -n "$gid" ]]; then
    spec="$uid:$gid"
  elif [[ -n "$uid" ]]; then
    spec="$uid"
  else
    spec=":$gid"
  fi

  # -h altera o próprio symlink em vez do alvo; -R não atravessa symlinks.
  local -a flags=(-h)
  [[ "$recursive" == "true" ]] && flags=(-Rh)

  if ! run::cmd "chown $spec $path" chown "${flags[@]}" "$spec" "$path"; then
    if ((EUID != 0)); then
      log::error "chown exige root: rode o init container com securityContext.runAsUser: 0" \
        path="$path" euid="$EUID"
    fi
    return 1
  fi
  return 0
}

# perms::chmod <path> <mode> <dir_mode> <file_mode> <recursive>
perms::chmod() {
  local path="$1" mode="$2" dir_mode="$3" file_mode="$4" recursive="$5"

  [[ -z "$mode" && -z "$dir_mode" && -z "$file_mode" ]] && return 0

  if [[ "$recursive" != "true" ]]; then
    # chmod num symlink altera o alvo, que pode estar fora do volume.
    if [[ -L "$path" ]]; then
      log::warn "symlink ignorado no chmod para não alterar o alvo" path="$path"
      return 0
    fi
    run::cmd "chmod $mode $path" chmod "$mode" "$path" || return 1
    return 0
  fi

  local status=0
  if [[ -n "$mode" ]]; then
    run::cmd "chmod -R $mode $path" \
      find "$path" ! -type l -exec chmod "$mode" {} + || status=1
  else
    if [[ -n "$dir_mode" ]]; then
      run::cmd "chmod dirs $dir_mode $path" \
        find "$path" -type d -exec chmod "$dir_mode" {} + || status=1
    fi
    if [[ -n "$file_mode" ]]; then
      run::cmd "chmod files $file_mode $path" \
        find "$path" ! -type d ! -type l -exec chmod "$file_mode" {} + || status=1
    fi
  fi
  return "$status"
}

# perms::apply <path> <owner> <group> <mode> <dir_mode> <file_mode> <recursive>
perms::apply() {
  local path="$1" owner="$2" group="$3" mode="$4" dir_mode="$5" file_mode="$6" recursive="$7"

  # -e segue symlinks, então um symlink quebrado precisa de -L para ser visto.
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    # Em dry-run o alvo normalmente ainda não existe: o objetivo é conferir o
    # plano, não o estado atual do volume.
    if [[ "$INITC_DRY_RUN" == "true" ]]; then
      log::warn "caminho não existe (dry-run)" path="$path"
      return 0
    fi
    log::error "caminho não existe" path="$path"
    return 1
  fi

  local status=0
  perms::chown "$path" "$owner" "$group" "$recursive" || status=1
  perms::chmod "$path" "$mode" "$dir_mode" "$file_mode" "$recursive" || status=1

  if ((status == 0)); then
    log::info "permissões aplicadas" path="$path" \
      owner="${owner:--}" group="${group:--}" \
      mode="${mode:-${dir_mode:--}/${file_mode:--}}" recursive="$recursive"
  fi
  return "$status"
}
