#!/usr/bin/env shorthandzsh
alias furl='command curl -qgsf --compressed'
alias fie='furl -A "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv 11.0) like Gecko"'
alias fios='furl -A "Mozilla/5.0 (iPhone; CPU iPhone OS 14_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 EdgiOS/46.3.7 Mobile/15E148 Safari/605.1.15"'
builtin zmodload -Fa zsh/datetime p:EPOCHSECONDS b:strftime
builtin zmodload -Fa zsh/zutil b:zparseopts

function main {
  case "$1" in
    (s|syncdb)
      shift; syncdb "${(@)argv}" ;;
    (f|fetch-complement)
      shift; fetch-complement "${(@)argv}" ;;
    (g|get)
      shift; get "${(@)argv}" ;;
    (q|query)
      shift; query "${(@)argv}" ;;
    (rss|generate-atomxml)
      shift; generate-xml "${(@)argv}" ;;
    (srs)
      shift
      syncdb "${(@)argv}"
      generate-xml "${(@)argv}"
      ;;
    (*)
      "${(@)argv}"
      ;;
  esac
}

local -a +x b22_region_names=(cn kr jp)
local -A +x b22_valid_status_notations
b22_valid_status_notations=(
  end .
  ing '~'
  tba '?'
  err '!'
)
# $0 [-status [status[,status[,...]]]] [region [region[ ...]]]
function syncdb::b22 {
  local -A getopts
  #zparseopts -A getopts -D -F - status:
  local -aU syncdb_statuses=()
  if [[ -v getopts[-status] ]]; then
    syncdb_statuses=(${(s@,@)getopts[-status]})
    (( $#syncdb_statuses>0 ))
    [[ "${getopts[-status]}" != *:* ]]
  else
    syncdb_statuses=(end ing)
  fi
  local -aU syncdb_regions=("${(@)argv}")
  if (( $#syncdb_regions==0 )); then
    syncdb_regions=($b22_region_names)
  else
    [[ ${(@)syncdb_regions[(I)^(${(j.|.)b22_region_names})|]} == 0 ]]
  fi
  integer +x syncdb_startts=$EPOCHSECONDS
  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
    get:list::${0##*::} -region "${i%%:*}" -status "${i##*:}"
  done; unset i
  integer +x syncdb_endts=$EPOCHSECONDS

  local +x query_buf=
  local +x i=; for i in ${(@)^syncdb_regions}:{tba,err}; do
    local +x buf=
    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" 1 $((syncdb_startts - 1)) | readeof buf
    query_buf+=$buf; buf=
  done; unset i
  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" $syncdb_startts $syncdb_endts | readeof buf
    query_buf+=$buf
    unset buf
  done; unset i
  if [[ $#query_buf -gt 0 ]]; then
    get:item::${0#*::} -listbufstr $query_buf
  fi
}

function zstrwan {
  [[ $# == 1 ]]
  local +x bbuf=
  zstan "$1" | readeof bbuf
  if [[ $#bbuf -gt 0 ]]; then
    printj $bbuf | zstd | rw -a -- "$1"
  elif [[ -e "$1" ]]; then
    touch -- "$1"
  fi
}

function zstan {
  [[ $# == 1 ]]
  if [[ -e "$1" ]]; then
    anewer <(zstdcat -- "$1")
  else
    cat
  fi
}

function get:item::b22 {
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  zparseopts -A getopts -D -F - listbufstr: region:
  if (( $# == 0 )) && [[ -v getopts[-listbufstr] ]]; then
    local -a +x listbufs=(${(ps.\n.)getopts[-listbufstr]})
    [[ ${#listbufs} -gt 0 ]]
    local -a +x bufs=()
    while (( ${#listbufs} > 0 )); do
      local -a +x listbuf=(${listbufs[1]})
      listbuf=("${(@ps.\t.)listbuf[1]}")
      integer +x id=${listbuf[3]#b22:}; (( id > 0 ))
      local +x region=${listbuf[4]%%:*}; (( ${#region} > 0 ))
      printj $'\r'$0"($id): ${listbuf[4]} ~" >&2
      local -a +x buf=()
      if ! fetch:item::b22 $id | IFS= read -rA buf; then
        say $'\r'$0"($id): ${listbuf[4]} !" >&2
        return 1
      fi
      buf=("${(@ps.\t.)buf}")
      buf[11]="${region}:${buf[11]}"
      printj $'\r'$0"($id):${buf[11]} %" >&2
      bufs+=("${(@pj.\t.)buf}")
      unset buf
      if [[ $#bufs == 14 ]]; then
        printf '%s\n' ${(@)bufs} | zstrwan $listfile
        printj $'\b.' >&2
        bufs=()
        _delay_next $#
        say >&2
      fi
      shift listbufs
    done
    if [[ $#bufs -gt 0 ]]; then
      printf '%s\n' ${(@)bufs} | zstrwan $listfile
      say $'\b.' >&2
      bufs=()
    fi
  elif (( $# > 0 )) && [[ -v getopts[-region] ]] && ! [[ -v getopts[-listbufstr] ]] && [[ "${b22_region_names[(Ie)${getopts[-region]}]}" -gt 0 ]]; then
    local -a +x bufs=()
    while (( $# > 0 )); do
      local -a +x buf=()
      printj $0"($1): (${(q)getopts[-region]})" >&2
      if ! fetch:item::b22 $1 | IFS= read -rA buf; then
        say $'\r'$0"($1): (${(q)getopts[-region]}) !" >&2
        return 1
      fi
      buf=("${(@ps.\t.)buf}")
      printj $'\r'$0"($1):${buf[11]} (${getopts[-region]}) %" >&2
      buf[11]="${getopts[-region]}:${buf[11]}"
      bufs+=("${(@pj.\t.)buf}")
      unset buf
      if [[ $#bufs == 14 ]]; then
        printf '%s\n' ${(@)bufs} | zstrwan $listfile
        printj $'\b.' >&2
        bufs=()
        _delay_next $#
        say >&2
      fi
      shift
    done
    if [[ $#bufs -gt 0 ]]; then
      printf '%s\n' ${(@)bufs} | zstrwan $listfile
      say $'\b.' >&2
      bufs=()
    fi
  else
    return 128
  fi
}

function query:item::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - region: status: mints: maxts:
  if (( $# > 0 )); then
    (( ${argv[(I)^(0|<1-9>|<1-9><0->)|]} == 0 ))
  fi
  local -a +x patexps=('$10 ~ /^b22:[0-9]+$/' '$11 !~ /:_$/')
  patexps+=('! printed_ids[$10]++')
  local +x mints=${getopts[-mints]} maxts=${getopts[-maxts]}
  if [[ -v getopts[-mints] ]]; then
    [[ "$mints" == <1-> ]]
    mints=$((mints))
    patexps+=('($1>='$mints' || $15>='$mints')')
  fi; if [[ -v getopts[-maxts] ]]; then
    [[ "$maxts" == <1-> ]]
    maxts=$((maxts))
    if [[ -v getopts[-mints] ]]; then
      ((maxts>=mints))
    fi
    patexps+=('(($1>0 && $1<='$maxts') || ($15>0 && $15<='$maxts'))')
  fi
  local -aU +x regions=() statuses=()
  if [[ -v getopts[-region] ]]; then
    [[ ${#getopts[-region]} -gt 0 ]]
    regions=("${(@s.,.)getopts[-region]}")
    [[ ${#regions} -gt 0 ]]
    [[ ${regions[(I)^(${(j.|.)b22_region_names})|]} -eq 0 ]]
    [[ ${regions[(I)${(j.|.)b22_region_names}]} -gt 0 ]]
  fi
  if [[ -v getopts[-status] ]]; then
    [[ ${#getopts[-status]} -gt 0 ]]
    statuses=("${(@s:,:)getopts[-status]}")
    [[ ${#statuses} -gt 0 ]]
    [[ ${statuses[(I)^(${(kj.|.)b22_valid_status_notations})|]} -eq 0 ]]
    [[ ${statuses[(I)${(kj.|.)b22_valid_status_notations}]} -gt 0 ]]
  fi
  local -a +x actexps_status=() actexps=()
  local -a +x actexps_region=()
  if [[ $#statuses -gt 0 ]]; then
    local +x walk_status=; for walk_status in $statuses; do
      case $walk_status in
        (end)
          actexps_status+=('.');;
        (ing)
          actexps_status+=('~');;
        (tba)
          actexps_status+=('?');;
        (*)
          return 128;;
      esac
    done
    actexps+=('$11 ~ /:['${(@j..)actexps_status}'](:[-0-9.]+|)$/')
  fi
  if [[ $#regions -gt 0 ]]; then
    local +x walk_region=; for walk_region in $regions; do
      actexps_region+=($walk_region)
    done
    actexps+=('$11 ~ /^('${(@j.|.)actexps_region}'):/')
  fi
  if (( $# > 0 )); then
    actexps+=('$10 ~ /^'${0##*::}':('${(j.|.)argv}')$/')
  fi
  local +x awkprog=${(j. && .)patexps}
  if [[ $#actexps -gt 0 ]]; then
    awkprog+=" { if ( ${(j. && .)actexps} ) print }"
  fi
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  set -x
  zstdcat -- $listfile | grep -ve '^#' | tac | gawk -F $'\t' -f <(builtin printf %s $awkprog) | tac
}

function query:list::b22 {
  zparseopts -A getopts -D -F - region: status:; (($#<=2))
  local +x mints=$1 maxts=$2
  local -a +x patexps=('$3 ~ /^b22:[0-9]+$/' '$4 !~ /:_$/')
  patexps+=('! printed_ids[$3]++')
  if [[ -v 1 ]]; then
    [[ "$1" == <1-> ]]
    mints=$((mints))
    patexps+=('$1>='$mints)
  fi; if [[ -v 2 ]]; then
    [[ "$2" == <1-> ]]
    maxts=$((maxts))
    ((maxts>=mintts))
    patexps+=('$1<='$maxts)
  fi
  local -aU +x regions=() statuses=()
  if [[ -v getopts[-region] ]]; then
    [[ ${#getopts[-region]} -gt 0 ]]
    regions=("${(@s.,.)getopts[-region]}")
    [[ ${#regions} -gt 0 ]]
    [[ ${regions[(I)^(${(j.|.)b22_region_names})|]} -eq 0 ]]
    [[ ${regions[(I)${(j.|.)b22_region_names}]} -gt 0 ]]
  fi
  if [[ -v getopts[-status] ]]; then
    [[ ${#getopts[-status]} -gt 0 ]]
    statuses=("${(@s:,:)getopts[-status]}")
    [[ ${#statuses} -gt 0 ]]
    [[ ${statuses[(I)^(${(kj.|.)b22_valid_status_notations})|]} -eq 0 ]]
    [[ ${statuses[(I)${(kj.|.)b22_valid_status_notations}]} -gt 0 ]]
  fi
  local -a +x actexps_status=() actexps=()
  local -a +x actexps_region=()
  if [[ $#statuses -gt 0 ]]; then
    local +x walk_status=; for walk_status in $statuses; do
      case $walk_status in
        (end)
          actexps_status+=('.');;
        (ing)
          actexps_status+=('~');;
        (tba)
          actexps_status+=('?');;
        (err)
          actexps_status+=('!');;
        (*)
          return 128;;
      esac
    done
    actexps+=('$4 ~ /:['${(@j..)actexps_status}']$/')
  fi
  if [[ $#regions -gt 0 ]]; then
    local +x walk_region=; for walk_region in $regions; do
      actexps_region+=($walk_region)
    done
    actexps+=('$4 ~ /^('${(@j.|.)actexps_region}'):/')
  fi
  local +x awkprog=${(j. && .)patexps}
  if [[ $#actexps -gt 0 ]]; then
    awkprog+=" { if ( ${(j. && .)actexps} ) print }"
  fi
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  zstdcat -- $listfile | grep -ve '^#' | tac | gawk -F $'\t' $awkprog | tac
}

function get:list::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - maxpn: region: status:; (( $# <= 1 ))
  integer +x startpn=${1:-1} maxpn=${getopts[-maxpn]:--1}
  (( startpn>0 )); (( maxpn>=startpn||maxpn<0 ))
  integer +x pn=$startpn
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  while ((pn<=maxpn||maxpn<0)); do
    local +x listresp=
    printj $0"($pn):? (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
    fetch:list::b22 -region "${getopts[-region]}" -status "${getopts[-status]}" $pn | readeof listresp
    if (( $#listresp==0 )); then if (( pn>1 )); then
      say $'\r'$0"($pn):EOF (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
      break
    else
      say $'\r'$0"($pn):! (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
      return 1
    fi; fi
    if [[ -r "$listfile" && -f "$listfile" && -s "$listfile" ]]; then
      integer +x listresp_ts="${listresp%%	*}"; (( listresp_ts>0 ))
      local +x listresp_tbw=
      ## orig: printj $listresp | cut -f 2-
      printj "${(@pj.\n.)${(@)${(@ps.\n.)listresp}#*	}}" | anewer <(zstdcat -- $listfile | grep -ve '^#' | cut -f 2-) | readeof listresp_tbw
      if (( ${#listresp_tbw} > 1 )); then
        printj $'\r'$0"($pn):>>" >&2
        ## orig: printj $listresp_tbw | sed -e '/..*/s%^%'$listresp_ts'%'
        printf '%s\n' ${listresp_ts}$'\t'${(@)^${(@ps.\n.)listresp_tbw}} | zstd | rw -a -- $listfile
      else
        say $'\r'$0"($pn):>< (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
        break
      fi
    else
      printj $'\r'$0"($pn):> " >&2
      printj $listresp | zstd | rw -- $listfile
    fi
    printj ". (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
    pn+=1
    say >&2
  done
}

function _delay_next {
  [[ -v pn ]] || local +x pn=$1
  if [[ -z "$nowait" ]] && ((pn<=maxpn||maxpn<=0)); then
    if (( pn%$((RANDOM%4+1)) == 0 )); then
      integer +x sleepint=$((5+RANDOM%15))
    else
      integer +x sleepint=$((RANDOM%5))
    fi
    if ((sleepint>0)); then
      printj " sleep($sleepint)" >&2
      delay $sleepint
      local +x erase_sleepprompt=
      repeat 9+$#sleepint {
        erase_sleepprompt+=$'\b'
      }
      repeat 9+$#sleepint {
        erase_sleepprompt+=' '
      }
      printj $erase_sleepprompt>&2
      unset erase_sleepprompt
    fi
    unset sleepint
  fi
}

local -a +x curl_hdr_flag_arrplh=(-H)

local -a +x b22_restapi_http_hdr=(
  'accept: application/json, text/plain, */*'
  'content-type: application/json;charset=UTF-8'
)
b22_restapi_http_hdr=(${curl_hdr_flag_arrplh:^^b22_restapi_http_hdr})
source "${ZSH_ARGZERO%/*}/mangarss.zsh.inc"
function fetch:item::b22 {
  integer +x id=$1; (( $# == 1 && id > 0 ))
  local +x jsonresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fios $b22_restapi_http_hdr -H 'referer: https://manga.bilibili.com/detail/mc'$id \
    --data-raw '{"comic_id":'$id'}' \
    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ComicDetail?device=pc&platform=web' | readeof jsonresp
  integer +x ts=$EPOCHSECONDS
  printj $jsonresp | pipeok gojq -r --arg ts "$ts" --arg fn_name "$0" --arg id "$id" --arg excluded_chapti_regex "(${(j:|:)excluded_chapti_regex})" -f <(builtin printf %s 'def resp_ok: if has("data") and has("code") and (.code==0) then
  .data
else
  $fn_name+"("+$id+"): REST API - response error\n" | halt_error
end;

def sanitstr: if ((type)=="string") then . else
  if ((type)=="null") then "" else
    tostring
  end
end|gsub("\\\\";"\\\\")|gsub("\n"; "\\n")|gsub("\t";"\\t")|gsub("\u000b";"");

def item_ok: if (length>0
  and has("title") and (.title|length>0) and has("introduction")
  and has("author_name")
  and has("ep_list") and has("last_ord") and has("is_finish")
  and has("vertical_cover") and has("horizontal_cover") and has("square_cover") and has("chapters")
  and has("evaluate") and has("styles") and has("tags")
  and has("comic_type")
  and has("type")) then .
else
  $fn_name+"("+$id+"): REST API - null or irregular response\n" | halt_error
end;

def filter_valid_chaps: select((.ord>=1) and ((.title | test($excluded_chapti_regex; "")) or (.short_title | test($excluded_chapti_regex; "")) | not));

def recheck_ts_status: if (.is_finish==-1) or (.ep_list|length==0) or (.is_finish == 0 and ([.ep_list[] | filter_valid_chaps] | length==0)) then
  .is_finish = -1 | .__secondary_ts = null | if ((.release_time|length>=8)
     and (.release_time|length<=10)
     and (.release_time+" +0800"|strptime("%Y.%m.%d %z")|mktime))
  then
    .__major_ts = (.release_time+" +0800" | strptime("%Y.%m.%d %z") | mktime)
  else
    if (.ep_list|length>0) then
      .__major_ts = (.ep_list | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
    else
      .__major_ts = null
    end
  end
else
  if (.is_finish==0) then
    .__major_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = null
  else
    if (.is_finish==1) then
      if ([.ep_list[] | filter_valid_chaps]|length>0) then
        .__major_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[-100:] | sort_by(.pub_time) | .[-1] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
      else
        .__major_ts = (.ep_list | sort_by(.ord) | .[-100:] | sort_by(.pub_time) | .[-1] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = (.ep_list | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
      end
    else
      $fn_name+"("+$id+"): unrecognised value on is_finish field.\n" | halt_error
    end
  end
end;

def check_redundant_intro: if ((.introduction|length>0)
   and ((.title == .introduction)
     or ((.evaluate|length>0) and (.introduction as $string | .evaluate | contains($string)))))
  then
    .introduction = ""
else
  .
end;

resp_ok | item_ok | recheck_ts_status | check_redundant_intro | [
  (.__major_ts|sanitstr),
  (.title|sanitstr),
  ([.author_name[]|sanitstr]|join("、")),
  (.introduction|sanitstr),
  (.evaluate|sanitstr),
  (.horizontal_cover),(.vertical_cover),(.square_cover),(if (.chapters|length>0) and ([.chapters[]|select(.cover|length>0)]|length>0) then
    [.chapters[]|select(.cover|length>0)]|sort_by(.ord)|[.[].cover]|unique|join("\u000b")
  else "" end),
  ("b22:"+$id),(if (.type==0) then
    if (.is_finish==-1) then
      "?"
    else
      if (.is_finish==1) then
        ".:"+(.last_ord|tostring)
      else
        "~:"+(.last_ord|tostring)
      end
    end
  else "_" end),
  (.comic_type|tostring)+(if has("is_star_hall") then ":"+(.is_star_hall|tostring) else "" end),
  (if (.styles|length>0) then
     [.styles[]|sanitstr]|join("、")
   else "" end),
  (if (.tags|length>0) then [.tags[]|.name|sanitstr]|join("、") else "" end),
  (.__secondary_ts|sanitstr)
]|join("\t")')
}

function fetch:list::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - region: status:
  integer +x b22_list_area_id=
  case "${getopts[-region]}" in
    (cn) b22_list_area_id=1;;
    (jp) b22_list_area_id=2;;
    (kr) b22_list_area_id=6;;
### (all) b22_list_area_id=-1;;
    (*) return 128;;
  esac
  integer +x b22_list_order= b22_list_is_finish=
  case "${getopts[-status]}" in
    (ing) b22_list_order=3; b22_list_is_finish=0;;
    (end) b22_list_order=1; b22_list_is_finish=1;;
    (all)      b22_list_order=3; b22_list_is_finish=-1;;
    (*) return 128;;
  esac
  (( # == 1 )); [[ "$1" == <1-> ]]; 1=$((argv[1]))
  local +x jsonresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $b22_restapi_http_hdr \
    -H "referer: https://manga.bilibili.com/classify?styles=-1&areas=$b22_list_area_id&status=$b22_list_is_finish&prices=-1&orders=$b22_list_order" \
    --data-raw '{"style_id":-1,"area_id":'$b22_list_area_id',"is_finish":'$b22_list_is_finish',"order":'$b22_list_order',"page_num":'$1',"page_size":18,"is_free":-1}' \
    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ClassPage?device=pc&platform=web' | readeof jsonresp
  integer +x ts=$EPOCHSECONDS
  # listts, title, id, region[:if_finish|vcomic], vc, hc, sc
  printj $jsonresp | pipeok gojq -r --arg ts "$ts" --arg fn_name "$0" --arg pn "$1" --arg region "${getopts[-region]}" --arg excluded_chapti_regex "(${(j:|:)excluded_chapti_regex})" -f <(builtin printf %s 'def listitem_ok: has("type") and has("season_id") and has("horizontal_cover") and has("vertical_cover") and has("square_cover") and has("last_ord") and has("is_finish") and has("title");
def sfesc: gsub("\n"; "")|gsub("\t"; " ");

def print_item(is_vcomic): if (is_vcomic==0) then
  [$ts,(.title|sfesc),"b22:"+(.season_id|tostring),$region+":"+(
    if (.is_finish==0) then
      if (.last_ord<1) then "!"
      else "~"
      end
    else
      if (.is_finish==-1) then "?"
      else
        if (.is_finish==1) then "."
        else
          $fn_name+"("+$pn+"): unrecognised is_finish value "+.is_finish+"\n" | halt_error
        end
      end
    end),(.vertical_cover|tostring),(.horizontal_cover|tostring),(.square_cover|tostring)]|join("\t")
else
  if (is_vcomic==1) then
    [$ts,(.title|sfesc),"b22:"+(.season_id|tostring),$region+":_",(.vertical_cover|tostring),(.horizontal_cover|tostring),(.square_cover|tostring)]|join("\t")
  else
    $fn_name+"("+$pn+"): REST API - unknown type: "+(.|tostring)+"\n" | halt_error
  end
end;

if (.code==0) and has("data") then
  if (.data|length>0) then
    .data[] | if listitem_ok then
      print_item(.type)
    else
      $fn_name+"("+$pn+"): REST API - item schema mismatch: "+(.|tostring)+"\n" | halt_error
    end
  else
    if ($pn==1) then
      $fn_name+"("+$pn+"): REST API - null response\n"|halt_error
    else
      halt
    end
  end
else
  if has("code") then
    $fn_name+"("+$pn+"): REST API - response error "+(.code|tostring)+"\n" | halt_error
  else
    $fn_name+"("+$pn+"): REST API - response error\n" | halt_error
  end
end')
}

main "${(@)argv}"
