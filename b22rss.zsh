#!/usr/bin/env shorthandzsh
alias furl='command curl -qgsf --compressed'
alias fie='ponsucc -n 3 -w 40 -m 22,56 furl -A "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv 11.0) like Gecko"'
alias frest='ponsucc -n 3 -w 25 -m 22,56 furl'
builtin zmodload -Fa zsh/datetime p:EPOCHSECONDS b:strftime
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
    (getlist*|expand*)
      "${(@)argv}";;
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
        zstdcat "$1.sfeed" | grep -ve '^#' | sed -Ee 's%\v[^\t]*\t%\t%' | sfeed_atom | dasel put -r xml -t string -s '.feed.author.name' -v "$1" | dasel put -r xml -t string -s '.feed.title.#text' -v "$1" | rw "$1.atom.xml"
      fi
    else
      return $?
    fi
    shift
  done
}

update() {
  while (( $# != 0 )); do
    local +x -i pn=${pn:-1}
    while (( pn <= ${maxpn:-50} )); do
      local -a these_ids=()
      local +x reply=  psstat=
      getlist.ids.${1} $pn | readeof reply
      printj $reply | anewer <(zstdcat -- $1.sfeed | grep -vEe '^#(~|\.)@' | cut -f6) | readarray these_ids || psstat=${pipestatus[3]}
      if [[ "$psstat" == 5 ]]; then
          break
      elif [[ "$psstat" == "" || "$psstat" == 0 ]]; then :
      else
        return 1
      fi
      these_ids=(${(@)these_ids})
      local +x sfeed_tbw=
      expand.ids ${1} ${these_ids} | readeof sfeed_tbw
      printj $sfeed_tbw | tac | anewer <(zstdcat -- $1.sfeed) | zstd | rw -a -- $1.sfeed
      pn+=1
      say $1:page$pn>&2
      if (( pn <= ${maxpn:-50} )); then
        if (( pn%8 == 0 )); then
          sleep $(( 5+RANDOM%15 ))
        else
          sleep $(( 2+RANDOM%2 ))
        fi
      fi
    done
    shift
  done
}

expand.ids() {
  if (( $# >= 2 )); then
    local sch=
    case "$1" in
      (b22-h5-*)
        sch=b22-h5
        ;;
      (*)
        sch=$1
        ;;
    esac
    shift

    while :; do
      ## filter out vcomic
      if [[ "$1" != \#* ]]; then
        expand.id.${sch} ${1}
        say $sch:$1>&2
      fi
      shift
      if (( $# == 0 )); then
        break
      fi
    done
  fi
}

source "${ZSH_ARGZERO%/*}/mangarss.zsh.inc"
expand.id.b22-h5() {
  local +x -i argid=$1
  if (( argid <= 0 )); then false; fi
  local +x jsonreply=
  frest \
    -H 'accept: application/json, text/plain, */*' \
    -H 'content-type: application/json;charset=UTF-8' \
    -H 'referer: https://manga.bilibili.com/m/detail/mc'$argid \
    --data-raw '{"comic_id":'$argid'}' \
    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ComicDetail?device=h5&platform=web' | readeof jsonreply
  local +x -i ts=$EPOCHSECONDS
  printj $jsonreply | gojq -r 'if (.code==0) and (.data|length>0) then halt else halt_error end' || return 1
  printj $jsonreply | gojq -r '.data' | readeof jsonreply
  # 标题 运营一句话简介 横幅图 封面 文案 条漫/页漫
  local +x {tit,intro,hc,vc,sc,text,layout}=
  # 分类 标签
  local +x {cats,tags}=
  printj $jsonreply|gojq -r .title|read -r tit

  # 作者
  local +x -a auts=()
  printj $jsonreply | gojq -r '.author_name[]' | readarray auts
  local +x this_serial_is_excluded=
  if printf %s\\n "${(@)auts}" | grep -Eqe "^(${(j.|.)excluded_auts})$" >/dev/null; then
    this_serial_is_excluded='#### '
  fi

  printj $jsonreply|gojq -j 'if (.introduction|length>0) then .introduction else halt end'|readeof intro
  printj $jsonreply|gojq -r 'if (.horizontal_cover|length>0) then .horizontal_cover else halt end'|read -r hc||:
  printj $jsonreply|gojq -r 'if (.vertical_cover|length>0) then .vertical_cover else halt end'|read -r vc||:
  printj $jsonreply|gojq -r 'if (.square_cover|length>0) then .square_cover else halt end'|read -r sc||:
  printj $jsonreply|gojq -j 'if (.evaluate|length>0) then .evaluate else halt end'|readeof text
  printj $jsonreply|gojq -r '.comic_type'|read -r layout
  printj $jsonreply|gojq -r 'if (.styles|length>0) then .styles|join("、") else "" end'|read -r cats
  printj $jsonreply|gojq -r 'if (.tags|length>0) then [.tags[]|.name]|join("、") else halt end'|read -r tags||:
  local +x -a covers=($vc $hc $sc)

  local +x -i exact_pubdate=
  printj $jsonreply | gojq -r 'if (.ep_list|length>0) and (
[.ep_list[] | select(
    (.ord>=1) and (
      (.title | test("'${(j:|:)excluded_chapti_regex}'"; "")) or (.short_title | test("'${(j:|:)excluded_chapti_regex}'"; "")) | not
    )
  )
] | length>0
) then [.ep_list[] | select(
    (.ord>=1) and (
      (.title | test("'${(j:|:)excluded_chapti_regex}'"; "")) or (.short_title | test("'${(j:|:)excluded_chapti_regex}'"; "")) | not
    )
  )
] | sort_by(.ord) | .[:100] | sort_by(.pub_time) | .[0].pub_time+" +0800" | strptime("%F %T %z") | mktime else -1 end' | read -r exact_pubdate||:
  if (( exact_pubdate>0 )); then
    ts=$exact_pubdate
  else
    local +x -i literal_release_time_epoch=
    printj $jsonreply | gojq -r 'if (.release_time|length>=8) then .release_time+" +0800"|strptime("%Y.%m.%d %z")|mktime else halt
 end'|read -r literal_release_time_epoch||:
    if (( literal_release_time_epoch>0 )); then
      ts=$literal_release_time_epoch
      this_serial_is_excluded='#~@'
    else
      this_serial_is_excluded='#.@'
    fi
  fi

  local -a content=(${intro:+——}$intro $text)
  local -a tagline=(${cats:+BL/GL/其他})
  if [[ ${#tags} -ne 0 && ${#tagline} -ne 0 ]]; then
    tagline+=(：)
  fi
  tagline+=($tags)
  content+=(${(j::)tagline})
  ## 给页漫在body末尾加一个emoji icon
  if [[ "$layout" == 1 ]]; then
    content[-1]+="📖"
  fi
  content=(${${${${${(@)content//\\/\\\\}//\t/\\t}//&/&amp;}//</&lt;}//>/&gt;})
  ## 先双掉text block,然后扫清原文本中的newline
  content=(${(@j:<br>:)${(@ps:\n:)${(@j:<br><br>:)content}}})
  local +x -a imguris=($hc $vc)
  content+=( "<p><img src=\""${(@)^imguris}"\"></p>" )
  content=(${(j::)content})

  local +x -a sfeed_cat_column=($cats)
  if [[ "$layout" == 1 ]]; then
    sfeed_cat_column+=('页漫')
  else
    sfeed_cat_column+=('条漫')
  fi
  sfeed_cat_column+=($tags)
  ## man 5 sfeed
  local -a printline=($ts "$tit" "https://manga.bilibili.com/detail/mc$argid" "$content" html $argid "$auts" "${(pj:\v:)covers}" "${(j:|:)sfeed_cat_column//、/|}")
  printj $this_serial_is_excluded"${(@pj:\t:)printline}" $'\n'
}

local +x listfin=$listfin
getlist.ids.b22-h5-cn() {
  local +x -i argpn=${1:-1} ps=${2:-15}
  local +x jsonreply=
  frest \
    -H 'accept: application/json, text/plain, */*' \
    -H 'content-type: application/json;charset=UTF-8' \
    -H 'referer: https://manga.bilibili.com/m/classify?status=0&areas=1&styles=-1&orders=3&prices=-1' \
    --data-raw '{"style_id":-1,"area_id":1,"is_finish":'${${listfin:+1}:-0}',"order":3,"is_free":-1,"page_num":'$argpn',"page_size":'$ps'}' \
    --url 'https://manga.bilibili.com/twirp/comic.v1.Comic/ClassPage?device=h5&platform=web' | readeof jsonreply
  local +x -i totals=
  printj $jsonreply | gojq -r '
    if (.code==0) and has("data") then
      [.data[].season_id]|length|tostring
    else
      "exception: non-zero REST API status.\n" | halt_error(1)
    end
' | read -r totals
  if (( totals == 0 )); then
    break
  elif (( totals>0 )); then
    :
  else
    return 1
  fi
  if (( ${#jsonreply}>0 )); then
    ## mark vcomic
    printj ${jsonreply} | gojq -cr '[(.data[]|select(.type==1).season_id|tostring|sub("^"; "#")),(.data[]|select(.type==0).season_id)]|.[]'
  fi
}
eval "$(typeset -pf getlist.ids.b22-h5-cn | sed -e '1s%b22-h5-cn%b22-h5-kr%' | sed -ze 's%"area_id":1,%"area_id":6,%')"
eval "$(typeset -pf getlist.ids.b22-h5-cn | sed -e '1s%b22-h5-cn%b22-h5-jp%' | sed -ze 's%"area_id":1,%"area_id":2,%')"

#functions -T expand.id.b22-h5
if [[ $# -ne 0 ]]; then
  main "${(@)argv}"
else
  main us b22-h5-cn b22-h5-kr b22-h5-jp
fi
