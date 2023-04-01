#!/usr/bin/env shorthandzsh
alias furl='command curl -qgsf --compressed'
alias fie='ponsucc -n 3 -w 40 -m 22,56 furl -A "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv 11.0) like Gecko"'
alias frest='ponsucc -n 3 -w 20 -m 22,56 furl'
builtin zmodload -Fa zsh/datetime p:EPOCHSECONDS
builtin zmodload -Fa zsh/zutil b:zparseopts

main() {
  local -A getopts
  builtin zparseopts -A getopts -D -F - daterootdir: || return 128
  if [[ -v getopts[-datarootdir] ]]; then
    cd "${getopts[datarootdir]}"
  fi
  if (( $# == 0 )); then usage; exit 128; fi

  case "$1" in
    (u|update)
      shift; update "${(@)argv}";;
    (us|update-and-syncxml)
      shift; update-and-syncxml "${(@)argv}";;
    (getlist*)
      $argv;;
    (*)
      usage; exit 128;;
  esac

  if [[ -v getopts[-datarootdir] ]]; then
    cd "$OLDPWD"
  fi
}

update-and-syncxml() {
  while (( $# > 0 )); do
    local +x before_md5=- after_md5=
    if [[ -f "$1.sfeed" && -r "$1.sfeed" ]]; then
      md5.b32x < "$1.sfeed" | read -r before_md5
    fi
    if update "$1"; then
      md5.b32x < "$1.sfeed" | read -r after_md5
      if [[ "$before_md5" != "$after_md5" ]] || ! xmllint --recover --noent --nonet --noblanks --encode utf-8 --dropdtd --nsclean --nocatalogs --nocdata --oldxml10 -- "$1.atom.xml" &>/dev/null; then
        zstdcat "$1.sfeed" | sfeed_atom | dasel put -r xml -t string -s '.feed.author.name' -v "$1" | dasel put -r xml -t string -s '.feed.title.#text' -v "$1" | rw "$1.atom.xml"
      fi
    else
      return $?
    fi
    shift
  done
}

update() {
  while (( $# != 0 )); do
    local +x -i actpn= pn=${pn:-1}
    while :; do
      local -a these_ids=()
      local +x reply
      eval getlist.${(q)1} '$pn' | readeof reply
      if [[ -e $1.sfeed ]]; then
        printj $reply | cut -f5 | grep -ve '^[ ]*$' \
        | anewer <(zstdcat -- $1.sfeed | cut -f6) | readarray these_ids
      else
        printj $reply | cut -f5 | readarray these_ids
      fi || if [[ $?==5 ]]; then
          break
        else
          return 1
        fi
      these_ids=(${(@)these_ids})
      local +x sfeed_tbw=
      printj $reply | expand.list.$1 $these_ids | readeof sfeed_tbw
      if (( pn != 1 )) && (( ${#sfeed_tbw} <= 6 )); then break; fi
      printj $sfeed_tbw | tac | zstd | rw -a -- $1.sfeed
      say '['$1']'page:$pn>&2
      #if (( actpn > pn )); then
      #  pn=$((actpn+1))
      if [[ "$1" == txdm-noncomm ]]; then
        pn+=$((RANDOM%20))
      else
        pn+=1
      fi
      if (( pn%8 == 0 )); then
        sleep $(( 5+RANDOM%15 ))
      else
        sleep $(( 1+RANDOM%2 ))
      fi
    done
    shift
  done
}

expand.list.txdm-newserial() {
  local +x readline=; while IFS= read -r readline; do
    if [[ ${#readline} -eq 0 ]]; then break; fi
    local -a columns=(${readline})
    columns=("${(@ps:\t:)columns}")
    if [[ ${#columns[5]#kkmh:} -gt 0 ]] && [[ ${(@)argv[(Ie)${columns[5]}]} -gt 0 ]]; then
      local +x htmlreply= desc= vcover=
      local -a auts
      fie "https://m.ac.qq.com/comic/index/id/${columns[2]##?*/id/}" | rw | uconv -x ':: NFKC; [[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] >;' | readeof htmlreply
      printj $htmlreply| pup 'html head meta[property=og:description]' 'attr{content}'|readeof desc
      if ! {printj $htmlreply | pup 'html head meta[property=og:image]' 'attr{content}' | IFS= read -r vcover}
      then
        vcover=
      fi
      local +x -i ts=$EPOCHSECONDS
      columns[3]="<div>${${${${${${desc//</&lt;}//>/&gt;}//&/&amp;}//
/<br>}//	/ }//\\}</div>${vcover:+<div><img src=\"}${vcover}${vcover:+\"></div>}${columns[3]}"
      printj $htmlreply | pup '.head-info-author .author-list' 'text{}' | sed -e '/^[ \t]*$/d;s%^[\t ]*%%;s%[ \t]*$%%' | readarray auts
      say $ts$'\t'"${(@pj:\t:)columns}"$'\t'"${${${(@pj:、:)auts//
}//	}//\\}"$'\t\t'
    else
      continue
    fi
  done
}

expand.list.txdm-noncomm() {
  printf '%s\n' $@ | shuf | readarray argv
  argv=($argv)
  while (( $# > 0 )); do
    local +x htmlreply= desc= ti=
    local -a columns=()
    local +x -i id=${1#txdm:}
    if (( id==0 )); then
      return 4
    fi
    fie "https://m.ac.qq.com/comic/index/id/$id" | rw | uconv -x ':: NFKC; [[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] >;' | readeof htmlreply
    local +x -i ts=$EPOCHSECONDS
    columns[1]=$ts
    printj $htmlreply | pup -p 'html head meta[property=og:title]' 'attr{content}' | IFS= read -r ti || {
      local +x reply=
      if printj $htmlreply | html2data - 'div.err-type2' | grep -oe 拐跑了 | IFS= read reply && (( ${#reply}>0 )); then
        :
      else
        say irr-resp:$id>&2
      fi
      shift; continue
    }
    columns[2]=${${ti//	}//\\}
    if (( ${#columns[2]}==0 )); then shift; continue; fi
    printj $htmlreply | html2data - 'div.head-info-desc' | readeof desc
    printj $htmlreply | pup 'html head meta[property=og:image]' 'attr{content}' | IFS= read -r vcover
    columns[4]="<div>${${${${${${desc//</&lt;}//>/&gt;}//&/&amp;}//
/<br>}//	/ }//\\}</div>${vcover:+<div><img src=\"}${vcover}${vcover:+\"></div>}"
    printj $htmlreply | pup '.head-info-author .author-list' 'text{}' | sed -e '/^[ \t]*$/d;s%^[\t ]*%%;s%[ \t]*$%%' | readarray auts
    columns[7]=${${${${(@pj:、:)auts}//	}//
}//\\}
    columns[5]=html
    columns[6]=txdm:$id
    columns[3]="https://ac.qq.com/Comic/comicInfo/id/$id"
    say "${(@pj:\t:)columns}"
    shift
  done
}

getlist.txdm-noncomm() {
  local +x -i argpn=${1:-1} ps=200
  local +x -i \
    sed_begin_linenum=$(( (argpn-1)*ps+1 ))
    sed_end_linenum=$(( argpn*ps+2 ))
  if [[ -e txdm-newserial.sfeed ]]; then
    local +x knownids
    zstdcat txdm-newserial.sfeed | \
    cut -f6 | \
    LC_ALL=C sort -rk6V,6 | \
    sed -ne $sed_begin_linenum,${sed_end_linenum}p | \
    readeof knownids
    local -a knownids=(${(ps:\n:)knownids})
    knownids=(${(@)knownids#txdm:})
    local +x -i num_knownids=${#knownids}
    local +x -a unknownids=()
    if (( num_knownids > 1 )); then
      local +x -i walkid= counter=
      for walkid in $knownids; do
        counter+=1
        if (( counter>=num_knownids || walkid<600000)); then break; fi
        walkid=$(( walkid - 1 ))

        while (( ${(@)knownids[(ie)$walkid]}>num_knownids)); do
          unknownids+=($walkid)
          say txdm:$walkid
          walkid=$(( walkid - 1 ))
          if (( walkid<600000 )); then break 2; fi
        done
      done
    fi
  else
    return 44
  fi
}

getlist.txdm-newserial() {
  local +x -i argpn=${1:-1} ps=12
  local +x htmlreply=
  local -a ids=()
  fie \
    -H 'accept: text/html, application/xhtml+xml, application/xml, */*' \
    -H 'accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7' \
    -H 'referer: https://ac.qq.com/Comic/all/search/time/page/1' \
    --url 'https://ac.qq.com/Comic/all/search/time/page/'$argpn | readeof htmlreply
  local +x reply=
  printj $htmlreply | pup '.ret-works-cover > a' 'attr{href}' | readeof reply
  local -a ids=(${(ps:\n:)reply})
           ids=(${(@)ids##?*/id/})
  if (( argpn == 1 && ${#ids} == 0 )) || (( ${#ids} > ps )); then
    : needs maintain
    return 1
  fi
  local -a {title,vcover}s
  printj $htmlreply | pup '.ret-works-cover > a' 'attr{title}' | readarray titles
  printj $htmlreply | pup '.ret-works-cover > a > img' 'attr{data-original}' | readarray vcovers
  if ! (( ${#ids} == ${#titles} && ${#ids} == ${#vcovers} )); then
    return 1
  fi
  if (( ${#ids} > 0 )); then
    local +x -i counter=
    while (( counter < ${#ids} )); do
      counter+=1
      local -a column=("${${titles[$counter]//\\}//	/ }" "https://ac.qq.com/Comic/comicInfo/id/${ids[$counter]}" "<div><img src=\"${vcovers[$counter]%/420}/0\"></div>" html "txdm:${ids[counter]}")
      say "${(@pj:\t:)column}"
    done
  fi
}

if [[ $# -ne 0 ]]; then
  main "${(@)argv}"
else
  main us txdm-newserial txdm-noncomm
fi
