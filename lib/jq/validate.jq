# Validação do arquivo de configuração do init container.
#
# Emite uma linha por problema encontrado; saída vazia significa configuração
# válida. Acumula todos os problemas em vez de parar no primeiro: num init
# container cada tentativa custa um restart do Pod, então vale entregar a lista
# completa de uma vez.
#
# Requer lib/jq/defs.jq concatenado antes deste arquivo.

# ---------------------------------------------------------------------------
# Passo 1: formato geral. Sem isso, os passos seguintes podem acessar campos de
# tipo inesperado.
# ---------------------------------------------------------------------------
def shape_problems:
  ( if type != "object" then ["raiz: esperado um objeto JSON"] else [] end )
  + ( if type == "object" then
        unknown_keys(["apiVersion", "defaults", "auth", "repositories", "permissions"]; "raiz")
        + ( if (.defaults? // null) != null and (.defaults | type) != "object"
            then ["defaults: deve ser um objeto"] else [] end )
        + ( if (.auth? // null) != null and (.auth | type) != "object"
            then ["auth: deve ser um objeto"] else [] end )
        + ( if (.repositories? // null) != null and (.repositories | type) != "array"
            then ["repositories: deve ser uma lista"] else [] end )
        + ( if (.permissions? // null) != null and (.permissions | type) != "array"
            then ["permissions: deve ser uma lista"] else [] end )
      else [] end );

# ---------------------------------------------------------------------------
# Passo 2: conteúdo.
# ---------------------------------------------------------------------------
def version_problems:
  if (.apiVersion? // null) == null then
    ["apiVersion: obrigatório, use \"\(api_version)\""]
  elif .apiVersion != api_version then
    ["apiVersion: esperado \"\(api_version)\", recebido \(.apiVersion | tojson)"]
  else [] end;

def defaults_problems:
  (.defaults // {}) as $d
  | ( $d | unknown_keys(["owner", "group", "mode", "auth", "concurrency"]; "defaults") )
  + ( $d | opt_ident("owner"; "defaults") )
  + ( $d | opt_ident("group"; "defaults") )
  + ( $d | opt_mode("mode"; "defaults") )
  + ( if ($d | has("concurrency"))
        and (($d.concurrency | type) != "number"
             or $d.concurrency != ($d.concurrency | floor)
             or $d.concurrency < 1)
      then ["defaults.concurrency: deve ser um inteiro >= 1"] else [] end )
  + ( if ($d | has("auth")) and (($d.auth | type) != "string")
      then ["defaults.auth: deve ser o nome de um bloco em auth"] else [] end );

def auth_problems:
  (.auth // {}) as $auth
  | [ $auth | keys[] ] as $names
  | reduce $names[] as $name ([];
      . + ( ($auth[$name]) as $spec
            | "auth.\($name)" as $prefix
            | ( if $name == "none"
                then ["auth: o nome \"none\" é reservado para clone anônimo"] else [] end )
            + ( if ($spec | type) != "object" then ["\($prefix): deve ser um objeto"]
                else
                  ( $spec | unknown_keys(["type", "username", "tokenEnv", "tokenFile"]; $prefix) )
                  + ( if ($spec.type // "https") != "https"
                      then ["\($prefix).type: apenas \"https\" é suportado nesta versão"] else [] end )
                  + ( if ($spec | has("tokenEnv")) and ($spec | has("tokenFile"))
                      then ["\($prefix): tokenEnv e tokenFile são mutuamente exclusivos"]
                      elif (($spec | has("tokenEnv")) or ($spec | has("tokenFile"))) | not
                      then ["\($prefix): informe tokenEnv ou tokenFile"]
                      else [] end )
                  + ( if ($spec | has("tokenFile")) and (($spec.tokenFile | is_abs) | not)
                      then ["\($prefix).tokenFile: deve ser um caminho absoluto"] else [] end )
                  + ( if ($spec | has("tokenEnv")) and (($spec.tokenEnv | type) != "string"
                                                        or ($spec.tokenEnv | length) == 0)
                      then ["\($prefix).tokenEnv: deve ser o nome de uma variável de ambiente"] else [] end )
                end ) ) );

def url_problems($prefix):
  . as $url
  | if ($url | type) != "string" or ($url | length) == 0 then
      ["\($prefix).url: obrigatório"]
    # URLs scp-like (git@host:org/repo.git) não têm scheme e não são aceitas:
    # esta versão só fala HTTPS.
    elif ($url | test("^[a-zA-Z][a-zA-Z0-9+.-]*://") | not) then
      ["\($prefix).url: esperada URL http(s), recebido \($url | tojson) (SSH não é suportado nesta versão)"]
    else
      ( ($url | capture("^(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]*)://(?<authority>[^/?#]*)")) as $parts
        | ( if ["http", "https", "file"] | index($parts.scheme) then []
            else ["\($prefix).url: scheme \"\($parts.scheme)\" não suportado, use http, https ou file"] end )
          # Credencial embutida na URL vazaria no ConfigMap e em qualquer log de
          # erro do servidor remoto. Use um bloco auth.
        + ( if $parts.authority | test("@")
            then ["\($prefix).url: não embuta credenciais na URL, declare um bloco auth"] else [] end ) )
    end;

def path_problems($prefix):
  if (type != "string") or (length == 0) then ["\($prefix).path: obrigatório"]
  elif (is_abs | not) then ["\($prefix).path: deve ser absoluto, recebido \(tojson)"]
  elif normpath == "/" then ["\($prefix).path: não pode ser a raiz do filesystem"]
  else [] end;

def repository_problems($root; $i):
  . as $repo
  | "repositories[\($i)]" as $prefix
  | if ($repo | type) != "object" then ["\($prefix): deve ser um objeto"] else
  ( $repo | unknown_keys(["url", "path", "ref", "depth", "submodules", "auth",
                          "optional", "force", "owner", "group", "mode"]; $prefix) )
  + ( $repo.url | url_problems($prefix) )
  + ( $repo.path | path_problems($prefix) )
  + ( $repo | opt_bool("submodules"; $prefix) )
  + ( $repo | opt_bool("optional"; $prefix) )
  + ( $repo | opt_bool("force"; $prefix) )
  + ( $repo | opt_ident("owner"; $prefix) )
  + ( $repo | opt_ident("group"; $prefix) )
  + ( $repo | opt_mode("mode"; $prefix) )
  + ( if ($repo | has("ref")) and (($repo.ref | type) != "string")
      then ["\($prefix).ref: deve ser uma string (branch, tag ou SHA)"] else [] end )
  + ( if ($repo | has("depth"))
        and (($repo.depth | type) != "number"
             or $repo.depth != ($repo.depth | floor)
             or $repo.depth < 0)
      then ["\($prefix).depth: deve ser um inteiro >= 0 (0 = clone completo)"] else [] end )
  + ( ($repo.auth // $root.defaults.auth // "") as $name
      | if ($name | type) == "string" and $name != "" and $name != "none"
           and (($root.auth // {}) | has($name) | not)
        then ["\($prefix).auth: bloco \"\($name)\" não existe em auth"] else [] end )
  end;

# Destinos duplicados ou aninhados: um clone dentro de outro faria o segundo
# apagar ou sujar a árvore do primeiro, com resultado dependente da ordem.
def nesting_problems:
  [ (.repositories // [])[]
    | if (type == "object") and ((.path | type) == "string") then (.path | normpath) else null end ] as $paths
  | [ range(0; $paths | length) as $i
      | range(0; $paths | length) as $j
      | select($i < $j)
      | select($paths[$i] != null and $paths[$j] != null)
      | if $paths[$i] == $paths[$j] then
          "repositories[\($i)] e repositories[\($j)]: mesmo path \"\($paths[$i])\""
        elif ($paths[$j] | startswith($paths[$i] + "/")) then
          "repositories[\($i)].path \"\($paths[$i])\" contém repositories[\($j)].path \"\($paths[$j])\""
        elif ($paths[$i] | startswith($paths[$j] + "/")) then
          "repositories[\($j)].path \"\($paths[$j])\" contém repositories[\($i)].path \"\($paths[$i])\""
        else empty end ];

def permission_problems($root; $i):
  . as $perm
  | "permissions[\($i)]" as $prefix
  | if ($perm | type) != "object" then ["\($prefix): deve ser um objeto"] else
  ( $perm | unknown_keys(["path", "owner", "group", "mode", "dirMode", "fileMode",
                          "recursive", "optional"]; $prefix) )
  + ( $perm.path | path_problems($prefix) )
  + ( $perm | opt_bool("recursive"; $prefix) )
  + ( $perm | opt_bool("optional"; $prefix) )
  + ( $perm | opt_ident("owner"; $prefix) )
  + ( $perm | opt_ident("group"; $prefix) )
  + ( $perm | opt_mode("mode"; $prefix) )
  + ( $perm | opt_mode("dirMode"; $prefix) )
  + ( $perm | opt_mode("fileMode"; $prefix) )
  + ( if ($perm | has("mode")) and (($perm | has("dirMode")) or ($perm | has("fileMode")))
      then ["\($prefix): mode é mutuamente exclusivo com dirMode/fileMode"] else [] end )
  + ( if (($perm.recursive // false) != true)
        and (($perm | has("dirMode")) or ($perm | has("fileMode")))
      then ["\($prefix): dirMode/fileMode só fazem sentido com recursive: true, use mode"] else [] end )
    # O modo default só se aplica quando a entrada não declara modo algum, para
    # não sobrescrever a combinação dirMode/fileMode.
  + ( ( ($perm | has("mode")) or ($perm | has("dirMode")) or ($perm | has("fileMode"))
        or (($root.defaults.mode // null) != null) ) as $has_mode
      | ( ($perm | has("owner")) or (($root.defaults.owner // null) != null) ) as $has_owner
      | ( ($perm | has("group")) or (($root.defaults.group // null) != null) ) as $has_group
      | if ($has_mode or $has_owner or $has_group) then []
        else ["\($prefix): nada a aplicar, informe owner, group, mode ou dirMode/fileMode"] end )
  end;

def content_problems:
  . as $root
  | version_problems
  + defaults_problems
  + auth_problems
  + ( reduce ((.repositories // []) | to_entries[]) as $entry ([];
        . + ($entry.value | repository_problems($root; $entry.key))) )
  + nesting_problems
  + ( reduce ((.permissions // []) | to_entries[]) as $entry ([];
        . + ($entry.value | permission_problems($root; $entry.key))) );

shape_problems as $shape
| (if ($shape | length) > 0 then $shape else content_problems end)
| .[]
