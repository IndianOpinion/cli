#!/usr/bin/env bash
# io.sh: Indian Opinion from bash and curl (jq optional). The same commands,
# flags, exit codes, IO_TOKEN and token file as the indianopinion CLI, minus
# the MCP bridge and skill install.
#   mkdir -p ~/bin && curl -fsSL https://indianopinion.org/agents/cli/io.sh -o ~/bin/io && chmod +x ~/bin/io
#   ~/bin/io login start --email you@yourdomain.example     (or put ~/bin on PATH and run io)
#   ~/bin/io login verify --email you@yourdomain.example --code 123456
#   ~/bin/io digest | jq '.stories[] | {title, url}'
# Output: with jq installed, the same JSON as the indianopinion CLI (briefs as
# {ok, count, items, next_cursor} with post_id, summary and so on); without jq,
# the API's JSON unchanged. Flags that need reshaping (digest --limit, breaking
# recent --limit or --would-send, brief --include) need jq and say so.
# A flag a command does not take is a usage error (exit 2), never ignored.
# Exit codes: 0 ok, 1 unexpected, 2 usage, 3 auth, 4 not found, 5 rate
# limited, 6 validation, 7 network or server, 8 needs a choice.
# Guide: https://indianopinion.org/agents/
set -uo pipefail

IO_SH_VERSION=0.2.2
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/indianopinion"
TOKEN_FILE="$CONF/token"
UA="indianopinion-io.sh/$IO_SH_VERSION (+https://indianopinion.org/agents/)"
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
[ -n "${IO_SH_NO_JQ:-}" ] && HAVE_JQ=0   # tests: behave as if jq were absent

jstr() { # JSON string literal
  local s=$1 out='' c i
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}; if [[ $c < ' ' ]]; then out+=$(printf '\\u%04x' "'$c"); else out+=$c; fi; done
  printf '"%s"' "$out"
}

# die EXIT ERROR MESSAGE: JSON on stderr when stdout is not a terminal (as the CLI does), else text.
die() {
  if [ -t 1 ]; then echo "io: $3" >&2; else printf '{"ok":false,"error":%s,"message":%s}\n' "$(jstr "$2")" "$(jstr "$3")" >&2; fi
  exit "$1"
}
usage() { die 2 usage "$1"; }
needjq() { [ "$HAVE_JQ" = 1 ] || usage "$1 needs jq (https://jqlang.org/); without jq, io.sh prints the API's JSON unchanged"; }

token() {
  if [ -n "${F_token:-}" ]; then printf '%s' "$F_token"; return; fi
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

OUT=''
# call METHOD PATH [BODY] [auth] [query pairs name=value ...]: the API's body in $OUT.
# Query values are URL-encoded by curl (--data-urlencode), so "+05:30", "&" and spaces survive.
call() {
  local method=$1 path=$2 body=${3:-} auth=${4:-} tok out status code
  shift 4 2>/dev/null || shift $#
  local args=(-sS -o - -w '\n%{http_code}' -H 'Accept: application/json' -A "$UA")
  if [ $# -gt 0 ]; then
    args+=(-G)
    local kv; for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  else
    args+=(-X "$method")
  fi
  if [ -n "$auth" ]; then
    tok=$(token)
    [ -n "$tok" ] || die 3 missing_token 'no token: run "io login start --email <address>" then "io login verify", or set IO_TOKEN'
    args+=(-H "Authorization: Bearer $tok")
  fi
  [ -n "$body" ] && args+=(-X "$method" -H 'Content-Type: application/json' --data-binary "$body")
  out=$(curl "${args[@]}" "$API$path" 2>/dev/null) || die 7 network "could not reach $API"
  status=${out##*$'\n'}; out=${out%$'\n'*}
  code=$(exit_for "$status" "$out")
  if [ "$code" != 0 ]; then printf '%s\n' "$out" >&2; exit "$code"; fi
  OUT=$out
}

emit() { # print JSON (pretty on a terminal when jq is there)
  if [ -t 1 ] && [ "$HAVE_JQ" = 1 ]; then printf '%s\n' "$1" | jq .; else printf '%s\n' "$1"; fi
}

# jq programs that give the CLI's shapes.
JQ_SENT='def sentences: ((. // "") | gsub("\\s+"; " ") | gsub("^ +| +$"; "")) as $t | ([$t | scan("[^.!?]+[.!?]+(?:\\s|$)")] | .[0:2] | join("") | gsub("^\\s+|\\s+$"; "")) as $s | (if $s == "" then $t else $s end) | if length > 400 then .[0:399] | sub("\\s+\\S*$"; "") + "..." else . end;'
JQ_COMPACT="$JQ_SENT"' def framing: reduce (.[]? | select(.stance) | .stance) as $k ({}; .[$k] += 1);
  def compact($api): {post_id: .id, title, url, md_url: (.md // null), json_url: "\($api)/brief/\(.id)", published, category: .section,
    outlets_count: (.corroboration // ((.sources // []) | length)), framing: ((.stances // []) | framing), summary: (.brief | sentences)};'

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }
unb64url() { local s; s=$(printf '%s' "$1" | tr -- '-_' '+/'); while [ $(( ${#s} % 4 )) != 0 ]; do s+='='; done; printf '%s' "$s" | base64 -d 2>/dev/null; }

ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,9})?)?)?([Zz]|[+-][0-9]{2}:?[0-9]{2})?$'
isotime() { # validate --since/--until (exit 6, like the CLI)
  [[ $2 =~ $ISO_RE ]] || die 6 invalid_field "--$1 must be an ISO 8601 time such as 2026-10-02T00:00:00Z, or a date such as 2026-10-02; got \"$2\""
}

# Parse --flag value pairs into F_<name> (dashes become underscores); SEEN lists the flags given.
POS=(); SEEN=()
parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) F_help=1 ;;
      --yes|--on|--off|--would-send|--json|--print) local k=${1#--}; SEEN+=("$k"); k=${k//-/_}; printf -v "F_$k" '%s' 1 ;;
      --text) usage 'io.sh prints JSON only (pipe it to jq for text)' ;;
      --*=*) local k=${1%%=*}; k=${k#--}; SEEN+=("$k"); k=${k//-/_}; printf -v "F_$k" '%s' "${1#*=}" ;;
      --*) local k=${1#--}; SEEN+=("$k"); k=${k//-/_}; [ $# -ge 2 ] && [[ $2 != --* ]] || usage "$1 needs a value"; printf -v "F_$k" '%s' "$2"; shift ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
}
f() { local v="F_$1"; printf '%s' "${!v:-}"; }
# allow "CMD" MAXPOS flag...: refuse any other flag (exit 2) and more positional words than MAXPOS.
allow() {
  local cmdname=$1 maxpos=$2 k ok a; shift 2
  for k in "${SEEN[@]+"${SEEN[@]}"}"; do
    ok=0
    for a in "$@" json token api; do [ "$k" = "$a" ] && ok=1; done
    [ $ok = 1 ] || usage "unknown flag --$k for \"$cmdname\"; it takes: $( [ $# -gt 0 ] && printf -- '--%s ' "$@" || printf 'no flags ')(and --json, --token, --api)"
  done
  [ "$maxpos" = any ] || [ ${#POS[@]} -le "$maxpos" ] || usage "\"$cmdname\" does not take \"${POS[*]:$maxpos}\""
}
limit_of() { # --limit N, 1 to 100, default $1
  local l; l=$(f limit); l=${l:-$1}
  [[ $l =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le 100 ] || usage '--limit must be a whole number from 1 to 100.'
  printf '%s' "$l"
}
onoff() { case "$2" in on|true) echo true ;; off|false) echo false ;; *) usage "--$1 takes on or off" ;; esac; }

help() {
  cat <<EOF
io.sh $IO_SH_VERSION: Indian Opinion from bash and curl. Guide: https://indianopinion.org/agents/
  io login start --email E [--name N --operator-url U --purpose P]
  io login verify --email E --code 123456 [--label L]     stores the token in $TOKEN_FILE (0600)
  io me
  io digest [--date YYYY-MM-DD] [--limit N]
  io briefs [--q Q] [--category C] [--since ISO] [--until ISO] [--limit N] [--cursor C]   (no account needed)
  io brief <url|id> [--include brief,analysis,coverage,sources]                         (no account needed)
  io topics list [--limit N] | follow <text> [--tier instant|daily] [--key K] [--id N] | unfollow <topic_id|name> [--key K] [--id N]
  io breaking status | set [--threshold 0.4] [--composite mean] [--max-per-day 3] [--on|--off] | recent [--days 7] [--limit N] [--would-send] [--cursor C] | show <event_id>
  io prefs get | set [--format text|json|html] [--hour 7|12|18|21] [--tz Asia/Kolkata] [--digest on|off] [--nudges on|off]
  io unsubscribe --what digest|breaking|topics|all --yes
  io account close --yes                                   tokens revoked, emails stopped (deactivation, not deletion)
  io token list | new [--label L] | revoke <id> --yes
  io browser-link
  io doctor
Global: --token T, --api URL, --json (JSON is the only output). Env: IO_TOKEN, IO_API, IO_EMAIL, XDG_CONFIG_HOME.
With jq the output matches the indianopinion CLI; without jq it is the API's JSON. A flag a command does not take is exit 2.
Exit codes: 0 ok, 2 usage, 3 auth, 4 not found, 5 rate limited, 6 validation, 7 network, 8 choose.
EOF
}

# No arguments: help on stdout and exit 2 (usage), as the Node CLI does (#24).
if [ $# -eq 0 ]; then help; exit 2; fi
cmd=$1; shift
sub=${1:-}
case "$sub" in --*|-h|'') sub='' ;; *) shift ;; esac
parse "$@"
# <command> --help shows the help and exits 0, as the Node CLI does (#18).
if [ -n "${F_help:-}" ]; then help; exit 0; fi
API="${F_api:-${IO_API:-https://indianopinion.org/wp-json/io/v1}}"
API="${API%/}"
SITE=$(printf '%s' "$API" | sed -E 's#^(https?://[^/]+).*#\1#')

case "$cmd" in
  help|--help|-h) help ;;
  --version|-V) echo "$IO_SH_VERSION" ;;
  login|signup)
    email=$(f email); email=${email:-${IO_EMAIL:-}}
    case "$sub" in
      start)
        allow 'login start' 0 email name operator-url purpose
        [ -n "$email" ] || usage 'login start --email <address>'
        body="{\"email\":$(jstr "$email")"
        [ -n "$(f name)" ] && body+=",\"agent_name\":$(jstr "$(f name)")"
        [ -n "$(f operator_url)" ] && body+=",\"operator_url\":$(jstr "$(f operator_url)")"
        [ -n "$(f purpose)" ] && body+=",\"purpose\":$(jstr "$(f purpose)")"
        echo 'Verifying a new address switches on the daily digest and Breaking News (up to 5 a day); "io unsubscribe --what all --yes" stops both.' >&2
        call POST /agent/start "$body}" ''
        # Name the io command as the next step, not the REST call (#19).
        verify="io login verify --email $email --code <6 digits>"
        if [ "$HAVE_JQ" = 1 ]; then OUT=$(printf '%s' "$OUT" | jq -c --arg v "$verify" '. + {message: ("A 6-digit code is on its way to that address. Read it from the mailbox, then run: " + $v), next: [{rel: "verify", command: $v}], unsubscribe: "io unsubscribe --what all --yes"}'); fi
        echo "io: next, run: $verify" >&2
        emit "$OUT" ;;
      verify)
        allow 'login verify' 0 email code label
        code=$(f code)
        [ -n "$email" ] && [[ $code =~ ^[0-9]{6}$ ]] || usage 'login verify --email <address> --code <6 digits>'
        body="{\"email\":$(jstr "$email"),\"code\":\"$code\""
        [ -n "$(f label)" ] && body+=",\"token_label\":$(jstr "$(f label)")"
        call POST /agent/verify "$body}" ''
        tok=$(printf '%s' "$OUT" | grep -o '"token" *: *"ioa_[A-Za-z0-9_-]*"' | head -1 | sed 's/.*"\(ioa_[^"]*\)"/\1/')
        if [ -n "$tok" ]; then
          (umask 077; mkdir -p "$CONF"; printf '%s\n' "$tok" > "$TOKEN_FILE"); chmod 600 "$TOKEN_FILE"
          echo "io: token stored in $TOKEN_FILE (0600)" >&2
          if [ "$HAVE_JQ" = 1 ]; then OUT=$(printf '%s' "$OUT" | jq -c --arg f "$TOKEN_FILE" '. + {token_file: $f}'); fi
        fi
        printf '%s\n' "$OUT" ;;
      *) usage 'login start | login verify' ;;
    esac ;;
  me|whoami) allow me 0; [ -z "$sub" ] || usage "\"me\" does not take \"$sub\""; call GET /agent/me '' auth; emit "$OUT" ;;
  digest)
    allow digest 0 date limit
    d=$(f date); [ -z "$d" ] && [ -n "$sub" ] && d=$sub
    if [ -n "$d" ]; then [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage '--date is YYYY-MM-DD.'; call GET "/agent/digest/$d" '' auth
    else call GET /agent/digest/latest '' auth; fi
    if [ -n "$(f limit)" ]; then needjq 'digest --limit'; l=$(limit_of 10); OUT=$(printf '%s' "$OUT" | jq -c --argjson n "$l" '.stories = ((.stories // [])[0:$n])'); fi
    emit "$OUT" ;;
  briefs)
    allow briefs 0 q category since until limit cursor
    [ -z "$sub" ] || usage "\"briefs\" does not take \"$sub\""
    l=$(limit_of 10)
    q=$(f q); c=$(f category); s=$(f since); u=$(f until); cur=$(f cursor); n=''
    [ -n "$s" ] && isotime since "$s"
    [ -n "$u" ] && isotime until "$u"
    if [ -n "$cur" ]; then
      j=$(unb64url "$cur")
      [ -n "$j" ] || usage 'That --cursor is not one this CLI or the API printed.'
      if printf '%s' "$j" | grep -q '"n"'; then
        needjq 'a cursor printed by the CLI'
        n=$(printf '%s' "$j" | jq -r '.n // empty'); q=$(printf '%s' "$j" | jq -r '.q // empty'); c=$(printf '%s' "$j" | jq -r '.c // empty')
        s=$(printf '%s' "$j" | jq -r '.s // empty'); u=$(printf '%s' "$j" | jq -r '.u // empty')
      else n=$cur; fi
    fi
    args=("limit=$l"); [ -n "$q" ] && args+=("q=$q"); [ -n "$c" ] && args+=("category=$c"); [ -n "$s" ] && args+=("since=$s"); [ -n "$u" ] && args+=("until=$u"); [ -n "$n" ] && args+=("cursor=$n")
    call GET /briefs '' '' "${args[@]}"
    if [ "$HAVE_JQ" = 1 ]; then
      OUT=$(printf '%s' "$OUT" | jq -c --arg api "$API" --arg q "$q" --arg c "$c" --arg s "$s" --arg u "$u" "$JQ_COMPACT"'
        {ok: true, count: ((.items // []) | length), items: [(.items // [])[] | compact($api)],
         next_cursor: (if .next_cursor then ({n: .next_cursor} + (if $q != "" then {q: $q} else {} end) + (if $c != "" then {c: $c} else {} end)
           + (if $s != "" then {s: $s} else {} end) + (if $u != "" then {u: $u} else {} end) | tojson | @base64 | gsub("="; "") | gsub("\\+"; "-") | gsub("/"; "_")) else null end)}')
    fi
    emit "$OUT" ;;
  brief)
    allow brief 0 include
    v=$sub; [ -n "$v" ] || usage 'brief <url|id>'
    inc=$(f include)
    if [ -n "$inc" ]; then
      [[ $inc =~ ^(brief|analysis|coverage|sources)(,(brief|analysis|coverage|sources))*$ ]] || die 6 invalid_field "--include takes a comma-separated list of brief, analysis, coverage, sources; got \"$inc\""
      needjq 'brief --include'
    fi
    if [[ $v =~ ^[0-9]+$ ]]; then id=$v
    else
      [[ $v =~ ^https?://([^/]+)(/[^?#]*)? ]] || usage 'brief takes a post id or an indianopinion.org URL.'
      host=${BASH_REMATCH[1]#www.}; path=${BASH_REMATCH[2]:-/}
      [ "$host" = "$(printf '%s' "$SITE" | sed -E 's#^https?://(www\.)?##')" ] || die 6 other_site "brief only reads ${SITE#*://} articles."
      if [[ $path =~ /wp-json/io/v1/brief/([0-9]+) ]]; then id=${BASH_REMATCH[1]}
      else
        path=${path%.md}; [[ $path == */ ]] || path+=/
        page=$(curl -sS -A "$UA" -H 'Accept: text/html' -w '\n%{http_code}' "$SITE$path" 2>/dev/null) || die 7 network "could not reach $SITE"
        st=${page##*$'\n'}; [ "$st" = 404 ] && die 4 not_found 'No such page.'
        id=$(printf '%s' "$page" | grep -o '/wp-json/io/v1/brief/[0-9]*' | head -1 | sed 's#.*/##')
        [ -n "$id" ] || die 4 not_found 'That page is not a published brief.'
      fi
    fi
    call GET "/brief/$id" '' ''
    if [ -n "$inc" ]; then
      OUT=$(printf '%s' "$OUT" | jq -c --arg inc "$inc" '($inc | split(",")) as $i | if ($i | index("analysis")) then . else del(.analysis) end
        | if ($i | index("brief")) then . else del(.brief) end | if ($i | index("sources")) then . else del(.sources) end
        | if ($i | index("coverage")) then . else del(.stances) end')
    fi
    emit "$OUT" ;;
  topics)
    case "$sub" in
      ''|list) allow 'topics list' 0 limit; call GET /agent/topics '' auth
        if [ "$HAVE_JQ" = 1 ]; then l=$(limit_of 10); OUT=$(printf '%s' "$OUT" | jq -c --argjson n "$l" '.suggested = ((.suggested // [])[0:$n])'); fi
        emit "$OUT" ;;
      follow)
        allow 'topics follow' any key id tier
        tier=$(f tier); tier=${tier:-daily}
        [[ $tier == instant || $tier == daily ]] || usage '--tier is instant or daily.'
        if [ -n "$(f key)" ]; then body="{\"key\":$(jstr "$(f key)"),\"tier\":\"$tier\"}"
        elif [ -n "$(f id)" ]; then [[ $(f id) =~ ^[0-9]+$ ]] || usage '--id is a topic id'; body="{\"topic_id\":$(f id),\"tier\":\"$tier\"}"
        elif [ ${#POS[@]} -gt 0 ]; then body="{\"text\":$(jstr "${POS[*]}"),\"tier\":\"$tier\"}"
        else usage 'topics follow <text> | --key K | --id N [--tier instant|daily]'; fi
        call POST /agent/topics "$body" auth; emit "$OUT" ;;
      unfollow)
        # Takes what follow takes: a topic_id, --id, --key or the name; a key or name needs jq (#20).
        allow 'topics unfollow' any key id
        want=$(f id); [ -n "$want" ] || want=$(f key); [ -n "$want" ] || want="${POS[*]:-}"
        [ -n "$want" ] || usage 'topics unfollow <topic_id | name> | --key K | --id N'
        [ ${#POS[@]} -gt 1 ] && [[ ${POS[0]} =~ ^[0-9]+$ ]] && usage 'topics unfollow takes one topic_id'
        if [[ $want =~ ^[0-9]+$ ]] && [ -z "$(f key)" ]; then tid=$want
        else
          [ "$HAVE_JQ" = 1 ] || usage 'topics unfollow by name or key needs jq; pass the numeric topic_id (io topics list shows it)'
          call GET /agent/topics '' auth
          tid=$(printf '%s' "$OUT" | jq -r --arg w "$want" '($w|ascii_downcase) as $w | [((.following // []) + (.suggested // []))[] | select(.topic_id != null and (((.key // "")|ascii_downcase) == $w or ((.name // "")|ascii_downcase) == $w))][0].topic_id // empty')
          [ -n "$tid" ] || die 4 not_found "No followed topic matches \"$want\". Run io topics list for topic ids."
        fi
        call DELETE "/agent/topics/$tid" '' auth; emit "$OUT" ;;
      *) usage 'topics list | follow | unfollow' ;;
    esac ;;
  breaking)
    case "$sub" in
      ''|status)
        allow 'breaking status' 0
        call GET /agent/me '' auth
        if [ "$HAVE_JQ" = 1 ]; then OUT=$(printf '%s' "$OUT" | jq -c '{ok: true, breaking: (.preferences.breaking // null), sent_last_24h: (.breaking_today.sent_last_24h // null)}'); fi
        emit "$OUT" ;;
      set)
        allow 'breaking set' 0 threshold composite max-per-day on off
        b=''
        if [ -n "$(f threshold)" ]; then [[ $(f threshold) =~ ^(0(\.[0-9]+)?|1(\.0+)?|\.[0-9]+)$ ]] || die 6 invalid_preference "--threshold must be 0.0 to 1.0; got $(f threshold)."; t=$(f threshold); [[ $t == .* ]] && t="0$t"; b+=",\"threshold\":$t"; fi
        if [ -n "$(f composite)" ]; then [[ $(f composite) =~ ^(min|mean|geo|breaking)$ ]] || usage '--composite is min, mean, geo or breaking.'; b+=",\"composite\":\"$(f composite)\""; fi
        if [ -n "$(f max_per_day)" ]; then [[ $(f max_per_day) =~ ^([1-9]|1[0-9]|20)$ ]] || die 6 invalid_preference '--max-per-day must be 1 to 20.'; b+=",\"max_per_day\":$(f max_per_day)"; fi
        [ -n "$(f on)" ] && b+=',"on":true'
        [ -n "$(f off)" ] && b+=',"on":false'
        [ -n "$b" ] || usage 'breaking set [--threshold 0.4] [--composite mean] [--max-per-day 3] [--on|--off]'
        call PATCH /agent/preferences "{\"breaking\":{${b#,}}}" auth; emit "$OUT" ;;
      recent)
        allow 'breaking recent' 0 days limit would-send cursor
        days=$(f days); days=${days:-7}; [[ $days =~ ^[1-7]$ ]] || die 6 invalid_field '--days must be 1 to 7.'
        args=("days=$days"); [ -n "$(f cursor)" ] && args+=("cursor=$(f cursor)")
        call GET /agent/breaking/recent '' auth "${args[@]}"
        if [ -n "$(f limit)$(f would_send)" ]; then needjq 'breaking recent --limit/--would-send'; fi
        if [ "$HAVE_JQ" = 1 ]; then
          l=$(limit_of 25)
          OUT=$(printf '%s' "$OUT" | jq -c --argjson n "$l" --arg w "$(f would_send)" '.events = ([(.events // [])[] | select($w == "" or .would_send)][0:$n])')
        fi
        emit "$OUT" ;;
      show) allow 'breaking show' 1; [[ ${POS[0]:-} =~ ^[0-9]+$ ]] || usage 'breaking show <event_id>'; call GET "/agent/breaking/${POS[0]}" '' auth; emit "$OUT" ;;
      *) usage 'breaking status | set | recent | show' ;;
    esac ;;
  prefs)
    case "$sub" in
      ''|get) allow 'prefs get' 0; call GET /agent/preferences '' auth; emit "$OUT" ;;
      set)
        allow 'prefs set' 0 format hour tz digest nudges
        d=''; body=''
        if [ -n "$(f format)" ]; then [[ $(f format) =~ ^(text|json|html)$ ]] || usage '--format is text, json or html.'; d+=",\"format\":\"$(f format)\""; fi
        if [ -n "$(f hour)" ]; then [[ $(f hour) =~ ^(7|12|18|21)$ ]] || die 6 invalid_preference '--hour must be 7, 12, 18 or 21.'; d+=",\"hour_local\":$(f hour)"; fi
        [ -n "$(f tz)" ] && d+=",\"tz\":$(jstr "$(f tz)")"
        [ -n "$(f digest)" ] && d+=",\"on\":$(onoff digest "$(f digest)")"
        [ -n "$d" ] && body+=",\"digest\":{${d#,}}"
        [ -n "$(f nudges)" ] && body+=",\"nudges\":$(onoff nudges "$(f nudges)")"
        [ -n "$body" ] || usage 'prefs set [--format text|json|html] [--hour 7|12|18|21] [--tz Zone] [--digest on|off] [--nudges on|off]'
        call PATCH /agent/preferences "{${body#,}}" auth; emit "$OUT" ;;
      *) usage 'prefs get | set' ;;
    esac ;;
  unsubscribe|unsub)
    allow unsubscribe 0 what yes
    what=$(f what); what=${what:-$sub}
    [[ $what =~ ^(digest|breaking|topics|all)$ ]] || usage 'unsubscribe --what digest|breaking|topics|all --yes'
    [ -n "$(f yes)" ] || die 2 confirm 'unsubscribe: add --yes to confirm (never prompted, so agents and scripts behave the same).'
    call POST /agent/unsubscribe "{\"what\":\"$what\"}" auth; emit "$OUT" ;;
  account)
    [ "$sub" = close ] || usage 'account close --yes'
    allow 'account close' 0 yes
    [ -n "$(f yes)" ] || die 2 confirm 'account close (revokes every token, stops every email and disables sign-in; deactivation, not deletion): add --yes to confirm.'
    call POST /agent/close '{"confirm":true}' auth; emit "$OUT" ;;
  token|tokens)
    case "$sub" in
      ''|list) allow 'token list' 0; call GET /agent/tokens '' auth; emit "$OUT" ;;
      new) allow 'token new' 0 label; if [ -n "$(f label)" ]; then body="{\"label\":$(jstr "$(f label)")}"; else body='{}'; fi; call POST /agent/tokens "$body" auth; emit "$OUT" ;;
      revoke) allow 'token revoke' 1 yes; [[ ${POS[0]:-} =~ ^[A-Za-z0-9]+$ ]] || usage 'token revoke <token_id> --yes'; [ -n "$(f yes)" ] || die 2 confirm 'token revoke: add --yes to confirm.'; call DELETE "/agent/tokens/${POS[0]}" '' auth; emit "$OUT" ;;
      *) usage 'token list | new | revoke' ;;
    esac ;;
  browser-link) allow browser-link 0; call POST /agent/browser-link '' auth; emit "$OUT" ;;
  doctor)
    allow doctor 0
    checks=(); okall=true
    add() { checks+=("{\"name\":$(jstr "$1"),\"ok\":$2,\"detail\":$(jstr "$3")}"); [ "$2" = true ] || okall=false; }
    add bash true "$BASH_VERSION"
    add jq true "$( [ "$HAVE_JQ" = 1 ] && echo 'found: output matches the CLI' || echo 'not found: output is the API JSON' )"
    # No token is the normal first-run state: reported, not a failure (#22).
    t=$(token); if [ -n "$t" ]; then add token true "$(printf '%s' "$t" | cut -d_ -f2)"; else checks+=('{"name":"token","ok":false,"required":false,"detail":"none (not signed in); run io login start --email <address>"}'); fi
    if r=$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" "$API/briefs?limit=1" 2>/dev/null) && [ "$r" = 200 ]; then add 'public api' true "$API"; else add 'public api' false "HTTP ${r:-000} from $API/briefs"; fi
    if r=$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" "$API/agent" 2>/dev/null) && [ "$r" = 200 ]; then add 'agent api' true answering; else add 'agent api' false "HTTP ${r:-000}"; fi
    if [ -n "$t" ]; then
      if r=$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" -H "Authorization: Bearer $t" "$API/agent/me" 2>/dev/null) && [ "$r" = 200 ]; then add 'token valid' true accepted; else add 'token valid' false "HTTP ${r:-000}"; fi
    fi
    latest=$(curl -sS -A "$UA" "$SITE/agents/cli/latest.json" 2>/dev/null | grep -o '"version" *: *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [ -z "$latest" ]; then add version true "this $IO_SH_VERSION (latest.json unreachable)"
    elif [ "$(printf '%s\n%s\n' "$IO_SH_VERSION" "$latest" | sort -V | head -1)" = "$IO_SH_VERSION" ] && [ "$IO_SH_VERSION" != "$latest" ]; then add version false "this $IO_SH_VERSION, latest $latest: download io.sh again"
    else add version true "this $IO_SH_VERSION, latest $latest"; fi
    out="{\"ok\":$okall,\"signed_in\":$( [ -n "$t" ] && echo true || echo false ),\"checks\":[$(IFS=,; echo "${checks[*]}")]}"
    emit "$out"; [ "$okall" = true ] || exit 1 ;;
  *) usage "unknown command \"$cmd\"; run io help" ;;
esac
