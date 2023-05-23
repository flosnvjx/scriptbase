#!/usr/bin/env shorthandzsh
local -A +x mh_st_smap
mh_st_smap=(
  ing '~'    end .
  tba '?'    err '!'
  dummy '@'
)
local -A +x mh_lic_smap
mh_lic_smap=(
  ok '+'     non '-'
  excl '++'  unknown ''
)
local -a +x mh_reg_nms=(
  cn kr jp
)
local -a +x mh_ls_ord_nms=(
  new upd hot rec
)
## kk: auts, cats[], numofeps, hc, relengdate, id, ti, vc, lastepti
## b22: lastepcti, lastepti, hc, lastepnum, relengdate, id, vc, sc, numofeps, ifvcomic, ifend
## txac: vc, ti, numofeps, lic, aut, cats[], desc, id, vc
## sfacg: aut, vc, id, lastepti, lastepdate, ifend, cats
## nvcn: vc, cat, ti, id, desc
local -a +x mh_dbe_cols=(
  bonjour
  id ti
  autnm autid ## + circleid (allcpp)
  stat ## stat == region+ifend+lastepnum/epcount
  vc hc icon albimgcap albimg
  cat ## item parody-work-title (allcpp)
  desc tag ## cpname
  intro ## secondary ti
  id2 ti2 ## collection id/ti (allcpp)
  date ## firstepdate/lastepdate
  date2 ## lastupd
  xattr ## extstat == lic 页漫、精选
)

readonly -a +x excl_ep_ti_re=(
  '敬请期待|先导|前瞻|预告|预热|预览|放料|人物|人设|介绍|新作|上线|连载'
  '福利|抽奖|开奖|中奖|兑奖|月票|投喂|活动|加料|订阅|关注|不见不散|平台|^序$|说明|通知|通告|请假|假条|更新|延迟|延更|开更|开刊'
  '完结|致谢|鸣谢|停更|整改|下架|复更|加更|作者的话'
  '内测|(新|星)势力|主站'
  'bilibili|哔哩哔哩|快看|KKworld|出展|动漫嘉年华|动漫节|国际动漫|ChinaJoy|COMICUP|腾讯动漫|阅文|企鹅娘'
  '动画|开播|漫剧|漫动画|有声漫画|Vcomic|广播剧|电视剧|剧场版|单行本|发售|上架|正式|线下|签售'
  '周边|赠品|抱枕|明信片|鼠标垫|立牌|Q币|好礼|券'
  '背景|设定|图鉴|鉴赏|百科|小课堂'
  '番外|小剧场|花絮|(制|创)作团队|寄语|原作'
  '贺图|(祝|贺)(—|:|：)|祝贺|庆祝|恭贺|谨贺'
  '周年|元旦|新年|元宵|新禧|佳节|春节|新春|清明|端午|中秋|国庆|祖国|圣诞'
)

alias 'initparse__argv0=local +x act=${${0%%::*}%%:*} actwhat=${${0%%::*}#*:} svc=${${0##*::}%%+*}
  if [[ "${#0##*::}" -gt "${#${0##*::}%%+*}" ]]; then
    local +x anc=${${${0##*::}##*+}%%"#"*}
    if [[ "${${0##*::}##*+}" == *"#"* ]]; then
      local +x subanc=${${${0##*::}##*+}#*"#"}
    else
      local +x subanc=
    fi
  else
    local +x anc= subanc=
  fi
  if [[ "$0" != "$act${actwhat:+:}$actwhat::${svc}${anc:+"+"}${anc}"${subanc:+"#"}${subanc} ]]; then
    false failure during parsing argc0
  fi'

alias furl='command curl -qgsf --compressed'
alias fie='furl -A "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv 11.0) like Gecko"'
alias fios='furl -A "Mozilla/5.0 (iPhone; CPU iPhone OS 14_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 EdgiOS/46.3.7 Mobile/15E148 Safari/605.1.15"'
alias nfkc='uconv -x ":: NFKC; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;"'
alias mulrg='rg -U --multiline-dotall'
alias readline='IFS= builtin read -r --'
alias readaline='IFS= builtin read -rA --'

alias init__mh_dbe_cols='eval unset "${(@k)mh_dbe_cols}" ";" local -aU "${(@k)mh_dbe_cols}"'

function normalize__mh_dbe_cols {
  if ! (( $# )); then
    argv=(${(@k)mh_dbe_cols})
  fi
  while (( $# )); do
    if (( ${(P)#1} )); then
      set -A "$1" "${(@)${(@)${(@)${(@)${(@)${(@)${(P@)1}//\\/\\\\}%%( |	|
)##}##( |	|
)##}//
/\\n}//	/\\t}//}"
    fi
    shift
  done
}

function join2param__mh_dbe_cols {
  (( $#==1 ))
  [[ -v "$1" && "$1" != *'['* ]]
  case "${(Pt)1}" in
    (scalar|scalar-local)
      function {
        : ${(P)argv[-1]::=}
        until (( $# == 1 )); do
          : ${(P)argv[-1]::=${(P)argv[-1]}${(pj.\v.)${(P@)1}}}
          shift
          : ${(P)argv[-1]::=${(P)argv[-1]}	}
        done
        : ${(P)argv[-1]::=${${(P)argv[-1]}%%	(#c1,)}}
      } "${(@k)mh_dbe_cols}" "$1"
    ;;
    (*)
      return 1
    ;;
  esac
}

local -A txac__mh_st_smap
txac__mh_st_smap=(
  end 2
  ing 1
)

function 'fetch:item::txac+h5' {
  (( $#==1 )); [[ "$1" == <1-> ]]
  argv[1]=$((argv[1]))
  initparse__argv0; init__mh_dbe_cols
  local htmlresp
  pipeok fios --url "https://m.ac.qq.com/comic/index/id/${1}" | nfkc | readeof htmlresp
  integer ts=$EPOCHSECONDS

  bonjour=$ts
  id=$svc:$1
  if [[ ! -v fetchedentry ]]; then local fetchedentry; fi

  if (( $#htmlresp )) && printj $htmlresp | pup 'meta[property=og:title]' 'attr{content}' | readarray ti; then

    integer epcount
    local epstatusresp
    printj $htmlresp | html2data - 'h1.mod-chapter-title span:nth-of-type(1)' | readeof epstatusresp
    local -a match mend mbegin
    if [[ "$epstatusresp" == *'连载'* ]]; then
      [[ "$epstatusresp" == *'已更新'(#b)([0-9](#c1,))(#B)* ]]||:
      epcount=${match[1]}
      if (( ${epcount:-0}==0 )); then
        stat[1]=${mh_st_smap[tba]}
      else
        stat[1]=${mh_st_smap[ing]}
      fi
    elif [[ "$epstatusresp" == *'完结'* ]]; then
      [[ "$epstatusresp" == *'已更新'(#b)([0-9](#c1,))(#B)* ]]||:
      epcount=${match[1]}
      if (( ${epcount:-0}==0 )); then
        stat=(${mh_st_smap[tba]})
      else
        stat=(${mh_st_smap[end]}:$epcount)
      fi
    else
      false undefined eps index pattern
    fi
    unset match mend mbegin

    if (( epcount!=0 )); then
      builtin local -a {,oktr_}ep_{ti,img}s
      if printj ${htmlresp//
/ } | html2data - 'p.chapter-title' | readarray ep_tis && printj $htmlresp | pup '.chapter-item .chapter-link img.chapter-img' 'attr{src}' | readarray ep_imgs && (( $#ep_tis == $#ep_imgs && $#ep_tis>0 )); then
        ep_tis=(${(@)ep_tis})
        integer walkepseq=1
        while (( walkepseq<=$#ep_imgs )); do
          if ! printj "${ep_tis[$walkepseq]}" | rg -qe '('${(j.|.)excl_ep_ti_re}')'; then
            oktr_ep_tis+=("${ep_tis[$walkepseq]}")
            oktr_ep_imgs+=("${ep_imgs[$walkepseq]}")
          fi
          walkepseq+=1
        done
        if [[ "${stat[1]}" == "${mh_st_smap[ing]}" ]] && (( $#oktr_ep_tis==0 )); then
          stat[1]=${mh_st_smap[tba]}
        fi

        walkepseq=1; local -a ep_img_tss=()
        if (( $#oktr_ep_imgs )); then while (( $#walkepseq<=$#oktr_ep_imgs && $#ep_img_tss<=5 )); do
          unset safecurltsstr; local safecurltsstr
          LC_ALL=C builtin strftime -s safecurltsstr '%Y%m%d %H:%M:%S %z' $((EPOCHSECONDS+86400))
          unset curltsresp; local curltsresp
          unset walkepimgts; integer walkepimgts
          if retry -w 15 1 pipeok fie -L -o /dev/null -z "$safecurltsstr" -w '%header{last-modified}\n' --url "${oktr_ep_imgs[$walkepseq]}" | readline curltsresp && builtin strftime -r -s walkepseq -- '%a, %d %b %Y %H:%M:%S %Z' "$curltsresp"&>/dev/null || date -d "$curltsresp" +%s | readline walkepimgts && (( walkepimgts>0 )); then
            ep_img_tss+=($walkepimgts)
          fi
          if (( walkepseq<0 )); then
            break
          else
            walkepseq+=1
          fi
          ## collect last ep
          if (( walkepseq>5 && $#oktr_ep_imgs>5 )); then
            walkepseq=-1
          fi
        done; fi

        set -x
        if (( $#ep_img_tss>0 )); then
          ep_img_tss=(${(n)ep_img_tss})
          date=(${ep_img_tss[1]})
          ## if book is not updated >= 1y
          if (( ($EPOCHSECONDS - ${ep_img_tss[-1]}) >= 31536000 )) || [[ "${stat[1]}" == "${mh_st_smap[end]}"* ]]; then
            date2=(${ep_img_tss[-1]})
            stat[1]+=":${#ep_tis}"
          fi
        fi
        set +x

      fi
    fi

  elif [[ "$htmlresp" == *'class="err-type2"'* ]]; then
    stat=(${mh_st_smap[err]})
    normalize__mh_dbe_cols
    join2param__mh_dbe_cols fetchedentry
    return
  elif (( $#htmlresp==0 )); then
    stat=(${mh_st_smap[dummy]})
    normalize__mh_dbe_cols
    join2param__mh_dbe_cols fetchedentry
    return
  else
    return 1
  fi

  printj $htmlresp | pup 'meta[property=og:image]' 'attr{content}' | readaline hc
  if [[ "${hc[1]}" == *'/operation/'* ]]; then
    hc=()
  fi
  printj $htmlresp | html2data - 'div.head-info-desc' | readeof desc
  printj $htmlresp | html2data - '.head-info-author .author-list .author-wr' | readarray autnm
  normalize__mh_dbe_cols
  join2param__mh_dbe_cols fetchedentry
  say $fetchedentry
}

function 'fetch:list::txac+pchtml#end' {
  (( $#==1 )); [[ "$1" == <1-> ]]
  integer pn=$1
  initparse__argv0

  local htmlresp
  pipeok fie --url 'https://ac.qq.com/Comic/all/finish/'${txac__mh_st_smap[$subanc]}'/search/time/page/'$pn | nfkc | readeof htmlresp
  local ts=$EPOCHSECONDS
  (( $#htmlresp ))

  ## on out-of-pn-range this will return false
  if printj $htmlresp | mulrg -oe '<ul class="ret-search-list clearfix">.+?</ul>' | readeof htmlresp; then
    printj $htmlresp | mulrg -oe '<li class="ret-search-item clearfix">(.+?)</li>' -r '$1'$'\v' | readeof htmlresp
    local -a html_li=(${(ps.\v.)htmlresp})
    local -a fetched_entries
    while (( $#html_li )); do
      unset fetchedentry; local fetchedentry=
      init__mh_dbe_cols
      bonjour[1]=$ts
      printj ${html_li[1]} | html2data - 'h3.ret-works-title > a:attr(title)' | readaline ti
      printj ${html_li[1]} | pup 'div.ret-works-cover img:nth-of-type(1)' 'attr{data-original}' | readaline vc
      vc[1]="${${vc[1]}%/([0-9])##}/0"
      if [[ "${html_li[1]}" == *' class="ui-icon-sign"'* ]]; then
        xattr+=(L)
      fi
      if [[ "${html_li[1]}" == *' class="ui-icon-exclusive"'* ]]; then
        xattr+=(u)
      fi
      stat[1]="${mh_st_smap[$subanc]}"
      if [[ "$subanc" == end ]]; then
        unset epcount; local epcount
        printj ${html_li[1]} | html2data - 'span.mod-cover-list-text' | readaline epcount
        integer epcount=${${epcount#全}%话}
        (( epcount ))
        stat[1]+=":$epcount"
      fi
      printj ${html_li[1]} | pup -p 'p.ret-works-tags span[href]' 'text{}' | readarray tag
      printj ${html_li[1]} | pup 'a.ret-works-view' 'attr{href}' | readaline id
      id[1]=${svc}:${id[1]##*/}
      normalize__mh_dbe_cols
      join2param__mh_dbe_cols fetchedentry
      fetched_entries+=($fetchedentry)
      shift html_li
      if [[ "${html_li[1]}" == ($'\n'|$'\t'| )## ]]; then
        shift html_li
      fi
    done
    (( $#fetched_entries ))
    printf '%s\n' $fetched_entries
  elif ((pn>1)); then
    return
  else
    false broken grep match rule
  fi
}
fnclone 'fetch:list::txac+pchtml#'{end,ing}

builtin zmodload -Fa zsh/datetime p:EPOCHSECONDS b:strftime
builtin zmodload -Fa zsh/zutil b:zparseopts

"${(@)argv}"
#function main {
#  case "$1" in
#    (s|syncdb)
#      shift; syncdb "${(@)argv}" ;;
#    (f|fetch-complement)
#      shift; fetch-complement "${(@)argv}" ;;
#    (g|get)
#      shift; get "${(@)argv}" ;;
#    (q|query)
#      shift; query "${(@)argv}" ;;
#    (rss|generate-xml)
#      shift; generate-xml "${(@)argv}" ;;
#    (srs)
#      shift
#      syncdb "${(@)argv}"
#      generate-xml "${(@)argv}"
#      ;;
#    (*)
#      "${(@)argv}"
#      ;;
#  esac
#}
#
#local -a +x b22_region_names=(cn kr jp)
#local -A +x b22_valid_status_notations
#b22_valid_status_notations=(
#  end .
#  ing '~'
#  tba '?'
#  err '!'
#)
#
#function syncdb::b22 {
#  local -A getopts
#  local -aU syncdb_statuses=()
#  syncdb_statuses=(end ing)
#  local -aU syncdb_regions=("${(@)argv}")
#  if (( $#syncdb_regions==0 )); then
#    syncdb_regions=(${b22_region_names})
#  else
#    [[ ${(@)syncdb_regions[(I)^(${(j.|.)b22_region_names})|]} == 0 ]]
#  fi
#  integer +x syncdb_startts=$EPOCHSECONDS
#  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
#    get:list::${0##*::} -region "${i%%:*}" -status "${i##*:}"
#  done; unset i
#  integer +x syncdb_endts=$EPOCHSECONDS
#
#  local +x query_buf=
#  local +x i=; for i in ${(@)^syncdb_regions}:{tba,err}; do
#    local +x buf=
#    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" 1 $((syncdb_startts - 1)) | readeof buf
#    query_buf+=$buf; buf=
#  done; unset i
#  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
#    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" $syncdb_startts $syncdb_endts | readeof buf
#    query_buf+=$buf
#    unset buf
#  done; unset i
#  if [[ $#query_buf -gt 0 ]]; then
#    get:item::${0#*::} -listbufstr $query_buf
#  fi
#}
#
#function syncdb::kkmh {
#  local -A getopts
#  local -aU syncdb_statuses=()
#  syncdb_statuses=(end ing)
#  local -aU syncdb_regions=("${(@)argv}")
#  if (( $#syncdb_regions==0 )); then
#    syncdb_regions=(${(k)kkmh_region_map})
#  else
#    [[ ${(@)syncdb_regions[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} == 0 ]]
#  fi
#  integer +x syncdb_startts=$EPOCHSECONDS
#  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
#    get:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" -ord rec || return
#  done; unset i
#  integer +x syncdb_endts=$EPOCHSECONDS
#
#  local +x query_buf=
#  local +x i=; for i in ${(@)^syncdb_regions}:{tba,err}; do
#    local +x buf=
#    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" 1 $((syncdb_startts - 1)) | readeof buf
#    query_buf+=$buf; buf=
#  done; unset i
#  local +x i=; for i in ${(@)^syncdb_regions}:${(@)^syncdb_statuses}; do
#    query:list::${0##*::} -region "${i%%:*}" -status "${i##*:}" $syncdb_startts $syncdb_endts | readeof buf
#    query_buf+=$buf
#    unset buf
#  done; unset i
#  if [[ $#query_buf -gt 0 ]]; then
#    get:item::${0#*::} -altsite kkmh -listbufstr $query_buf
#  fi
#}
#function zstrwan {
#  [[ $# == 1 ]]
#  local +x bbuf=
#  zstan "$1" | readeof bbuf
#  if [[ $#bbuf -gt 0 ]]; then
#    printj $bbuf | zstd | rw -a -- "$1"
#  elif [[ -e "$1" ]]; then
#    touch -- "$1"
#  fi
#}
#
#function zstan {
#  [[ $# == 1 ]]
#  if [[ -e "$1" ]]; then
#    anewer <(zstdcat -- "$1")
#  else
#    cat
#  fi
#}
#
#function clip-or-print {
#  if [[ -v getopts[-c] ]]; then
#    printj "${(@)argv}" | termux-clipboard-set
#  else
#    printj "${(@)argv}"
#  fi
#}
#function gen:bgmwiki::b22 {
#  local -A getopts
#  zparseopts -A getopts -D -F - c
#  (( $#==1 ))
#  [[ "$1"==<1-> ]]
#  1=$((argv[1]))
#  local +x itemrepl=
#  query:item::b22 $1 | readeof itemrepl
#  if (( $#itemrepl==0 )); then
#    fetch:item::b22 $1 | readeof itemrepl
#  fi
#  local -a +x itemrepl=("${(@ps.\t.)itemrepl}")
#  local +x ti=${itemrepl[2]}
#  local +x -a auts=(${itemrepl[3]})
#  local +x -a intro=(${itemrepl[4]})
#  local +x -a desc=(${itemrepl[5]//\\n/
#})
#  if eval '[[ "${itemrepl[11]#('${(j.|.)b22_region_names}'):}" == .* ]]'; then
#    local +x ts=$(date -d @${itemrepl[15]} +%F)
#    local +x endts=$(date -d @${itemrepl[1]} +%F)
#  else
#    local +x ts=$(date -d @${itemrepl[1]} +%F)
#    local +x endts=
#  fi
#  local -a +x tags=(${itemrepl[13]} ${itemrepl[14]})
#  if [[ "${itemrepl[11]%:*}" == 1* ]]; then
#    tags+=(页漫)
#  fi
#  clip-or-print $ti
#  say '(标题: '$ti' )'
#  if [[ -v getopts[-c] ]]; then
#    local -a +x urlencti=($(printf %s $ti|basenc --base16 -w2))
#    urlencti=(%${^urlencti})
#    termux-open-url "https://manga.bilibili.com/detail/mc${itemrepl[10]#*:}"
#    delay 0.2
#    termux-open-url "https://bangumi.tv/subject_search/${(j..)urlencti}?cat=1&legacy=1"
#  fi
#  local +x infobox=
#  local +x infobox_temp="{{Infobox animanga/Manga
#|原作= $auts
#|作者= 
#|脚本= 
#|分镜= 
#|作画= 
#|监制= 
#|制作= $auts
#|制作协力= 
#|出品= 
#|製作= 
#|责任编辑= 
#|开始= $ts
#|结束= $endts
#|连载杂志= 哔哩哔哩漫画
#|出版社= 
#|发售日= 
#|备注= 
#|ISBN= 
#|话数= 
#|别名={
#}
#}}"
#  say $infobox_temp | vipe | readeof infobox
#  if [[ "$infobox_temp" == "$infobox" || $#infobox == 0 ]]; then
#    return
#  fi
#  clip-or-print $infobox
#  if [[ -v getopts[-c] ]]; then
#    printj '(已复制wiki)...'
#    rlwrap head -n1 &>/dev/null
#  fi
#  local +x descbox=
#  printj ${^intro}——$'\n\n' $desc | readeof descbox
#  if [[ $#descbox -gt 0 ]]; then
#    clip-or-print $descbox
#  if [[ -v getopts[-c] ]]; then
#    printj '(已复制desc: '${descbox[1,10]}')'
#    rlwrap head -n1 &>/dev/null
#  fi
#  fi
#  say ${${${(j. .)tags}//、/ }//：/ }
#  local +x -a tagl=(${(j.、.)tags})
#  local +x coldesc=
#  printj ${^intro}—— $desc 【${^tagl}】 | readeof coldesc
#  clip-or-print $coldesc
#}
#
## options regions
#function gen:xml::b22 {
#  local +x itemfile=${0##*::}:item.lst
#  local -A getopts
#  zparseopts -A getopts -D -F - mints: maxts:
#  if (( $#==0 )); then
#    local -a +x regions=($b22_region_names)
#  else
#    (( ${argv[(I)^(${(j.|.)b22_region_names})|]} == 0 ))
#    local -a +x regions=($argv)
#  fi
#  local -a +x statuses=(end ing)
#  local +x wreg=; for wreg in $regions; do
#    local +x wsta=; for wsta in $statuses; do
#    local +x xmlfile=${0##*::}-$wreg-$wsta.atom.xml
#    local +x awkprog='$3 !~ /'${(j.|.)excluded_auts}'/ {
#      ts=$1
#      id=$10; sub(/^[^:]+:/,"",id)
#      ti=$2
#      aut=$3
#      intro=$4; gsub(/&/,"&amp;",intro); gsub(/</,"&lt;",intro); gsub(/>/,"&gt;",intro)
#      desc=$5; gsub(/&/,"&amp;",desc); gsub(/</,"&lt;",desc); gsub(/>/,"&gt;",desc); gsub(/\\n/,"<br>",desc)
#
#      hc=$6
#      vc=$7
#      sc=$8
#      cc=$9; split(cc, ccs, /\v/)
#      cchtml=""
#      if (length(ccs)>0) {
#        for (wcc in ccs) {
#          cchtml=cchtml "<img src=\"" ccs[wcc] "\">"
#        }
#      }
#
#      st=$11; sub(/^[a-z][a-z]:/,"",st)
#      ch=st; sub(/^.(:|)/,"",ch); sub(/:[-0-9.]+$/,"",st)
#
#      ym=$12; sub(/(:[-01]+|)$/,"",ym)
#      hot=$12
#      length(hot)>length(ym) ? sub(/^[01]:/,"",hot) : hot=0
#      style=$13; gsub(/ /,"",style)
#      tag=$14; gsub(/ /,"",tag)
#      subts=$15
#
#      print ts,ti,(urlprefix id),( \
#        ((length(intro)>0 && intro!=ti && intro!=desc) ? "<div class=\"intro\">——" intro "</div><br>" : "") \
#        "<div class=\"desc\">" desc "</div><br>" \
#        "<div class=\"tags\">" style ((length(style)>0 && length(tag)>0) ? "：" : "") tag (ym==1 ? "📖" : "") (hot==1 ? "🌟" : "") "</div>" \
#        "<div class=\"chapstat\">" (ch>0 ? ch "话" : "") (st=="'${b22_valid_status_notations[end]}'" ? "✅" : "") (subts>0 ? "（开刊时间：" strftime("%F",subts) "）" : "") "</div>" \
#        "<div class=\"gallery\">" \
#        (length(hc)>0 ? "<img src=\"" hc "\">" : "") \
#        (length(vc)>0 ? "<img src=\"" vc "\">" : "") \
#        (length(sc)>0 ? "<img src=\"" sc "\">" : "") \
#        cchtml "</div>" \
#      ),"html",$10,aut,"",(reg (ym==1 ? "|页漫" : "|条漫") (hot==1 ? "|殿堂" : ""))
#    }'
#    local +x bbuf=
#    query:item::${0##*::} -status $wsta -region $wreg | gawk -F $'\t' -v OFS=$'\t' -v urlprefix="https://manga.bilibili.com/detail/mc" -v reg=$wreg -f <(builtin printf %s $awkprog) |sfeed_atom|sed -e '3,4s%[Nn]ewsfeed%'${0##*::}-$wreg-$wsta'%'| readeof bbuf
#    if (( $#bbuf>0 )); then
#      local +x md5b= md5a=
#      if [[ -e "$xmlfile" ]]; then
#        printj $bbuf | sha256sum | awk '{print $1}' | IFS= read md5b
#        sha256sum -- $xmlfile | awk '{print $1}' | IFS= read md5a
#        if [[ "$md5b" != "$md5a" ]]; then
#          printj $bbuf|rw -- $xmlfile
#        else
#          say "$0($wreg::$wsta): nothing written.">&2
#        fi
#      else
#        printj $bbuf|rw -- $xmlfile
#      fi
#    else
#      say "$0($wreg::$wsta): no records.">&2
#    fi
#  done; done
#}
#
#readonly -a +x svcs=(b22 kkmh txac)
#
#function get:item::kkmh {
#  get:item::b22 -altsite kkmh "${(@)argv}"
#}
#function get:item::b22 {
#  zparseopts -A getopts -D -F - listbufstr: region: altsite:
#  if [[ -v getopts[-altsite] ]]; then
#    [[ ${svcs[(Ie)${getopts[-altsite]}]} -ne 0 ]]
#    local +x svc=${getopts[-altsite]}
#  else
#    local +x svc=${0##*::}
#  fi
#  local +x listfile=$svc:${${0%%::*}#*:}.lst
#  if (( $# == 0 )) && [[ -v getopts[-listbufstr] ]]; then
#    local -a +x listbufs=(${(ps.\n.)getopts[-listbufstr]})
#    [[ ${#listbufs} -gt 0 ]]
#    local -a +x bufs=()
#    while (( ${#listbufs} > 0 )); do
#      ## kkmh := ats, svc:id, ti, aut, reg:sta:eps, ep1relts, vc, hc, cat
#      ## kkmh := ats, ti, svcid, regstaeps, vc, hc, aut, ep1relts, cat
#      ## b22  := ats, ti, svc:id, reg:sta, vc, hc, sc
#      local -a +x listbuf=(${listbufs[1]})
#      listbuf=("${(@ps.\t.)listbuf[1]}")
#      local +x id=${listbuf[3]#$svc:}
#      [[ "$id" == <1-> ]]
#      local +x region=${listbuf[4]%%:*}; (( ${#region} > 0 ))
#      printj $'\r'$0"($id): ${listbuf[4]} ~" >&2
#      local -a +x buf=()
#      if [[ $svc == ${0##*::} ]]; then
#        if ! fetch:item::$svc $id | IFS= read -rA buf; then
#          say $'\r'$0"($id): ${listbuf[4]} !" >&2
#          return 1
#        fi
#        buf=("${(@ps.\t.)buf}")
#        buf[11]="${region}:${buf[11]}"
#      elif [[ $svc == kkmh ]]; then
#        if ! say ${listbufs[1]} | fetch-expand:list2item::$svc | IFS= read -rA buf; then
#          say $'\r'$0"($id): ${listbuf[4]} !" >&2
#          return 1
#        fi
#      fi
#      printj $'\r'$0"($id):${buf[11]} %" >&2
#      bufs+=("${(@pj.\t.)buf}")
#
#      unset buf
#      if [[ $#bufs == 14 ]]; then
#        printf '%s\n' ${(@)bufs} | zstrwan $listfile
#        printj $'\b.' >&2
#        bufs=()
#        _delay_next $#listbufs
#        say >&2
#      fi
#      shift listbufs
#    done
#    if [[ $#bufs -gt 0 ]]; then
#      printf '%s\n' ${(@)bufs} | zstrwan $listfile
#      say $'\b.' >&2
#      bufs=()
#    fi
#  elif (( $# > 0 )) && [[ $svc == ${0##*::} ]] && [[ -v getopts[-region] ]] && ! [[ -v getopts[-listbufstr] ]] && [[ "${b22_region_names[(Ie)${getopts[-region]}]}" -gt 0 ]]; then
#    local -a +x bufs=()
#    while (( $# > 0 )); do
#      local -a +x buf=()
#      printj $0"($1): (${(q)getopts[-region]})" >&2
#      if ! fetch:item::b22 $1 | IFS= read -rA buf; then
#        say $'\r'$0"($1): (${(q)getopts[-region]}) !" >&2
#        return 1
#      fi
#      buf=("${(@ps.\t.)buf}")
#      printj $'\r'$0"($1):${buf[11]} (${getopts[-region]}) %" >&2
#      buf[11]="${getopts[-region]}:${buf[11]}"
#      bufs+=("${(@pj.\t.)buf}")
#      unset buf
#      if [[ $#bufs == 14 ]]; then
#        printf '%s\n' ${(@)bufs} | zstrwan $listfile
#        printj $'\b.' >&2
#        bufs=()
#        _delay_next $#
#        say >&2
#      fi
#      shift
#    done
#    if [[ $#bufs -gt 0 ]]; then
#      printf '%s\n' ${(@)bufs} | zstrwan $listfile
#      say $'\b.' >&2
#      bufs=()
#    fi
#  else
#    return 128
#  fi
#}
#
#function query:list::b22 {
#  zparseopts -A getopts -D -F - region: status:; (($#<=2))
#  local +x mints=$1 maxts=$2
#  local -a +x patexps=('$3 ~ /^'${0##*::}':[0-9]+$/' '$4 !~ /:_$/')
#  patexps+=('! printed_ids[$3]++')
#  if [[ -v 1 ]]; then
#    [[ "$1" == <1-> ]]
#    mints=$((mints))
#    patexps+=('$1>='$mints)
#  fi; if [[ -v 2 ]]; then
#    [[ "$2" == <1-> ]]
#    maxts=$((maxts))
#    ((maxts>=mintts))
#    patexps+=('$1<='$maxts)
#  fi
#  local -aU +x regions=() statuses=()
#  if [[ -v getopts[-region] ]]; then
#    [[ ${#getopts[-region]} -gt 0 ]]
#    regions=("${(@s.,.)getopts[-region]}")
#    [[ ${#regions} -gt 0 ]]
#    if [[ ${0##*::} == b22 ]]; then
#      [[ ${regions[(I)^(${(j.|.)b22_region_names})|]} -eq 0 ]]
#      [[ ${regions[(I)${(j.|.)b22_region_names}]} -gt 0 ]]
#    elif [[ ${0##*::} == kkmh ]]; then
#      [[ ${(@)regions[(I)^(${(@j.|.)${(@k)kkmh_region_map}})|]} -eq 0 ]]
#      [[ ${(@)regions[(I)${(@j.|.)${(@k)kkmh_region_map}}]} -gt 0 ]]
#    else false txdm tbd
#    fi
#  fi
#  if [[ -v getopts[-status] ]]; then
#    [[ ${#getopts[-status]} -gt 0 ]]
#    statuses=("${(@s:,:)getopts[-status]}")
#    [[ ${#statuses} -gt 0 ]]
#    [[ ${statuses[(I)^(${(kj.|.)b22_valid_status_notations})|]} -eq 0 ]]
#    [[ ${statuses[(I)${(kj.|.)b22_valid_status_notations}]} -gt 0 ]]
#  fi
#  local -a +x actexps_status=() actexps=()
#  local -a +x actexps_region=()
#  if [[ $#statuses -gt 0 ]]; then
#    local +x walk_status=; for walk_status in $statuses; do
#      case $walk_status in
#        (end)
#          actexps_status+=('.');;
#        (ing)
#          actexps_status+=('~');;
#        (tba)
#          actexps_status+=('?');;
#        (err)
#          actexps_status+=('!');;
#        (*)
#          return 128;;
#      esac
#    done
#    actexps+=('$4 ~ /:['${(@j..)actexps_status}'](|:[0-9]+)$/')
#  fi
#  if [[ $#regions -gt 0 ]]; then
#    local +x walk_region=; for walk_region in $regions; do
#      actexps_region+=($walk_region)
#    done
#    actexps+=('$4 ~ /^('${(@j.|.)actexps_region}'):/')
#  fi
#  local +x awkprog=${(j. && .)patexps}
#  if [[ $#actexps -gt 0 ]]; then
#    awkprog+=" { if ( ${(j. && .)actexps} ) print }"
#  fi
#  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
#  zstdcat -- $listfile | grep -ve '^#' | tac | gawk -F $'\t' $awkprog | tac
#}
#functions[query:list::kkmh]=${functions[query:list::b22]}
#
#function get:list::b22 {
#  local -A getopts
#  zparseopts -A getopts -D -F - ord: maxpn: region: status:; (( $# <= 1 ))
#  integer +x startpn=${1:-1} maxpn=${getopts[-maxpn]:--1}
#  (( startpn>0 )); (( maxpn>=startpn||maxpn<0 ))
#  integer +x pn=$startpn
#  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
#  while ((pn<=maxpn||maxpn<0)); do
#    local +x listresp=
#    printj $0"($pn):? (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
#    fetch:list::${0%::*} -region "${getopts[-region]}" -status "${getopts[-status]}" ${getopts[-ord]:+-ord} ${getopts[-ord]} $pn | readeof listresp
#    if (( $#listresp==0 )); then if (( pn>1 )) || [[ $pn == 1 && "${getopts[-ord]}" == new && "${0%::*}" == kkmh ]]; then
#      say $'\r'$0"($pn):EOF (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
#      break
#    else
#      say $'\r'$0"($pn):! (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
#      return 1
#    fi; fi
#    if [[ -r "$listfile" && -f "$listfile" && -s "$listfile" ]]; then
#      integer +x listresp_ts="${listresp%%	*}"; (( listresp_ts>0 ))
#      local +x listresp_tbw=
#      ## orig: printj $listresp | cut -f 2-
#      printj "${(@pj.\n.)${(@)${(@ps.\n.)listresp}#*	}}" | anewer <(zstdcat -- $listfile | grep -ve '^#' | cut -f 2-) | readeof listresp_tbw
#      if (( ${#listresp_tbw} > 1 )); then
#        printj $'\r'$0"($pn):>>" >&2
#        ## orig: printj $listresp_tbw | sed -e '/..*/s%^%'$listresp_ts'%'
#        printf '%s\n' ${listresp_ts}$'\t'${(@)^${(@ps.\n.)listresp_tbw}} | zstd | rw -a -- $listfile
#      else
#        say $'\r'$0"($pn):>< (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
#        break
#      fi
#    else
#      printj $'\r'$0"($pn):> " >&2
#      printj $listresp | zstd | rw -- $listfile
#    fi
#    printj ". (${(q)getopts[-region]}:${(q)getopts[-status]})" >&2
#    pn+=1
#    say >&2
#  done
#}
#functions[get:list::kkmh]=${functions[get:list::b22]}
#
#function _delay_next {
#  [[ -v pn ]] || local +x pn=$1
#  if [[ -z "$nowait" ]] && ((pn<=maxpn||maxpn<=0)); then
#    if (( pn%$((RANDOM%4+1)) == 0 )); then
#      integer +x sleepint=$((5+RANDOM%15))
#    else
#      integer +x sleepint=$((RANDOM%5))
#    fi
#    if ((sleepint>0)); then
#      printj " sleep($sleepint)" >&2
#      delay $sleepint
#      local +x erase_sleepprompt=
#      repeat 9+$#sleepint {
#        erase_sleepprompt+=$'\b'
#      }
#      repeat 9+$#sleepint {
#        erase_sleepprompt+=' '
#      }
#      printj $erase_sleepprompt>&2
#      unset erase_sleepprompt
#    fi
#    unset sleepint
#  fi
#}
#
#local -a +x curl_hdr_flag_arrplh=(-H)
#
#local -a +x b22_restapi_http_hdr=(
#  'accept: application/json, text/plain, */*'
#  'content-type: application/json;charset=UTF-8'
#)
#b22_restapi_http_hdr=(${curl_hdr_flag_arrplh:^^b22_restapi_http_hdr})
#source "${ZSH_ARGZERO%/*}/mangarss.zsh.inc"
#function fetch:item::b22 {
#  integer +x id=$1; (( $# == 1 && id > 0 ))
#  local +x jsonresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fios $b22_restapi_http_hdr -H 'referer: https://manga.bilibili.com/detail/mc'$id \
#    --data-raw '{"comic_id":'$id'}' \
#    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ComicDetail?device=pc&platform=web' | readeof jsonresp
#  integer +x ts=$EPOCHSECONDS
#  printj $jsonresp | pipeok gojq -r --arg ts "$ts" --arg fn_name "$0" --arg id "$id" --arg excluded_chapti_regex "(${(j:|:)excluded_chapti_regex})" -f <(builtin printf %s 'def resp_ok: if has("data") and has("code") and (.code==0) then
#  .data
#else
#  $fn_name+"("+$id+"): REST API - response error\n" | halt_error
#end;
#
#def sanitstr: if ((type)=="string") then . else
#  if ((type)=="null") then "" else
#    tostring
#  end
#end|gsub("\\\\";"\\\\")|gsub("\n"; "\\n")|gsub("\t";"\\t")|gsub("\u000b";"");
#
#def item_ok: if (length>0
#  and has("title") and (.title|length>0) and has("introduction")
#  and has("author_name")
#  and has("ep_list") and has("last_ord") and has("is_finish")
#  and has("vertical_cover") and has("horizontal_cover") and has("square_cover") and has("chapters")
#  and has("evaluate") and has("styles") and has("tags")
#  and has("comic_type")
#  and has("type")) then .
#else
#  $fn_name+"("+$id+"): REST API - null or irregular response\n" | halt_error
#end;
#
#def filter_valid_chaps: select((.ord>=1) and ((.title | test($excluded_chapti_regex; "")) or (.short_title | test($excluded_chapti_regex; "")) | not));
#
#def recheck_ts_status: if (.is_finish==-1) or (.ep_list|length==0) or (.is_finish == 0 and ([.ep_list[] | filter_valid_chaps] | length==0)) then
#  .is_finish = -1 | .__secondary_ts = null | if ((.release_time|length>=8)
#     and (.release_time|length<=10)
#     and (.release_time+" +0800"|strptime("%Y.%m.%d %z")|mktime))
#  then
#    .__major_ts = (.release_time+" +0800" | strptime("%Y.%m.%d %z") | mktime)
#  else
#    if (.ep_list|length>0) then
#      .__major_ts = (.ep_list | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
#    else
#      .__major_ts = null
#    end
#  end
#else
#  if (.is_finish==0) then
#    .__major_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = null
#  else
#    if (.is_finish==1) then
#      if ([.ep_list[] | filter_valid_chaps]|length>0) then
#        .__major_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[-100:] | sort_by(.pub_time) | .[-1] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = ([.ep_list[] | filter_valid_chaps] | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
#      else
#        .__major_ts = (.ep_list | sort_by(.ord) | .[-100:] | sort_by(.pub_time) | .[-1] | .pub_time+" +0800" | strptime("%F %T %z") | mktime) | .__secondary_ts = (.ep_list | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0] | .pub_time+" +0800" | strptime("%F %T %z") | mktime)
#      end
#    else
#      $fn_name+"("+$id+"): unrecognised value on is_finish field.\n" | halt_error
#    end
#  end
#end;
#
#def check_redundant_intro: if ((.introduction|length>0)
#   and ((.title == .introduction)
#     or ((.evaluate|length>0) and (.introduction as $string | .evaluate | contains($string)))))
#  then
#    .introduction = ""
#else
#  .
#end;
#
#resp_ok | item_ok | recheck_ts_status | check_redundant_intro | [
#  (.__major_ts|sanitstr),
#  (.title|sanitstr),
#  ([.author_name[]|sanitstr]|join("、")),
#  (.introduction|sanitstr),
#  (.evaluate|sanitstr),
#  (.horizontal_cover),(.vertical_cover),(.square_cover),(if (.chapters|length>0) and ([.chapters[]|select(.cover|length>0)]|length>0) then
#    [.chapters[]|select(.cover|length>0)]|sort_by(.ord)|[.[].cover]|unique|join("\u000b")
#  else "" end),
#  ("b22:"+$id),(if (.type==0) then
#    if (.is_finish==-1) then
#      "?"
#    else
#      if (.is_finish==1) then
#        ".:"+(.last_ord|tostring)
#      else
#        "~:"+(.last_ord|tostring)
#      end
#    end
#  else "_" end),
#  (.comic_type|tostring)+(if has("is_star_hall") then ":"+(.is_star_hall|tostring) else "" end),
#  (if (.styles|length>0) then
#     [.styles[]|sanitstr]|join("、")
#   else "" end),
#  (if (.tags|length>0) then [.tags[]|.name|sanitstr]|join("、") else "" end),
#  (.__secondary_ts|sanitstr)
#]|join("\t")')
#}
#
#function get:nav-banner::b22 {
#  local -A getopts
#  zparseopts -A getopts -D -F - altsite:
#  (( $#==0 ))
#  if [[ ${#getopts[-altsite]} -ne 0 ]]; then
#    local +x svc=${getopts[-altsite]}
#  else
#    local +x svc=${0##*::}
#  fi
#  local +x listfile=$svc:${${0%%::*}#*:}.lst
#  local +x resp=
#  fetch:${${0%%::*}#*:}::$svc | readeof resp
#  local +x ts=$EPOCHSECONDS
#  if (( $#resp>0 )); then
#    if [[ -e $listfile ]]; then
#      local +x tbw=
#      printj $resp | anzst -pipe 'cut -f2-' -- $listfile | readeof tbw
#      read
#      if (( $#tbw >0 )); then
#        local -a +x tbw=(${(ps.\n.)tbw})
#        printf %s'\n' $ts$'\t'${(@)^tbw} | zstd | rw -a -- $listfile
#      fi
#    else
#      local -a +x resp=(${(ps.\n.)resp})
#      printf %s'\n' $ts$'\t'${(@)^resp} | zstd -qo $listfile
#    fi
#  fi
#}
#
#function fetch:nav-banner::b22 {
#  local +x jsonresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $b22_restapi_http_hdr \
#    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/Banner?device=pc&platform=web' \
#    -H 'accept: application/json, text/plain, */*' \
#    -H 'accept-language: zh-CN,zh;q=0.9' \
#    -H 'content-type: application/json;charset=UTF-8' \
#    --data-raw '{"platform":"pc"}' | readeof jsonresp
#  integer +x ts=$EPOCHSECONDS
#  printj $jsonresp | gojq -r --arg site ${0##*::} '
#def resp_ok: if has("code") and has("data") and (.data|length>0) and (.code==0) then
#  .data
#else
#  halt_error
#end;
#
#resp_ok | .[] | select((.jump_value|match("^bilicomic://reader/([0-9]+)")|.captures.[0].string)|length>0)|[$site+":"+(.jump_value|match("^bilicomic://reader/([0-9]+)")|.captures.[0].string),.img]|join("\t")'
#}
#
#function fetch:list::b22 {
#  local -A getopts
#  zparseopts -A getopts -D -F - region: status:
#  integer +x b22_list_area_id=
#  case "${getopts[-region]}" in
#    (cn) b22_list_area_id=1;;
#    (jp) b22_list_area_id=2;;
#    (kr) b22_list_area_id=6;;
#### (all) b22_list_area_id=-1;;
#    (*) return 128;;
#  esac
#  integer +x b22_list_order= b22_list_is_finish=
#  case "${getopts[-status]}" in
#    (ing) b22_list_order=3; b22_list_is_finish=0;;
#    (end) b22_list_order=1; b22_list_is_finish=1;;
#    (all)      b22_list_order=3; b22_list_is_finish=-1;;
#    (*) return 128;;
#  esac
#  (( $# == 1 )); [[ "$1" == <1-> ]]; 1=$((argv[1]))
#  local +x jsonresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $b22_restapi_http_hdr \
#    -H "referer: https://manga.bilibili.com/classify?styles=-1&areas=$b22_list_area_id&status=$b22_list_is_finish&prices=-1&orders=$b22_list_order" \
#    --data-raw '{"style_id":-1,"area_id":'$b22_list_area_id',"is_finish":'$b22_list_is_finish',"order":'$b22_list_order',"page_num":'$1',"page_size":18,"is_free":-1}' \
#    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ClassPage?device=pc&platform=web' | readeof jsonresp
#  integer +x ts=$EPOCHSECONDS
#  # listts, title, id, region[:if_finish|vcomic], vc, hc, sc
#  printj $jsonresp | pipeok gojq -r --arg ts "$ts" --arg fn_name "$0" --arg pn "$1" --arg region "${getopts[-region]}" --arg excluded_chapti_regex "(${(j:|:)excluded_chapti_regex})" -f <(builtin printf %s 'def listitem_ok: has("type") and has("season_id") and has("horizontal_cover") and has("vertical_cover") and has("square_cover") and has("last_ord") and has("is_finish") and has("title");
#def sfesc: gsub("\n"; "")|gsub("\t"; " ");
#
#def print_item(is_vcomic): if (is_vcomic==0) then
#  [$ts,(.title|sfesc),"b22:"+(.season_id|tostring),$region+":"+(
#    if (.is_finish==0) then
#      if (.last_ord<1) then "!"
#      else "~"
#      end
#    else
#      if (.is_finish==-1) then "?"
#      else
#        if (.is_finish==1) then "."
#        else
#          $fn_name+"("+$pn+"): unrecognised is_finish value "+.is_finish+"\n" | halt_error
#        end
#      end
#    end),(.vertical_cover|tostring),(.horizontal_cover|tostring),(.square_cover|tostring)]|join("\t")
#else
#  if (is_vcomic==1) then
#    [$ts,(.title|sfesc),"b22:"+(.season_id|tostring),$region+":_",(.vertical_cover|tostring),(.horizontal_cover|tostring),(.square_cover|tostring)]|join("\t")
#  else
#    $fn_name+"("+$pn+"): REST API - unknown type: "+(.|tostring)+"\n" | halt_error
#  end
#end;
#
#if (.code==0) and has("data") then
#  if (.data|length>0) then
#    .data[] | if listitem_ok then
#      print_item(.type)
#    else
#      $fn_name+"("+$pn+"): REST API - item schema mismatch: "+(.|tostring)+"\n" | halt_error
#    end
#  else
#    if ($pn==1) then
#      $fn_name+"("+$pn+"): REST API - null response\n"|halt_error
#    else
#      halt
#    end
#  end
#else
#  if has("code") then
#    $fn_name+"("+$pn+"): REST API - response error "+(.code|tostring)+"\n" | halt_error
#  else
#    $fn_name+"("+$pn+"): REST API - response error\n" | halt_error
#  end
#end')
#}
#
#local -A kkmh_region_map
#kkmh_region_map=(
#  cn 2
#  kr 3
#  jp 4
#)
#local -A kkmh_ord_map
#kkmh_ord_map=(
#  new 3
#  rec 1
#  hot 2
#)
#local -A kkmh_status_map
#kkmh_status_map=(
#  ing 1
#  end 2
#)
#local -a +x kkmh_restapi_http_hdr=(
#  'accept: application/json, text/plain, */*'
#  'accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7'
#  'user-agent-pc: PCKuaikan/1.0.0/100000(unknown;unknown;Chrome;pckuaikan;1920*1080;0)'
#)
#kkmh_restapi_http_hdr=(${curl_hdr_flag_arrplh:^^kkmh_restapi_http_hdr})
#function fetch:list::kkmh {
#  integer +x ps=48
#  local -A getopts; zparseopts -A getopts -D -F - region: status: ord:
#  (( $# == 1 )); [[ "$1" == <1-> ]]; 1=$((argv[1]))
#  ## region is requred, cause the response doesnot incl region info.
#  [[ -v getopts[-region] ]]
#  [[ ${(@)${(@k)kkmh_region_map}[(Ie)${getopts[-region]}]} != 0 ]]
#
#  [[ -v getopts[-status] ]]
#  [[ ${(@)${(@k)kkmh_status_map}[(Ie)${getopts[-status]}]} != 0 ]]
#
#  if [[ -v getopts[-ord] ]]; then
#    [[ ${(@)${(@k)kkmh_ord_map}[(Ie)${getopts[-ord]}]} != 0 ]]
#  else
#    getopts[-ord]=new
#  fi
#
#  local +x jsonresp=; retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $kkmh_restapi_http_hdr \
#    --referer 'https://www.kuaikanmanhua.com/tag/0' \
#    --url "https://www.kuaikanmanhua.com/search/mini/topic/multi_filter?page=$1&size=$ps&tag_id=0&update_status=${kkmh_status_map[${getopts[-status]}]}&pay_status=0&label_dimension_origin=${kkmh_region_map[${getopts[-region]}]}&sort=${kkmh_ord_map[${getopts[-ord]}]}" | readeof jsonresp
#  integer +x ts=$EPOCHSECONDS
#  printj $jsonresp | gojq -r --arg ts $ts --arg status ${b22_valid_status_notations[${getopts[-status]}]} --arg region ${getopts[-region]} --arg pn $1 --arg ord ${getopts[-ord]} --arg fn_name $0 -f <(builtin printf %s 'def resp_ok: if has("code") and (.code==200) and has("total") then
#  if (.hits.topicMessageList|length>0) then .hits.topicMessageList[]
#  else empty end
#else
#  $fn_name+"("+$region+"#"+$ord+":"+$pn+")"|halt_error
#end;
#
#resp_ok | [$ts,
#(.title|gsub("[[:cntrl:]]"; "")|gsub("(^  *|  *$)";"")|gsub("   *";" "|gsub("\\\\";"\\\\"))),
#("kkmh:"+(.id|tostring)),
#($region+":"+$status)+(if $status=="." then ":"+(.comics_count|tostring) else "" end),
#(.vertical_image_url|sub("-w[0-9]{3,4}(|\\.w)$";"")),
#(.cover_image_url|sub("-w[0-9]{3,4}(|\\.w)$";"")),
#(.author_name|gsub("[[:cntrl:]]"; "")|gsub("(^  *|  *$)";"")|gsub("   *";" ")|gsub("(?<a>[^+])[+](?<b>[^+])"; (.a)+"、"+(.b))|gsub("\\\\";"\\\\")),
#(.first_comic_publish_time),
#(if (.category|length>0) then .category|join("、") else "" end)
#] | join("\t")')
#}
#function get:list::kkmh {
#  local -A getopts
#  zparseopts -A getopts -D -F - nonstop maxpn: region: status: ord:; (( $# <= 1 ))
#  integer +x startpn=${1:-1} maxpn=${getopts[-maxpn]:--1}
#  (( startpn>0 )); (( maxpn>=startpn||maxpn<0 ))
#  [[ ${(@)${(@k)kkmh_ord_map}[(Ie)${getopts[-ord]}]} != 0 ]]
#  integer +x pn=$startpn
#  local +x listfile=${0##*::}:${${0%%::*}#*:}.lst
#  while ((pn<=maxpn||maxpn<0)); do
#    local +x listresp=
#    printj $0"($pn):? (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#    fetch:list::${0##*:} -region "${getopts[-region]}" -status "${getopts[-status]}" -ord "${getopts[-ord]}" $pn | readeof listresp
#    if (( $#listresp==0 )); then if (( pn>1 )) || [[ $pn == 1 && "${getopts[-ord]}" == new ]]; then
#      say $'\r'$0"($pn):EOF (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#      break
#    else
#      say $'\r'$0"($pn):! (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#      return 1
#    fi; fi
#    if [[ -r "$listfile" && -f "$listfile" && -s "$listfile" ]]; then
#      integer +x listresp_ts="${listresp%%	*}"; (( listresp_ts>0 ))
#      local +x listresp_tbw=
#      ## orig: printj $listresp | cut -f 2-
#      printj "${(@pj.\n.)${(@)${(@ps.\n.)listresp}#*	}}" | anewer <(zstdcat -- $listfile | grep -ve '^#' | cut -f 2-) | readeof listresp_tbw
#      if (( ${#listresp_tbw} > 1 )); then
#        ## orig: printj $listresp_tbw | sed -e '/..*/s%^%'$listresp_ts'%'
#        printf '%s\n' ${listresp_ts}$'\t'${(@)^${(@ps.\n.)listresp_tbw}} | zstd | rw -a -- $listfile
#        say $'\r'$0"($pn):>> (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#      else
#        say $'\r'$0"($pn):>< (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#        if [[ ! -v getopts[-nonstop] ]]; then break; fi
#      fi
#    else
#      printj $listresp | zstd | rw -- $listfile
#      printj $'\r'$0"($pn):>. (${(q)getopts[-region]}${getopts[-ord]:+#}${getopts[-ord]}:${(q)getopts[-status]})" >&2
#    fi
#    pn+=1
#  done
#}
#
#function fetch:nav-banner::kkmh {
#  local +x htmlresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie \
#    --url 'https://www.kuaikanmanhua.com/' \
#    -H 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
#    -H 'accept-language: zh-CN,zh;q=0.9' | readeof htmlresp
#  integer +x ts=$EPOCHSECONDS
#  local +x jsresp=
#  printj ${${${${htmlresp##*,bannerList:\[}%%\]*}//\&quot;/\"}//\\u002[Ff]/\/} | readeof jsresp
#  [[ $#jsresp -ne 0 ]]; [[ $#jsresp -ne $#htmlresp ]]
#  local +x jsspl=
#  printj $jsresp | grep -Eoe '(target_id:"[0-9]+"|image_url:"http[^"]+")' | readeof jsspl
#  local -a +x jsspl=(${(ps.\n.)jsspl})
#  [[ $#jsspl -ne 0 && $(($#jsspl%2)) -eq 0 ]]
#  local -a +x epids=() imguris=()
#  printf '%s\n' $jsspl | sed -nEe '/^target_id:"[0-9]+"$/ s%(.+:|")%%gp' | readarray epids
#  printf '%s\n' $jsspl | sed -nEe '/^image_url:"http[^"]+"$/ s%(^image_url:|")%%gp' | readarray imguris
#  [[ $#epids -eq $#imguris ]]
#  while (( $#epids!=0 )); do
#    integer +x serid=
#    conv:id:ep2serial::${0##*::} ${epids[1]} | IFS= read -r serid
#    say ${0##*::}:$serid $'\t' ${imguris[1]}
#    shift epids
#    shift imguris
#  done
#}
#
#function conv:id:ep2serial::kkmh {
#  (( $#==1 ))
#  [[ "$1" == <1-> ]]
#  integer +x epid=$((argv[1]))
#  local +x htmlresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie \
#    --url 'https://www.kuaikanmanhua.com/web/comic/'$epid'/' \
#    -H 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
#    -H 'accept-language: zh-CN,zh;q=0.9' | readeof htmlresp
#  [[ $#htmlresp -ne 0 ]]
#  local +x uri=
#  printj $htmlresp | pup -p 'div.titleBox h3.title a:nth-of-type(2)' 'attr{href}' | IFS= read -r uri
#  [[ "$uri" == /web/topic/<1-> ]]
#  integer +x id=${uri##*/}
#  say $id
#}
#
#function get:nav-banner::kkmh {
#  ${0%::*}::b22 -altsite ${0##*::}
#}
#
#function fetch-expand:list2item::kkmh {
#  while :; do
#    local -a +x listbuf=()
#    IFS= read -rA listbuf || break
#    listbuf=("${(@ps.\t.)listbuf}")
#    if [[ $#listbuf == 0 ]]; then break; fi
#    ## kkmh := ats, ti, svcid, regstaeps, vc, hc, aut, ep1relts, cat
#    [[ "${listbuf[3]}" == ${0##*::}:<1-> ]]
#    integer id=${listbuf[3]#${0##*::}:}
#    let $id
#    local +x ti=${(Q)listbuf[2]}
#    let $#ti
#    local +x jsonresp=
#    retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fie $kkmh_restapi_http_hdr --url 'https://www.kuaikanmanhua.com/search/web/complex' --url-query q=$ti --url-query f=3 \
#    --referer 'https://www.kuaikanmanhua.com/sou/%20' | readeof jsonresp
#    local +x reply=
#    printj $jsonresp | gojq --arg id $id --arg region "${listbuf[4]%%:*}" --arg aut "${listbuf[7]}" -r -f <(builtin printf %s 'def resp_ok: if has("code") and (.code==200) then
#  if (.data.topics.hit|length>0) then .data.topics.hit[]
#  else empty|halt end
#else
#  empty|halt_error
#end;
#
#def sanitstr: gsub("(^  *|  *$)";"")|gsub("[\t ]+";" ")|gsub("\t";"")|gsub("\\\\";"\\\\")|gsub("\n";"\\n")|gsub("[[:cntrl:]]";"");
#
#resp_ok | if ([select((.id|tostring)==$id)]|length==1) then
#  select((.id|tostring)==$id) | [
#    (.first_comic_publish_time|sub("\\.[0-9]{3,}\\+(?<zh>[0-9]{2}):(?<zm>[0-9]{2})$";"+"+(.zh)+(.zm))|strptime("%FT%T%z")|mktime),
#    (.title|sanitstr),
#    ($aut),
#    (.recommend_text as $intro | if (.description|contains($intro)|not) and (.title|contains($intro)|not) then .recommend_text|sanitstr else "" end),
#    (.description|sanitstr),
#    (.cover_image_url|sub("-w[0-9]{3,4}(|\\.w)(|\\.(jpg|png))$";"")),
#    (.vertical_image_url|sub("-w[0-9]{3,4}(|\\.w)(|\\.(jpg|png))$";"")),
#    ("kkmh:"+(.id|tostring)),
#    ($region+":"+(if (.update_status==2) then "." else
#      if (.update_status==1) then "~"
#      else "?"
#      end
#    end)+(if (.update_status==2) then ":"+(.comics_count|tostring) else "" end)),
#    (if (.category|length>0) then .category|join("、")|sanitstr else "" end),
#    (.sentence_desc|sanitstr|gsub(" ";"、"))
#  ] | join("\t")
#else
#  empty|halt
#end') | readeof reply
#    local -a +x replies=(${(ps.\n.)reply}) reconst_replies=()
#    if let $#replies; then
#      while (( $#replies != 0 )); do
#        local -a +x fcrepl=() reconst_reply=("${(@ps.\t.)${(@)replies[1]}}")
#        fetch-complement:item::kkmh $id | IFS= read -rA fcrepl
#        fcrepl=("${(@ps.\t.)fcrepl}")
#        local -a +x -U cats=(${(@s.、.)${(@)reconst_reply[10]}})
#        local -a +x -U tags=($cats ${(@s.、.)${(@)fcrepl[1]}})
#        if (( $#tags>$#cats )); then
#          tags=(${(@)tags:$#cats})
#        else
#          tags=()
#        fi
#        if [[ "${fcrepl[2]}" != '+' ]]; then
#          cats+=('投稿')
#          reconst_reply[10]=${(j.、.)cats}
#        fi
#        if (( $#tags )); then
#          if (( ${#reconst_reply[11]} )); then
#            reconst_reply[11]+=、
#          fi
#          reconst_reply[11]+=${(j.、.)tags}
#        fi
#        reconst_replies+=("${(@pj.\t.)reconst_reply}")
#        say "${(@pj.\t.)reconst_reply}"
#        shift replies
#      done
#      let $#reconst_replies
#    else
#      false left unimplmented
#    fi
#  done
#}
#
#function fetch-complement:item::kkmh {
#  integer +x id=$1; (( $# == 1 && id > 0 ))
#  local +x htmlresp=
#  retry -w $((RANDOM%(${TMOUT:-19}+1))) 2 pipeok fios https://m.kuaikanmanhua.com/mobile/$id/list/ | readeof htmlresp
#  integer +x ts=$EPOCHSECONDS
#  (( $#htmlresp!=0 ))
#  local +x tag=
#  printj $htmlresp | html2data - 'div.classifications span' | readeof tag
#  tag=${${tag%[
#	 ]##}//
#/、}
#  if [[ $htmlresp == *[_a-zA-Z]([_a-zA-Z]|)'.signing_status="签约作品"'* ]]; then
#    local +x qy='+'
#  else
#    local +x qy=
#  fi
#  say $tag${qy:+	}${qy}
#}
#
#main "${(@)argv}"
