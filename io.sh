#!/usr/bin/env bash
# io.sh: Indian Opinion from bash and curl (jq optional). The same commands,
# flags, exit codes, IO_TOKEN and token file as the indianopinion CLI, minus
# the MCP bridge and skill install. Output is the API's JSON.
#   curl -fsSL https://indianopinion.org/agents/cli/io.sh -o ~/bin/io && chmod +x ~/bin/io
#   io login start --email you@yourdomain.example
#   io login verify --email you@yourdomain.example --code 123456
#   io digest | jq '.stories[] | {title, url}'
# Exit codes: 0 ok, 1 unexpected, 2 usage, 3 auth, 4 not found, 5 rate
# limited, 6 validation, 7 network or server, 8 needs a choice.
# Guide: https://indianopinion.org/agents/
set -uo pipefail

IO_SH_VERSION=0.2.0
API="${IO_API:-https://indianopinion.org/wp-json/io/v1}"
API="${API%/}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/indianopinion"
TOKEN_FILE="$CONF/token"
UA="indianopinion-io.sh/$IO_SH_VERSION (+https://indianopinion.org/agents/)"

die() { echo "io: $2" >&2; exit "$1"; }
usage() { die 2 "$1"; }

jstr() { # JSON string literal
  local s=$1 out='' c i
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}; if [[ $c < ' ' ]]; then out+=$(printf '\\u%04x' "'$c"); else out+=$c; fi; done
  printf '"%s"' "$out"
}

token() {
  if [ -n "${IO_TOKEN:-}" ]; then printf '%s' "$IO_TOKEN"; return; fi
  [ -r "$TOKEN_FILE" ] && tr -d ' \n\r' < "$TOKEN_FILE"
}

exit_for() { # status, body
  case "$1" in
    2??) echo 0 ;;
    401|403) echo 3 ;;
    404) echo 4 ;;
    409) if printf '%s' "$2" | grep -q '"ambiguous"'; then echo 8; else echo 6; fi ;;
    429) echo 5 ;;
    400|415|422) echo 6 ;;
    000|5??) echo 7 ;;
    *) echo 1 ;;
  esac
}

# req METHOD PATH [BODY] [auth]
req() {
  local method=$1 path=$2 body=${3:-} auth=${4:-} tok out status code
  local args=(-sS -o - -w '\n%{http_code}' -X "$method" -H 'Accept: application/json' -A "$UA")
  if [ -n "$auth" ]; then
    tok=$(token)
    [ -n "$tok" ] || die 3 'no token: run "io login start --email <address>" then "io login verify", or set IO_TOKEN'
    args+=(-H "Authorization: Bearer $tok")
  fi
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  out=$(curl "${args[@]}" "$API$path" 2>/dev/null) || { echo "{\"ok\":false,\"error\":\"network\",\"message\":\"could not reach $API\"}" >&2; exit 7; }
  status=${out##*$'\n'}; out=${out%$'\n'*}
  code=$(exit_for "$status" "$out")
  if [ "$code" != 0 ]; then printf '%s\n' "$out" >&2; exit "$code"; fi
  if [ -t 1 ] && command -v jq >/dev/null 2>&1; then printf '%s\n' "$out" | jq .; else printf '%s\n' "$out"; fi
}

# Parse --flag value pairs into F_<name> variables (dashes become underscores).
POS=()
parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|--on|--off|--would-send) local k=${1#--}; k=${k//-/_}; printf -v "F_$k" '%s' 1 ;;
      --*=*) local k=${1%%=*}; k=${k#--}; k=${k//-/_}; printf -v "F_$k" '%s' "${1#*=}" ;;
      --*) local k=${1#--}; k=${k//-/_}; [ $# -ge 2 ] || usage "$1 needs a value"; printf -v "F_$k" '%s' "$2"; shift ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
}
f() { local v="F_$1"; printf '%s' "${!v:-}"; }

help() {
  cat <<EOF
io.sh $IO_SH_VERSION: Indian Opinion from bash and curl. Guide: https://indianopinion.org/agents/
  io login start --email E [--name N --operator-url U --purpose P]
  io login verify --email E --code 123456 [--label L]     stores the token in $TOKEN_FILE (0600)
  io me
  io digest [--date YYYY-MM-DD]
  io briefs [--since ISO] [--limit N]                     (no account needed; filter with jq)
  io brief <id>                                           (no account needed)
  io topics list | follow <text> [--tier instant|daily] [--key K] | unfollow <topic_id>
  io breaking status | set [--threshold 0.4] [--composite mean] [--max-per-day 3] [--on|--off] | recent [--days 7] | show <event_id>
  io prefs get | set [--format text|json|html] [--hour 7|12|18|21] [--tz Asia/Kolkata]
  io unsubscribe --what digest|breaking|topics|all --yes
  io token list | revoke <id> --yes
Env: IO_TOKEN, IO_API, IO_EMAIL, XDG_CONFIG_HOME. Exit codes: 0 ok, 2 usage, 3 auth, 4 not found, 5 rate limited, 6 validation, 7 network, 8 choose.
EOF
}

cmd=${1:-help}; [ $# -gt 0 ] && shift
sub=${1:-}
case "$sub" in --*|'') sub='' ;; *) shift ;; esac
parse "$@"

case "$cmd" in
  help|--help|-h) help ;;
  --version) echo "$IO_SH_VERSION" ;;
  login|signup)
    email=$(f email); email=${email:-${IO_EMAIL:-}}
    case "$sub" in
      start)
        [ -n "$email" ] || usage 'login start --email <address>'
        body="{\"email\":$(jstr "$email")"
        [ -n "$(f name)" ] && body+=",\"agent_name\":$(jstr "$(f name)")"
        [ -n "$(f operator_url)" ] && body+=",\"operator_url\":$(jstr "$(f operator_url)")"
        [ -n "$(f purpose)" ] && body+=",\"purpose\":$(jstr "$(f purpose)")"
        echo 'Verifying this address subscribes it to the daily digest; "io unsubscribe --what digest --yes" stops it.' >&2
        req POST /agent/start "$body}" ;;
      verify)
        code=$(f code)
        [ -n "$email" ] && [[ $code =~ ^[0-9]{6}$ ]] || usage 'login verify --email <address> --code <6 digits>'
        body="{\"email\":$(jstr "$email"),\"code\":\"$code\""
        [ -n "$(f label)" ] && body+=",\"token_label\":$(jstr "$(f label)")"
        out=$(req POST /agent/verify "$body}") || exit $?
        tok=$(printf '%s' "$out" | grep -o '"token" *: *"ioa_[A-Za-z0-9_-]*"' | head -1 | sed 's/.*"\(ioa_[^"]*\)"/\1/')
        if [ -n "$tok" ]; then
          (umask 077; mkdir -p "$CONF"; printf '%s\n' "$tok" > "$TOKEN_FILE"); chmod 600 "$TOKEN_FILE"
          echo "io: token stored in $TOKEN_FILE (0600)" >&2
        fi
        printf '%s\n' "$out" ;;
      *) usage 'login start | login verify' ;;
    esac ;;
  me|whoami) req GET /agent/me '' auth ;;
  digest)
    d=$(f date); [ -z "$d" ] && [[ $sub =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && d=$sub
    if [ -n "$d" ]; then [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage '--date is YYYY-MM-DD'; req GET "/agent/digest/$d" '' auth
    else req GET /agent/digest/latest '' auth; fi ;;
  briefs)
    q="?limit=$(f limit)"; [ -z "$(f limit)" ] && q='?limit=10'
    [[ ${q#?limit=} =~ ^[0-9]+$ ]] || usage '--limit is a number'
    [ -n "$(f since)" ] && q+="&since=$(f since)"
    req GET "/briefs$q" ;;
  brief) [[ $sub =~ ^[0-9]+$ ]] || usage 'brief <id> (the CLI also takes URLs)'; req GET "/brief/$sub" ;;
  topics)
    case "$sub" in
      ''|list) req GET /agent/topics '' auth ;;
      follow)
        tier=$(f tier); tier=${tier:-daily}
        [[ $tier == instant || $tier == daily ]] || usage '--tier is instant or daily'
        if [ -n "$(f key)" ]; then body="{\"key\":$(jstr "$(f key)"),\"tier\":\"$tier\"}"
        elif [ ${#POS[@]} -gt 0 ]; then body="{\"text\":$(jstr "${POS[*]}"),\"tier\":\"$tier\"}"
        else usage 'topics follow <text> | --key K'; fi
        req POST /agent/topics "$body" auth ;;
      unfollow) [[ ${POS[0]:-} =~ ^[0-9]+$ ]] || usage 'topics unfollow <topic_id>'; req DELETE "/agent/topics/${POS[0]}" '' auth ;;
      *) usage 'topics list | follow | unfollow' ;;
    esac ;;
  breaking)
    case "$sub" in
      ''|status) req GET /agent/preferences '' auth ;;
      set)
        b=''
        if [ -n "$(f threshold)" ]; then [[ $(f threshold) =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die 6 '--threshold must be 0.0 to 1.0'; b+=",\"threshold\":$(f threshold)"; fi
        if [ -n "$(f composite)" ]; then [[ $(f composite) =~ ^(min|mean|geo|breaking)$ ]] || usage '--composite is min, mean, geo or breaking'; b+=",\"composite\":\"$(f composite)\""; fi
        if [ -n "$(f max_per_day)" ]; then [[ $(f max_per_day) =~ ^([1-9]|1[0-9]|20)$ ]] || die 6 '--max-per-day must be 1 to 20'; b+=",\"max_per_day\":$(f max_per_day)"; fi
        [ -n "$(f on)" ] && b+=',"on":true'
        [ -n "$(f off)" ] && b+=',"on":false'
        [ -n "$b" ] || usage 'breaking set [--threshold 0.4] [--composite mean] [--max-per-day 3] [--on|--off]'
        req PATCH /agent/preferences "{\"breaking\":{${b#,}}}" auth ;;
      recent) days=$(f days); days=${days:-7}; [[ $days =~ ^[1-7]$ ]] || usage '--days is 1 to 7'; req GET "/agent/breaking/recent?days=$days" '' auth ;;
      show) [[ ${POS[0]:-} =~ ^[0-9]+$ ]] || usage 'breaking show <event_id>'; req GET "/agent/breaking/${POS[0]}" '' auth ;;
      *) usage 'breaking status | set | recent | show' ;;
    esac ;;
  prefs)
    case "$sub" in
      ''|get) req GET /agent/preferences '' auth ;;
      set)
        d=''
        if [ -n "$(f format)" ]; then [[ $(f format) =~ ^(text|json|html)$ ]] || usage '--format is text, json or html'; d+=",\"format\":\"$(f format)\""; fi
        if [ -n "$(f hour)" ]; then [[ $(f hour) =~ ^(7|12|18|21)$ ]] || die 6 '--hour must be 7, 12, 18 or 21'; d+=",\"hour_local\":$(f hour)"; fi
        [ -n "$(f tz)" ] && d+=",\"tz\":$(jstr "$(f tz)")"
        [ -n "$d" ] || usage 'prefs set [--format text|json|html] [--hour 7|12|18|21] [--tz Zone]'
        req PATCH /agent/preferences "{\"digest\":{${d#,}}}" auth ;;
      *) usage 'prefs get | set' ;;
    esac ;;
  unsubscribe)
    what=$(f what); what=${what:-$sub}
    [[ $what =~ ^(digest|breaking|topics|all)$ ]] || usage 'unsubscribe --what digest|breaking|topics|all --yes'
    [ -n "$(f yes)" ] || usage 'unsubscribe: add --yes to confirm'
    req POST /agent/unsubscribe "{\"what\":\"$what\"}" auth ;;
  token|tokens)
    case "$sub" in
      ''|list) req GET /agent/tokens '' auth ;;
      revoke) [[ ${POS[0]:-} =~ ^[A-Za-z0-9]+$ ]] || usage 'token revoke <id> --yes'; [ -n "$(f yes)" ] || usage 'token revoke: add --yes to confirm'; req DELETE "/agent/tokens/${POS[0]}" '' auth ;;
      *) usage 'token list | revoke' ;;
    esac ;;
  *) usage "unknown command \"$cmd\"; run io help" ;;
esac
