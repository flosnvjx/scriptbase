#!/usr/bin/env shorthandzsh
alias furl='command curl -qgsf'
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
    local +x -i actpn= pn=1
    while (( pn <= ${maxpn:-10} )); do
      local -a these_ids=()
      local +x reply
      eval getlist.${(q)1} '$pn' | readeof reply
      if [[ -e $1.sfeed ]]; then
        printj $reply | cut -f6 | grep -ve '^[ ]*$' \
        | anewer <(zstdcat -- $1.sfeed | cut -f6) | readarray these_ids
      else
        printj $reply | cut -f6 | readarray these_ids
      fi || if [[ $?==5 ]]; then
          break
        else
          return 1
        fi
      these_ids=(${(@)these_ids})
      local +x sfeed_tbw=
      printj $reply | expand.list $these_ids | readeof sfeed_tbw
      printj $sfeed_tbw | zstd | rw -a -- $1.sfeed
      if (( actpn > pn )); then
        pn=$((actpn+1))
      else
        pn+=1
      fi
      sleep $(( 1+RANDOM%2 ))
    done
    shift
  done
}

expand.list() {
  local +x readline=; while IFS= read -r readline; do
    if [[ ${#readline} -eq 0 ]]; then break; fi
    local -a columns=(${readline})
    columns=("${(@ps:\t:)columns}")
    if [[ ${#columns[6]#kkmh:} -gt 0 ]] && [[ ${(@)argv[(Ie)${columns[6]}]} -gt 0 ]]; then
      local +x desc=
      fie "${columns[3]}" | pup '.detailsBox' 'text{}' | readeof desc
      columns[4]="<div>${${${${${${desc//</&lt;}//>/&gt;}//&/&amp;}//
/<br>}//	/ }//\\}</div>${columns[4]}"
      say "${(@pj:\t:)columns}"
    else
      continue
    fi
  done
}

getlist.kk-pchtml-series-cn() {
  local +x -i argpn=${1:-1} ps=48
  local +x jsonreply=
  local -a ids=()
  frest \
    -H 'accept: application/json, text/plain, */*' \
    -H 'accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7' \
    -H 'referer: https://www.kuaikanmanhua.com/tag/0?region=2&pays=0&state=1&sort=3&page=1' \
    -H 'user-agent-pc: PCKuaikan/1.0.0/100000(unknown;unknown;Chrome;pckuaikan;1920*1080;0)' \
    --url 'https://www.kuaikanmanhua.com/search/mini/topic/multi_filter?page='$argpn'&size='$ps'&tag_id=0&update_status=1&pay_status=0&label_dimension_origin=2&sort=3' | readeof jsonreply
  printj $jsonreply | gojq -j '
    if (.code==200) then
      if ((.hits.topicMessageList|length)>0) then
        halt
      else
        ""|halt_error(90)
      end
    else
      "exception: non-zero REST API status.\n" | halt_error(1)
    end
' || case ${pipestatus[2]} in
       (90)
         return 0;;
       (*)
         false;;
     esac
  printj $jsonreply | gojq -j .hits.topicMessageList | readeof jsonreply
  printj $jsonreply | ponsucc gojq -r '.[]|[
  (.first_comic_publish_time|sub("\\.(?<a>[1-9])$"; ".0"+(.a))|sub("^(?<y>[0-9]{4})\\.(?<m1>[1-9])\\."; (.y)+".0"+(.m1)+".")|strptime("%Y.%m.%d")|mktime),
  (.title|gsub("[\t\n]"; "")|gsub("\\\\"; "")),
  ("https://www.kuaikanmanhua.com/web/topic/"+(.id|tostring)+"/"),
  ([
    ("<div>"+(.category|join("、"))+"</div>"),
    ("<div><img src=\""+(.vertical_image_url|sub("\\.webp-.+$"; ".webp"))+"\"></div>"),
    ("<div><img src=\""+(.cover_image_url|sub("\\.webp-.+$"; ".webp"))+"\"></div>")
   ]|join("")),
  "html",
  ("kkmh:"+(.id|tostring)),
  (.author_name|gsub("\\\\"; "")|gsub("[ \t\n]"; " ")|gsub("\\+"; "、")),
  "",
  ""
]|join("\t")'
}
eval "$(typeset -pf getlist.kk-pchtml-series-cn | perl -0777pe 's%getlist.kk-pchtml-series-cn%getlist.kk-pchtml-series-kr%;
s.region=2.region=3.;
s.label_dimension_origin=2.label_dimension_origin=3.')"
eval "$(typeset -pf getlist.kk-pchtml-series-cn | perl -0777pe 's%getlist.kk-pchtml-series-cn%getlist.kk-pchtml-posts%;
s.region=2.region=1.;
s.state=1.state=0.;
s.update_status=1.update_status=0.;
s.label_dimension_origin=2.label_dimension_origin=1.;
s.tag_id=0.tag_id=76.')"

if [[ $# -ne 0 ]]; then
  main "${(@)argv}"
else
  main us kk-pchtml-{series-{cn,kr},posts}
fi
