#!/usr/bin/env shorthandzsh
setopt multibyte
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
    (rss|generate-xml)
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

function syncdb::b22 {
  local -A getopts
  local -aU syncdb_statuses=()
  syncdb_statuses=(end ing)
  local -aU syncdb_regions=("${(@)argv}")
  if (( $#syncdb_regions==0 )); then
    syncdb_regions=(${b22_region_names})
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

function syncdb::kkmh {
  local -A getopts
  local -aU syncdb_statuses=()
  syncdb_statuses=(end ing)
  local -aU syncdb_regions=("${(@)argv}")
  if (( $#syncdb_regions==0 )); then
    syncdb_regions=(${(k)kkmh_region_map})
  else
    [[ ${(@)syncdb_regions[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} == 0 ]]
  fi
  integer +x syncdb_startts=$EPOCHSECONDS
  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
    get:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" -ord new || return
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
    get:item::${0#*::} -altsite kkmh -listbufstr $query_buf
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

function clip-or-print {
  if [[ -v getopts[-c] ]]; then
    printj "${(@)argv}" | termux-clipboard-set
  else
    printj "${(@)argv}" | less -s~ -Ps
  fi
}

function gen:bgmwiki::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - c
  (( $#==1 ))
  [[ "$1"==<1-> ]]
  1=$((argv[1]))
  local +x itemrepl=
  query:item::${0##*::} $1 | IFS= read -r itemrepl
  if (( $#itemrepl==0 )); then
    fetch:item::${0##*::} $1 | IFS= read -r itemrepl
  fi
  local -a +x itemrepl=("${(@ps.\t.)itemrepl}")
  local +x ti=${itemrepl[2]}
  local +x -a auts=(${itemrepl[3]})
  local +x -a intro=(${itemrepl[4]})
  local +x -a desc=(${itemrepl[5]//\\n/
})
  if [[ "${0##*::}" == b22 ]]; then
    if eval '[[ "${itemrepl[11]#('${(j.|.)b22_region_names}'):}" == .* ]]'; then
      local +x ts="$(date -d @"${itemrepl[15]}" +%F)"
      local +x endts="$(date -d @"${itemrepl[1]}" +%F)"
    else
      local +x ts="$(date -d @"${itemrepl[1]}" +%F)"
      local +x endts=
    fi
    local -a +x tags=(${itemrepl[13]} ${itemrepl[14]})
    if [[ "${itemrepl[11]%:*}" == 1* ]]; then
      tags+=(页漫)
    fi
  elif [[ "${0##*::}" == kkmh ]]; then
    local +x ts="$(date -d @"${itemrepl[1]}" +%F)"
    if [[ -n "${itemrepl[12]}" ]]; then
      local +x endts="$(date -d @"${itemrepl[12]}" +%F)"
    else local +x endts=
    fi
    local -a +x tags=(${itemrepl[10]} ${itemrepl[11]})
  fi
  clip-or-print $ti
  say '(标题: '$ti' )'
  if [[ -v getopts[-c] ]]; then
    local -a +x urlencti=($(printf %s $ti|basenc --base16 -w2))
    urlencti=(%${^urlencti})
    delay 0.2
    termux-open-url "https://bangumi.tv/subject_search/${(j..)urlencti}?cat=1&legacy=1"
  fi
  local +x magti=
  case "${0##*::}" in
    (b22) magti=哔哩哔哩漫画 ;;
    (kkmh) magti=快看漫画 ;;
  esac
  local +x infobox=
  local +x infobox_temp="{{Infobox animanga/Manga
|原作= $auts
|作者= 
|脚本= 
|分镜= 
|作画= 
|上色= 
|场景建模= 
|监制= 
|制作= $auts
|制作协力= 
|制作协调= 
|出品= 
|责任编辑= 
|开始= $ts
|结束= $endts
|连载杂志= $magti
|话数= 
|发售日= 
|出版社= 
|别名={
}
}}"
  say $infobox_temp | vipe | readeof infobox
  if [[ "$infobox_temp" == "$infobox" || $#infobox == 0 ]]; then
    return
  fi
  clip-or-print $infobox
  if [[ -v getopts[-c] ]]; then
    printj '(已复制wiki)...'
    vared 'argv[-1]'
  fi
  local +x descbox=
  printj ${^intro}——$'\n\n' $desc | readeof descbox
  if [[ $#descbox -gt 0 ]]; then
    clip-or-print $descbox
  if [[ -v getopts[-c] ]]; then
    printj '(已复制desc: '${descbox[1,10]}')'
    vared 'argv[-1]' >/dev/null
  fi
  fi
  say ${${${(j. .)tags}//、/ }//：/ }
}
eval 'function gen:bgmwiki::kkmh {
  '${functions[gen:bgmwiki::b22]}'
}'

# options regions
function gen:xml::kkmh {
  local +x itemfile=${0##*::}:item.lst
  local -A getopts
  zparseopts -A getopts -D -F - mints: maxts:
  if (( $#==0 )); then
    local -a +x regions=(${(k)kkmh_region_map})
  else
    [[ ${(@)argv[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} -eq 0 ]]
    local -a +x regions=($argv)
  fi
  local -a +x statuses=(end ing)
  local +x wreg=; for wreg in $regions; do
    local +x wsta=; for wsta in $statuses; do
    local +x xmlfile=${0##*::}-$wreg-$wsta.atom.xml
    local +x awkprog='{
      ts=$1
      id=$8; sub(/^[^:]+:/,"",id)
      ti=$2
      aut=$3
      intro=$4; gsub(/&/,"&amp;",intro); gsub(/</,"&lt;",intro); gsub(/>/,"&gt;",intro)
      desc=$5; gsub(/&/,"&amp;",desc); gsub(/</,"&lt;",desc); gsub(/>/,"&gt;",desc); gsub(/\\n/,"<br>",desc)

      hc=$6
      vc=$7

      st=$9; sub(/^[-a-z]+:/,"",st)
      ch=st; sub(/^.(:|)/,"",ch); sub(/:[-0-9.]+$/,"",st)

      style=$10; gsub(/ /,"",style)
      tag=$11; gsub(/ /,"",tag)
      date2=$12

      print ts,ti,(urlprefix id "/"),( \
        ((length(intro)>0 && intro!=ti && intro!=desc) ? "<div class=\"intro\">——" intro "</div><br>" : "") \
        "<div class=\"desc\">" desc "</div><br>" \
        "<div class=\"tags\">" style ((length(style)>0 && length(tag)>0) ? "：" : "") tag "</div>" \
        "<div class=\"chapstat\">" (ch>0 ? ch "话" : "") (st=="'${b22_valid_status_notations[end]}'" ? "完结" : "") (date2>0 ? "（最后更新：" strftime("%F",date2) "）" : "") "</div>" \
        "<div class=\"gallery\">" \
        (length(hc)>0 ? "<img src=\"" hc "\">" : "") \
        (length(vc)>0 ? "<img src=\"" vc "\">" : "") \
        "</div>" \
      ),"html",$10,aut,"",reg
    }'
    local +x bbuf=
    query:item::${0##*::} -status $wsta -region $wreg | gawk -F $'\t' -v OFS=$'\t' -v urlprefix="https://www.kuaikanmanhua.com/web/topic/" -v reg=$wreg -f <(builtin printf %s $awkprog) | sfeed_atom | sed -e '3,4s%[Nn]ewsfeed%'${0##*::}-$wreg-$wsta'%'| readeof bbuf
    if (( $#bbuf>0 )); then
      local +x md5b= md5a=
      if [[ -e "$xmlfile" ]]; then
        printj $bbuf | sha256sum | awk '{print $1}' | IFS= read md5b
        sha256sum -- $xmlfile | awk '{print $1}' | IFS= read md5a
        if [[ "$md5b" != "$md5a" ]]; then
          printj $bbuf|rw -- $xmlfile
        else
          say "$0($wreg::$wsta): nothing written.">&2
        fi
      else
        printj $bbuf|rw -- $xmlfile
      fi
    else
      say "$0($wreg::$wsta): no records.">&2
    fi
  done; done
}
# options regions
function gen:xml::b22 {
  local +x itemfile=${0##*::}:item.lst
  local -A getopts
  zparseopts -A getopts -D -F - mints: maxts:
  if (( $#==0 )); then
    local -a +x regions=($b22_region_names)
  else
    (( ${argv[(I)^(${(j.|.)b22_region_names})|]} == 0 ))
    local -a +x regions=($argv)
  fi
  local -a +x statuses=(end ing)
  local +x wreg=; for wreg in $regions; do
    local +x wsta=; for wsta in $statuses; do
    local +x xmlfile=${0##*::}-$wreg-$wsta.atom.xml
    local +x awkprog='$3 !~ /'${(j.|.)excluded_auts}'/ {
      ts=$1
      id=$10; sub(/^[^:]+:/,"",id)
      ti=$2
      aut=$3
      intro=$4; gsub(/&/,"&amp;",intro); gsub(/</,"&lt;",intro); gsub(/>/,"&gt;",intro)
      desc=$5; gsub(/&/,"&amp;",desc); gsub(/</,"&lt;",desc); gsub(/>/,"&gt;",desc); gsub(/\\n/,"<br>",desc)

      hc=$6
      vc=$7
      sc=$8
      cc=$9; split(cc, ccs, /\v/)
      cchtml=""
      if (length(ccs)>0) {
        for (wcc in ccs) {
          cchtml=cchtml "<img src=\"" ccs[wcc] "\">"
        }
      }

      st=$11; sub(/^[a-z][a-z]:/,"",st)
      ch=st; sub(/^.(:|)/,"",ch); sub(/:[-0-9.]+$/,"",st)

      ym=$12; sub(/(:[-01]+|)$/,"",ym)
      hot=$12
      length(hot)>length(ym) ? sub(/^[01]:/,"",hot) : hot=0
      style=$13; gsub(/ /,"",style)
      tag=$14; gsub(/ /,"",tag)
      subts=$15

      print ts,ti,(urlprefix id),( \
        ((length(intro)>0 && intro!=ti && intro!=desc) ? "<div class=\"intro\">——" intro "</div><br>" : "") \
        "<div class=\"desc\">" desc "</div><br>" \
        "<div class=\"tags\">" style ((length(style)>0 && length(tag)>0) ? "：" : "") tag (ym==1 ? "📖" : "") (hot==1 ? "🌟" : "") "</div>" \
        "<div class=\"chapstat\">" (ch>0 ? ch "话" : "") (st=="'${b22_valid_status_notations[end]}'" ? "✅" : "") (subts>0 ? "（开刊时间：" strftime("%F",subts) "）" : "") "</div>" \
        "<div class=\"gallery\">" \
        (length(hc)>0 ? "<img src=\"" hc "\">" : "") \
        (length(vc)>0 ? "<img src=\"" vc "\">" : "") \
        (length(sc)>0 ? "<img src=\"" sc "\">" : "") \
        cchtml "</div>" \
      ),"html",$10,aut,"",(reg (ym==1 ? "|页漫" : "|条漫") (hot==1 ? "|殿堂" : ""))
    }'
    local +x bbuf=
    query:item::${0##*::} -status $wsta -region $wreg | gawk -F $'\t' -v OFS=$'\t' -v urlprefix="https://manga.bilibili.com/detail/mc" -v reg=$wreg -f <(builtin printf %s $awkprog) |sfeed_atom|sed -e '3,4s%[Nn]ewsfeed%'${0##*::}-$wreg-$wsta'%'| readeof bbuf
    if (( $#bbuf>0 )); then
      local +x md5b= md5a=
      if [[ -e "$xmlfile" ]]; then
        printj $bbuf | sha256sum | awk '{print $1}' | IFS= read md5b
        sha256sum -- $xmlfile | awk '{print $1}' | IFS= read md5a
        if [[ "$md5b" != "$md5a" ]]; then
          printj $bbuf|rw -- $xmlfile
        else
          say "$0($wreg::$wsta): nothing written.">&2
        fi
      else
        printj $bbuf|rw -- $xmlfile
      fi
    else
      say "$0($wreg::$wsta): no records.">&2
    fi
  done; done
}

readonly -a +x svcs=(b22 kkmh txac)

function get:item::kkmh {
  get:item::b22 -altsite kkmh "${(@)argv}"
}
function get:item::b22 {
  zparseopts -A getopts -D -F - listbufstr: region: altsite:
  if [[ -v getopts[-altsite] ]]; then
    [[ ${svcs[(Ie)${getopts[-altsite]}]} -ne 0 ]]
    local +x svc=${getopts[-altsite]}
  else
    local +x svc=${0##*::}
  fi
  local +x listfile=$svc:${${0%%::*}#*:}.lst
  if (( $# == 0 )) && [[ -v getopts[-listbufstr] ]]; then
    local -a +x listbufs=(${(ps.\n.)getopts[-listbufstr]})
    [[ ${#listbufs} -gt 0 ]]
    local -a +x bufs=()
    while (( ${#listbufs} > 0 )); do
      ## kkmh := ats, svc:id, ti, aut, reg:sta:eps, ep1relts, vc, hc, cat
      ## kkmh := ats, ti, svcid, regstaeps, vc, hc, aut, ep1relts, cat
      ## b22  := ats, ti, svc:id, reg:sta, vc, hc, sc
      local -a +x listbuf=(${listbufs[1]})
      listbuf=("${(@ps.\t.)listbuf[1]}")
      local +x id=${listbuf[3]#$svc:}
      [[ "$id" == <1-> ]]
      local +x region=${listbuf[4]%%:*}; (( ${#region} > 0 ))
      printj $'\r'$0"($id): ${listbuf[4]} ~" >&2
      local -a +x buf=()
      if [[ $svc == ${0##*::} ]]; then
        if ! fetch:item::$svc $id | IFS= read -rA buf; then
          say $'\r'$0"($id): ${listbuf[4]} !" >&2
          return 1
        fi
        buf=("${(@ps.\t.)buf}")
        buf[11]="${region}:${buf[11]}"
      elif [[ $svc == kkmh ]]; then
        if ! say ${listbufs[1]} | fetch-expand:list2item::$svc | IFS= read -rA buf; then
          say $'\r'$0"($id): ${listbuf[4]} !" >&2
          return 1
        fi
      fi
      printj $'\r'$0"($id):${buf[11]} %" >&2
      bufs+=("${(@pj.\t.)buf}")

      unset buf
      if [[ $#bufs == 14 ]]; then
        printf '%s\n' ${(@)bufs} | zstrwan $listfile
        printj $'\b.' >&2
        bufs=()
        _delay_next $#listbufs
        say >&2
      fi
      shift listbufs
    done
    if [[ $#bufs -gt 0 ]]; then
      printf '%s\n' ${(@)bufs} | zstrwan $listfile
      say $'\b.' >&2
      bufs=()
    fi
  elif (( $# > 0 )) && [[ $svc == ${0##*::} ]] && [[ -v getopts[-region] ]] && ! [[ -v getopts[-listbufstr] ]] && [[ "${b22_region_names[(Ie)${getopts[-region]}]}" -gt 0 ]]; then
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
  if [[ "${0##*::}" == b22 ]]; then
  local -a +x patexps=('$10 ~ /^'${0##*::}':[0-9]+$/' '$11 !~ /:_$/')
  patexps+=('! printed_ids[$10]++')
  else
  local -a +x patexps=('$8 ~ /^'${0##*::}':[0-9]+$/' '$9 !~ /:_$/')
  patexps+=('! printed_ids[$8]++')
  fi
  local +x mints=${getopts[-mints]} maxts=${getopts[-maxts]}
  if [[ -v getopts[-mints] ]]; then
    [[ "$mints" == <1-> ]]
    mints=$((mints))
    if [[ "${0##*::}" == b22 ]]; then
      patexps+=('($1>='$mints' || $15>='$mints')')
    else
      patexps+=('($1>='$mints')')
    fi
  fi; if [[ -v getopts[-maxts] ]]; then
    [[ "$maxts" == <1-> ]]
    maxts=$((maxts))
    if [[ -v getopts[-mints] ]]; then
      ((maxts>=mints))
    fi
    if [[ "${0##*::}" == b22 ]]; then
      patexps+=('(($1>0 && $1<='$maxts') || ($15>0 && $15<='$maxts'))')
    else
      patexps+=('($1>0 && $1<='$maxts')')
    fi
  fi
  local -aU +x regions=() statuses=()
  if [[ -v getopts[-region] ]]; then
    [[ ${#getopts[-region]} -gt 0 ]]
    regions=("${(@s.,.)getopts[-region]}")
    [[ ${#regions} -gt 0 ]]
    if [[ ${0##*::} == b22 ]]; then
      [[ ${regions[(I)^(${(j.|.)b22_region_names})|]} -eq 0 ]]
      [[ ${regions[(I)${(j.|.)b22_region_names}]} -gt 0 ]]
    elif [[ ${0##*::} == kkmh ]]; then
      [[ ${(@)regions[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} -eq 0 ]]
      [[ ${(@)regions[(I)${(@j.|.)${(@k)kkmh_region_map}}]} -gt 0 ]]
    else false txdm tbd
    fi
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
    if [[ "${0##*::}" == b22 ]]; then
    actexps+=('$11 ~ /:['${(@j..)actexps_status}'](:[-0-9.]+|)$/')
    else
    actexps+=('$9 ~ /:['${(@j..)actexps_status}'](:[-0-9.]+|)$/')
    fi
  fi
  if [[ $#regions -gt 0 ]]; then
    local +x walk_region=; for walk_region in $regions; do
      actexps_region+=($walk_region)
    done
    if [[ "${0##*::}" == b22 ]]; then
    actexps+=('$11 ~ /^('${(@j.|.)actexps_region}'):/')
    else
    actexps+=('$9 ~ /^('${(@j.|.)actexps_region}'):/')
    fi
  fi
  if (( $# > 0 )); then
    if [[ "${0##*::}" == b22 ]]; then
    actexps+=('$10 ~ /^'${0##*::}':('${(j.|.)argv}')$/')
    else
    actexps+=('$8 ~ /^'${0##*::}':('${(j.|.)argv}')$/')
    fi
  fi
  local +x awkprog=${(j. && .)patexps}
  if [[ $#actexps -gt 0 ]]; then
    awkprog+=" { if ( ${(j. && .)actexps} ) print }"
  fi
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  zstdcat -- $listfile | grep -ve '^#' | tac | gawk -F $'\t' -f <(builtin printf %s $awkprog) | tac
}
functions[query:item::kkmh]=${functions[query:item::b22]}

function query:list::b22 {
  zparseopts -A getopts -D -F - region: status:; (($#<=2))
  local +x mints=$1 maxts=$2
  local -a +x patexps=('$3 ~ /^'${0##*::}':[0-9]+$/' '$4 !~ /:_$/')
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
    if [[ ${0##*::} == b22 ]]; then
      [[ ${regions[(I)^(${(j.|.)b22_region_names})|]} -eq 0 ]]
      [[ ${regions[(I)${(j.|.)b22_region_names}]} -gt 0 ]]
    elif [[ ${0##*::} == kkmh ]]; then
      [[ ${(@)regions[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} -eq 0 ]]
      [[ ${(@)regions[(I)${(@j.|.)${(@k)kkmh_region_map}}]} -gt 0 ]]
    else false txdm tbd
    fi
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
    actexps+=('$4 ~ /:['${(@j..)actexps_status}'](|:[0-9]+)$/')
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
functions[query:list::kkmh]=${functions[query:list::b22]}

function get:list::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - ord: maxpn: region: status:; (( $# <= 1 ))
  integer +x startpn=${1:-1} maxpn=${getopts[-maxpn]:--1}
  (( startpn>0 )); (( maxpn>=startpn||maxpn<0 ))
  integer +x pn=$startpn
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  while ((pn<=maxpn||maxpn<0)); do
    local +x listresp=
    printj $0"($pn):? (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
    fetch:list::${0##*::} -region "${getopts[-region]}" -status "${getopts[-status]}" ${getopts[-ord]:+-ord} ${getopts[-ord]} $pn | readeof listresp
    if (( $#listresp==0 )); then if (( pn>1 )) || [[ $pn == 1 && "${getopts[-ord]}" == new && "${0##*::}" == kkmh ]]; then
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
#functions[get:list::kkmh]=${functions[get:list::b22]}

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

function get:nav-banner::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - altsite:
  (( $#==0 ))
  if [[ ${#getopts[-altsite]} -ne 0 ]]; then
    local +x svc=${getopts[-altsite]}
  else
    local +x svc=${0##*::}
  fi
  local +x listfile=$svc:${${0%%::*}#*:}.lst
  local +x resp=
  fetch:${${0%%::*}#*:}::$svc | readeof resp
  local +x ts=$EPOCHSECONDS
  if (( $#resp>0 )); then
    if [[ -e $listfile ]]; then
      local +x tbw=
      printj $resp | anzst -pipe 'cut -f2-' -- $listfile | readeof tbw
      read
      if (( $#tbw >0 )); then
        local -a +x tbw=(${(ps.\n.)tbw})
        printf %s'\n' $ts$'\t'${(@)^tbw} | zstd | rw -a -- $listfile
      fi
    else
      local -a +x resp=(${(ps.\n.)resp})
      printf %s'\n' $ts$'\t'${(@)^resp} | zstd -qo $listfile
    fi
  fi
}

function fetch:nav-banner::b22 {
  local +x jsonresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $b22_restapi_http_hdr \
    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/Banner?device=pc&platform=web' \
    -H 'accept: application/json, text/plain, */*' \
    -H 'accept-language: zh-CN,zh;q=0.9' \
    -H 'content-type: application/json;charset=UTF-8' \
    --data-raw '{"platform":"pc"}' | readeof jsonresp
  integer +x ts=$EPOCHSECONDS
  printj $jsonresp | gojq -r --arg site ${0##*::} '
def resp_ok: if has("code") and has("data") and (.data|length>0) and (.code==0) then
  .data
else
  halt_error
end;

resp_ok | .[] | select((.jump_value|match("^bilicomic://reader/([0-9]+)")|.captures.[0].string)|length>0)|[$site+":"+(.jump_value|match("^bilicomic://reader/([0-9]+)")|.captures.[0].string),.img]|join("\t")'
}

function fetch:list::b22 {
  local -A getopts
  zparseopts -A getopts -D -F - region: status: ord:
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
  if [[ -v getopts[-ord] ]]; then
    case "${getopts[-ord]}" in
      (upd) b22_list_order=1;;
      (new) b22_list_order=3;;
      (*) return 9
      ;;
    esac
  fi
  (( $# == 1 )); [[ "$1" == <1-> ]]; 1=$((argv[1]))
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

local -A kkmh_region_map
kkmh_region_map=(
  cn-original 1
  cn 2
  kr 3
  jp 4
)
local -A kkmh_ord_map
kkmh_ord_map=(
  new 3
  rec 1
  hot 2
)
local -A kkmh_status_map
kkmh_status_map=(
  ing 1
  end 2
)
local -a +x kkmh_restapi_http_hdr=(
  'accept: application/json, text/plain, */*'
  'accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7'
  'user-agent-pc: PCKuaikan/1.0.0/100000(unknown;unknown;Chrome;pckuaikan;1920*1080;0)'
)
kkmh_restapi_http_hdr=(${curl_hdr_flag_arrplh:^^kkmh_restapi_http_hdr})
function fetch:list::kkmh {
  integer +x ps=48
  local -A getopts; zparseopts -A getopts -D -F - region: status: ord:
  (( $# == 1 )); [[ "$1" == <1-> ]]; 1=$((argv[1]))
  ## region is requred, cause the response doesnot incl region info.
  [[ -v getopts[-region] ]]
  [[ ${(@)${(@k)kkmh_region_map}[(Ie)${getopts[-region]}]} != 0 ]]

  [[ -v getopts[-status] ]]
  [[ ${(@)${(@k)kkmh_status_map}[(Ie)${getopts[-status]}]} != 0 ]]

  if [[ -v getopts[-ord] ]]; then
    [[ ${(@)${(@k)kkmh_ord_map}[(Ie)${getopts[-ord]}]} != 0 ]]
  else
    getopts[-ord]=new
  fi

  local +x jsonresp=; retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $kkmh_restapi_http_hdr \
    --referer 'https://www.kuaikanmanhua.com/tag/0' \
    --url "https://www.kuaikanmanhua.com/search/mini/topic/multi_filter?page=$1&size=$ps&tag_id=${${${getopts[-region]:#^(cn-original)}:+76}:-0}&update_status=${kkmh_status_map[${getopts[-status]}]}&pay_status=0&label_dimension_origin=${kkmh_region_map[${getopts[-region]}]}&sort=${kkmh_ord_map[${getopts[-ord]}]}" | readeof jsonresp
  integer +x ts=$EPOCHSECONDS
  printj $jsonresp | gojq -r --arg ts $ts --arg status ${b22_valid_status_notations[${getopts[-status]}]} --arg region ${getopts[-region]} --arg pn $1 --arg ord ${getopts[-ord]} --arg fn_name $0 -f <(builtin printf %s 'def resp_ok: if has("code") and (.code==200) and has("total") then
  if (.hits.topicMessageList|length>0) then .hits.topicMessageList[]
  else empty end
else
  $fn_name+"("+$region+"#"+$ord+":"+$pn+")"|halt_error
end;

resp_ok | [$ts,
(.title|gsub("[[:cntrl:]]"; "")|gsub("(^  *|  *$)";"")|gsub("   *";" "|gsub("\\\\";"\\\\"))),
("kkmh:"+(.id|tostring)),
($region+":"+$status)+(if $status=="." then ":"+(.comics_count|tostring) else "" end),
(.vertical_image_url|sub("-w[0-9]{3,4}(|\\.w)$";"")),
(.cover_image_url|sub("-w[0-9]{3,4}(|\\.w)$";"")),
(.author_name|gsub("[[:cntrl:]]"; "")|gsub("(^  *|  *$)";"")|gsub("   *";" ")|gsub("(?<a>[^+])[+](?<b>[^+])"; (.a)+"、"+(.b))|gsub("\\\\";"\\\\")),
(.first_comic_publish_time),
(if (.category|length>0) then .category|join("、") else "" end)
] | join("\t")')
}
function get:list::kkmh {
  local -A getopts
  zparseopts -A getopts -D -F - nonstop maxpn: region: status: ord:; (( $# <= 1 ))
  integer +x startpn=${1:-1} maxpn=${getopts[-maxpn]:--1}
  (( startpn>0 )); (( maxpn>=startpn||maxpn<0 ))
  [[ ${(@)${(@k)kkmh_ord_map}[(Ie)${getopts[-ord]}]} != 0 ]]
  integer +x pn=$startpn
  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
  while ((pn<=maxpn||maxpn<0)); do
    local +x listresp=
    printj $0"($pn):? (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
    fetch:list::${0##*::} -region "${getopts[-region]}" -status "${getopts[-status]}" -ord "${getopts[-ord]}" $pn | readeof listresp
    if (( $#listresp==0 )); then if (( pn>1 )) || [[ $pn == 1 && "${getopts[-ord]}" == new ]]; then
      say $'\r'$0"($pn):EOF (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
      break
    else
      say $'\r'$0"($pn):! (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
      return 1
    fi; fi
    if [[ -r "$listfile" && -f "$listfile" && -s "$listfile" ]]; then
      integer +x listresp_ts="${listresp%%	*}"; (( listresp_ts>0 ))
      local +x listresp_tbw=
      ## orig: printj $listresp | cut -f 2-
      printj "${(@pj.\n.)${(@)${(@ps.\n.)listresp}#*	}}" | anewer <(zstdcat -- $listfile | grep -ve '^#' | cut -f 2-) | readeof listresp_tbw
      if (( ${#listresp_tbw} > 1 )); then
        ## orig: printj $listresp_tbw | sed -e '/..*/s%^%'$listresp_ts'%'
        printf '%s\n' ${listresp_ts}$'\t'${(@)^${(@ps.\n.)listresp_tbw}} | zstd | rw -a -- $listfile
        say $'\r'$0"($pn):>> (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
      else
        say $'\r'$0"($pn):>< (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
        if [[ ! -v getopts[-nonstop] ]]; then break; fi
      fi
    else
      printj $listresp | zstd | rw -- $listfile
      printj $'\r'$0"($pn):>. (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
    fi
    pn+=1
  done
}

function fetch:nav-banner::kkmh {
  local +x htmlresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie \
    --url 'https://www.kuaikanmanhua.com/' \
    -H 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' | readeof htmlresp
  integer +x ts=$EPOCHSECONDS
  local +x jsresp=
  printj ${${${${htmlresp##*,bannerList:\[}%%\]*}//\&quot;/\"}//\\u002[Ff]/\/} | readeof jsresp
  [[ $#jsresp -ne 0 ]]; [[ $#jsresp -ne $#htmlresp ]]
  local +x jsspl=
  printj $jsresp | grep -Eoe '(target_id:"[0-9]+"|image_url:"http[^"]+")' | readeof jsspl
  local -a +x jsspl=(${(ps.\n.)jsspl})
  [[ $#jsspl -ne 0 && $(($#jsspl%2)) -eq 0 ]]
  local -a +x epids=() imguris=()
  printf '%s\n' $jsspl | sed -nEe '/^target_id:"[0-9]+"$/ s%(.+:|")%%gp' | readarray epids
  printf '%s\n' $jsspl | sed -nEe '/^image_url:"http[^"]+"$/ s%(^image_url:|")%%gp' | readarray imguris
  [[ $#epids -eq $#imguris ]]
  while (( $#epids!=0 )); do
    integer +x serid=
    conv:id:ep2serial::${0##*::} ${epids[1]} | IFS= read -r serid
    say ${0##*::}:$serid $'\t' ${imguris[1]}
    shift epids
    shift imguris
  done
}

function conv:id:ep2serial::kkmh {
  (( $#==1 ))
  [[ "$1" == <1-> ]]
  integer +x epid=$((argv[1]))
  local +x htmlresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie \
    --url 'https://www.kuaikanmanhua.com/web/comic/'$epid'/' \
    -H 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' | readeof htmlresp
  [[ $#htmlresp -ne 0 ]]
  local +x uri=
  printj $htmlresp | pup -p 'div.titleBox h3.title a:nth-of-type(2)' 'attr{href}' | IFS= read -r uri
  [[ "$uri" == /web/topic/<1-> ]]
  integer +x id=${uri##*/}
  say $id
}

function get:nav-banner::kkmh {
  ${0%::*}::b22 -altsite ${0##*::}
}

function fetch-expand:list2item::kkmh {
  while :; do
    local -i +x i=
    local -a +x listbuf=()
    IFS= read -rA listbuf || break
    listbuf=("${(@ps.\t.)listbuf}")
    if [[ $#listbuf == 0 ]]; then break; fi
    ## kkmh := ats, ti, svcid, regstaeps, vc, hc, aut, ep1relts, cat
    [[ "${listbuf[3]}" == ${0##*::}:<1-> ]]
    integer id=${listbuf[3]#${0##*::}:}
    let $id
    local +x ti=${(Q)listbuf[2]}
    let $#ti
    local +x jsonresp=
    retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $kkmh_restapi_http_hdr --url 'https://www.kuaikanmanhua.com/search/web/complex' --url-query q=$ti --url-query f=3 \
    --referer 'https://www.kuaikanmanhua.com/sou/%20' | readeof jsonresp
    local +x reply=
    printj $jsonresp | gojq --arg id $id --arg region "${listbuf[4]%%:*}" --arg aut "${listbuf[7]}" -r -f <(builtin printf %s 'def resp_ok: if has("code") and (.code==200) then
  if (.data.topics.hit|length>0) then .data.topics.hit[]
  else empty|halt end
else
  empty|halt_error
end;

def sanitstr: gsub("(^  *|  *$)";"")|gsub("[\t ]+";" ")|gsub("\t";"")|gsub("\\\\";"\\\\")|gsub("\n";"\\n")|gsub("[[:cntrl:]]";"");

resp_ok | if ([select((.id|tostring)==$id)]|length==1) then
  select((.id|tostring)==$id) | [
    (if (.first_comic_publish_time|tostring|test("^....-..-..T..:..:..\\....\\+..:..$")) then
       .first_comic_publish_time|sub("\\.[0-9]{3,}\\+(?<zh>[0-9]{2}):(?<zm>[0-9]{2})$";"+"+(.zh)+(.zm))|strptime("%FT%T%z")|mktime
     else
       now
     end),
    (.title|sanitstr),
    ($aut),
    (.recommend_text as $intro | if (.description|contains($intro)|not) and (.title|contains($intro)|not) then .recommend_text|sanitstr else "" end),
    (.description|sanitstr),
    (.cover_image_url|sub("-w[0-9]{3,4}(|\\.w)(|\\.(jpg|png))$";"")),
    (.vertical_image_url|sub("-w[0-9]{3,4}(|\\.w)(|\\.(jpg|png))$";"")),
    ("kkmh:"+(.id|tostring)),
    ($region+":"+(if (.update_status==2) then "." else
      if (.update_status==1) then "~"
      else "?"
      end
    end)+(if (.update_status==2) then ":"+(.comics_count|tostring) else "" end)),
    (if (.category|length>0) then .category|join("、")|sanitstr else "" end),
    (.sentence_desc|sanitstr|gsub(" ";"、"))
  ] | join("\t")
else
  empty|halt
end') | readeof reply
    local -a +x replies=(${(ps.\n.)reply}) reconst_replies=()
    if let $#replies; then
      while (( $#replies != 0 )); do
        local -a +x fcrepl=() reconst_reply=("${(@ps.\t.)${(@)replies[1]}}")
        fetch-complement:item::kkmh $id | IFS= read -rA fcrepl
        fcrepl=("${(@ps.\t.)fcrepl}")
        local -a +x -U cats=(${(@s.、.)${(@)reconst_reply[10]}})
        local -a +x -U tags=($cats ${(@s.、.)${(@)fcrepl[1]}})
        if (( $#tags>$#cats )); then
          tags=(${(@)tags:$#cats})
        else
          tags=()
        fi
        if [[ "${fcrepl[2]}" != '+' ]]; then
          cats+=('投稿')
          reconst_reply[10]=${(j.、.)cats}
        fi
        if (( $#tags )); then
          if (( ${#reconst_reply[11]} )); then
            reconst_reply[11]+=、
          fi
          reconst_reply[11]+=${(j.、.)tags}
        fi
        if (( (${fcrepl[3]:-0} > 0) && (EPOCHSECONDS - ${fcrepl[3]:-0} >= 31536000) )); then
          reconst_reply[12]=${fcrepl[3]:-0}
        fi
        reconst_replies+=("${(@pj.\t.)reconst_reply}")
        say "${(@pj.\t.)reconst_reply}"
        shift replies
      done
      let $#reconst_replies
    else
      false left unimplmented
    fi
    i+=1
    if (( i>100 && i%45==0 )); then
      delay $((${RANDOM%19}+6))
    fi
  done
}

function fetch-complement:item::kkmh {
  integer +x id=$1; (( $# == 1 && id > 0 ))
  local +x htmlresp=
  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fios https://m.kuaikanmanhua.com/mobile/$id/list/ | readeof htmlresp
  integer +x ts=$EPOCHSECONDS
  (( $#htmlresp!=0 ))
  local +x tag=
  printj $htmlresp | html2data - 'div.classifications span' | readeof tag
  tag=${${tag%[
	 ]##}//
/、}
  if [[ $htmlresp == *[_a-zA-Z]([_a-zA-Z]|)'.signing_status="签约作品"'* ]]; then
    local +x qy='+'
  else
    local +x qy=
  fi
  printj $tag${qy:+	}${qy}
  local -a +x epts=()
  if printj $htmlresp | rg --no-config -oe ',created_at:([0-9]{3,})[0-9]{3}' -r '$1' | readarray epts; then
    printj $'\t'${epts[-1]}
  fi
  say
}

main "${(@)argv}"
