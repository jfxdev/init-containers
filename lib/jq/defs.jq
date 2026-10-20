# Definições compartilhadas pelos programas jq de validação e normalização.
# Carregado por concatenação antes de cada programa.

def api_version: "init-containers/v1";

def normpath:
  if type != "string" then .
  else
    ( split("/")
      | reduce .[] as $seg ([];
          if $seg == "" or $seg == "." then .
          elif $seg == ".." then (if length > 0 then .[0:-1] else . end)
          else . + [$seg] end)
      | "/" + join("/") )
  end;

def is_abs: type == "string" and startswith("/");
def is_mode: type == "string" and test("^[0-7]{3,4}$");
def is_bool: type == "boolean";
def is_ident: (type == "number" and . == floor and . >= 0)
           or (type == "string" and length > 0);

# Campos desconhecidos viram erro: num ConfigMap montado, um typo em
# "recursive" silenciosamente não aplicaria nada.
def unknown_keys($allowed; $prefix):
  if type == "object"
  then (keys - $allowed) | map("\($prefix): campo desconhecido \"\(.)\"")
  else [] end;

def opt_bool($field; $prefix):
  if has($field) and ((.[$field] | is_bool) | not)
  then ["\($prefix).\($field): deve ser true ou false"] else [] end;

def opt_mode($field; $prefix):
  if has($field) and ((.[$field] | is_mode) | not)
  then ["\($prefix).\($field): modo deve ser string octal, ex.: \"0755\""] else [] end;

def opt_ident($field; $prefix):
  if has($field) and ((.[$field] | is_ident) | not)
  then ["\($prefix).\($field): deve ser um uid/gid inteiro ou um nome"] else [] end;
