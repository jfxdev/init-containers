# Normalização do arquivo de configuração.
#
# Aplica o bloco defaults, normaliza paths e garante que todo campo exista com
# um tipo previsível, de modo que o shell possa ler cada valor sem repetir a
# lógica de default. Identidades e modos saem como string ("" quando ausentes).
#
# Requer lib/jq/defs.jq concatenado antes deste arquivo.
# Pressupõe uma configuração já validada.

def ident_str: if . == null then "" else tostring end;

(.defaults // {}) as $d
| {
    concurrency: ($d.concurrency // 4),
    auth: ( (.auth // {})
            | map_values({
                type: (.type // "https"),
                username: (.username // "x-access-token"),
                tokenEnv: (.tokenEnv // ""),
                tokenFile: (.tokenFile // "")
              }) ),
    repositories: [ (.repositories // [])[] | {
        url: .url,
        path: (.path | normpath),
        ref: (.ref // ""),
        depth: (.depth // 0),
        submodules: (.submodules // false),
        auth: (.auth // $d.auth // ""),
        optional: (.optional // false),
        force: (.force // false),
        owner: ((.owner // $d.owner) | ident_str),
        group: ((.group // $d.group) | ident_str),
        mode: (.mode // $d.mode // "")
      } ],
    permissions: [ (.permissions // [])[] | {
        path: (.path | normpath),
        owner: ((.owner // $d.owner) | ident_str),
        group: ((.group // $d.group) | ident_str),
        # O modo default só se aplica quando a entrada não declara modo algum,
        # para não sobrescrever a combinação dirMode/fileMode.
        mode: ( if (has("mode") or has("dirMode") or has("fileMode"))
                then (.mode // "") else ($d.mode // "") end ),
        dirMode: (.dirMode // ""),
        fileMode: (.fileMode // ""),
        recursive: (.recursive // false),
        optional: (.optional // false)
      } ]
  }
