# Validates the input against the schema given with --slurpfile schema FILE, using a subset of
# JSON Schema 2020-12. Prints one error per line, "<json pointer>: <message>"; nothing when valid.
# Any keyword outside the subset is an error, so a schema cannot rely on an unchecked keyword.
# Usage: jq -r --slurpfile schema S.json -f tests/jsonschema-subset.jq INSTANCE.json

def known: ["$schema", "$id", "title", "description", "$defs", "$ref", "type", "const", "enum",
  "required", "properties", "additionalProperties", "items", "minItems", "maxItems",
  "minLength", "maxLength", "pattern", "minimum", "maximum", "format"];

def esc: tostring | gsub("~"; "~0") | gsub("/"; "~1");

# Every schema object reachable through $defs, properties and items, with its pointer.
def subschemas($p):
  [$p, .],
  (if type == "object" then
     ((.["$defs"] // {}) | to_entries[] | .key as $k | .value | subschemas("\($p)/$defs/\($k | esc)")),
     ((.properties // {}) | to_entries[] | .key as $k | .value | subschemas("\($p)/properties/\($k | esc)")),
     (if has("items") then .items | subschemas("\($p)/items") else empty end)
   else empty end);

def keyword_errors:
  subschemas("#") as [$p, $s]
  | if ($s | type) != "object" then "\($p): a schema must be an object"
    else
      ($s | keys_unsorted - known | .[] | "\($p): unsupported keyword \(.)"),
      (if $s | has("additionalProperties") and .additionalProperties != false
       then "\($p): only additionalProperties false is supported" else empty end)
    end;

def is_type($t):
  if $t == "integer" then type == "number" and . == floor
  else type == $t end;

def v($s; $p):
  . as $x
  | if $s | has("$ref") then
      if ($s["$ref"] | test("^#/\\$defs/[^/]+$")) and ($schema[0]["$defs"][$s["$ref"][8:]] != null)
      then v($schema[0]["$defs"][$s["$ref"][8:]]; $p)
      else "\($p): unsupported $ref \($s["$ref"])" end
    else empty end,
    (if $s | has("type") then
       ($s.type | if type == "array" then . else [.] end) as $ts
       | if any($ts[]; . as $t | $x | is_type($t)) then empty
         else "\($p): \($x | type) is not \($ts | join(" or "))" end
     else empty end),
    (if ($s | has("const")) and $x != $s.const then "\($p): must be \($s.const | tojson)" else empty end),
    (if ($s | has("enum")) and (any($s.enum[]; . == $x) | not) then "\($p): not one of \($s.enum | tojson)" else empty end),
    (if ($x | type) == "object" then
       ($s.required // [] | .[] | select(. as $k | $x | has($k) | not) | "\($p): missing \(.)"),
       ($x | keys_unsorted[] as $k
        | if ($s.properties // {} | has($k)) then $x[$k] | v($s.properties[$k]; "\($p)/\($k | esc)")
          elif $s.additionalProperties == false then "\($p): unknown member \($k)"
          else empty end)
     else empty end),
    (if ($x | type) == "array" then
       (if $s.minItems != null and ($x | length) < $s.minItems then "\($p): fewer than \($s.minItems) items" else empty end),
       (if $s.maxItems != null and ($x | length) > $s.maxItems then "\($p): more than \($s.maxItems) items" else empty end),
       (if $s | has("items") then range(0; $x | length) as $i | $x[$i] | v($s.items; "\($p)/\($i)") else empty end)
     else empty end),
    (if ($x | type) == "string" then
       (if $s.minLength != null and ($x | length) < $s.minLength then "\($p): shorter than \($s.minLength)" else empty end),
       (if $s.maxLength != null and ($x | length) > $s.maxLength then "\($p): longer than \($s.maxLength)" else empty end),
       (if $s.pattern != null and ($x | test($s.pattern) | not) then "\($p): does not match \($s.pattern)" else empty end)
     else empty end),
    (if ($x | type) == "number" then
       (if $s.minimum != null and $x < $s.minimum then "\($p): below \($s.minimum)" else empty end),
       (if $s.maximum != null and $x > $s.maximum then "\($p): above \($s.maximum)" else empty end)
     else empty end);

($schema[0] | keyword_errors), v($schema[0]; "#")
