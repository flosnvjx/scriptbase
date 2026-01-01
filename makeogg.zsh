#!/usr/bin/env shorthandzsh

## split cuesheets in cwd.
## $0 [mmode] [output_codec [output_codec_args]]

setopt extendedglob pipefail errreturn xtrace
function .main {
  local ofmt= mmode= fifo=
  local match=()
  if [[ "$1" = ((#b)(cue|tidy|lrc|fifo[.:=](/?*))(#B)) ]]; then
    mmode=${match[1]}
    case "$mmode" in; (fifo*) mmode=fifo; fifo=${match[2]} ;; esac
    shift
  fi
  if (( $#1 )) && [[ ${(@)${(@k)ostr}[(I)(#i)${(q)1}]} -gt 0 || "$1" == (none|null) ]]; then
    ofmt=$1
    shift
  elif (( !$#1 )); then
    if [[ "$mmode" == cue ]]; then
      ofmt=none
    elif [[ "$mmode" == lrc ]]; then
      ofmt=null
    else
      function {
        while ((#)); do if [[ -v ostr[$1] ]]; then
          ofmt=$1
          break
          fi
          shift
        done
      } aotuv fdkaac flac
    fi
  else
    .fatal "unsupported output fmt: $1"
  fi

  local ofmtargs=("${(@)argv}")

  local -a acuefiles=(**/?*.(#i)cue(.N)) cuefiles=()
  if [[ "$mmode" = fifo ]]; then
    case $#acuefiles in
      0) return 44 ;;
      1) cuefiles=($acuefiles) ;;
      *) cuefiles=("${(@f)$(printf %s\\n $acuefiles | fzf --layout=reverse-list --prompt="Select a cuesheet for later operations> ")}") ;;
    esac
  else
    case $#acuefiles in
      0) return 44 ;;
      1) cuefiles=($acuefiles) ;;
      *) cuefiles=("${(@f)$(printf %s\\n $acuefiles | fzf -m --layout=reverse-list --prompt="Select cuesheets for later operations> ")}") || cuefiles=($acuefiles)
         ;;
    esac
  fi
  local -a cuefilecodepages cuebuffers cue{file,discnumber,totaldiscs,filetitle,catno}directives
  local -a albumtitles albumfiles discnumbers totaldiscs catnos
  if [[ "$mmode" = tidy ]]; then
    local -a albumtidy{file,dir}s suris vgmdbids cue{performer,label,date}directives dates labels aarts ssdlwids
  fi
  function {
    local walkcuefiles REPLY
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      cuefilecodepages+=('')
      local buf=
      if ! aconv < ${cuefiles[$walkcuefiles]} | cmp -s -- ${cuefiles[$walkcuefiles]} -; then
        aconv < ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
        while :; do
          read -k1 "REPLY?${cuefiles[$walkcuefiles]} -- Is that okay? ${cuefilecodepages[-1]:+${cuefilecodepages[-1]} }(y/N)" < ${TTY:-/dev/tty}
          case "$REPLY" in
            ([^$'\n']) echo ;|
            ([yY]) break ;;
          esac
          cuefilecodepages[-1]="${$(iconv -l | fzf --layout=reverse-list --prompt="Select a codepage> ")// *}"
          iconv -f ${cuefilecodepages[-1]} -t UTF-8 -- ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
        done
        if (( ${#cuefilecodepages[-1]} )); then
          ## perform unicode sanitize
          uconv -i -f ${cuefilecodepages[-1]} -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' --remove-signature < ${cuefiles[$walkcuefiles]} | readeof buf
        else
          aconv < ${cuefiles[$walkcuefiles]} | .uninorm | readeof buf
        fi
      else
        .uninorm < ${cuefiles[$walkcuefiles]} | readeof buf
        .msg 'open '${cuefiles[$walkcuefiles]}
      fi
      cuebuffers[$walkcuefiles]=$buf
      unset buf
      cuefiledirectives+=( "${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#FILE "*" (WAVE|FLAC) #]#*\"}%\"*}" )
      cuefiletitledirectives+=( "${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#TITLE "*" #]#*\"}%\" #}" )
      cuediscnumberdirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM DISCNUMBER [1-9][0-9]# #]#[ 	 ]#REM DISCNUMBER }% #}")
      cuetotaldiscsdirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM TOTALDISCS [1-9][0-9]# #]#[ 	 ]#REM TOTALDISCS }% #}")
      cuecatnodirectives+=("${${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM CATALOGNUMBER ("[A-Z][-_0-9A-Z]##"|[A-Z][-_0-9A-Z]##) #]#[ 	 ]#REM CATALOGNUMBER }%\" #}#\"}")
    if [[ "$mmode" = tidy ]]; then
      cuelabeldirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM LABEL "*" #]#*\"}%\" #}")
      cueperformerdirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#PERFORMER "*" #]#*\"}%\" #}")
      cuedatedirectives+=("${${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM DATE ("[0-9](#c4)(|/<1-12>(|/<1-31>))"|[0-9](#c4)(|/<1-12>(|/<1-31>))) #]#[ 	 ]#REM DATE }%\" #}#\"}")
    fi
    done
    (( $#cuefiledirectives == $#cuefiles )) || .fatal "specified $#cuefiles cue sheet(s), but found $#cuefiledirectives FILE directive(s)"
    (( $#cuefiledirectives == ${(@)#${(@u)cuefiledirectives}} )) || .fatal "multiple cue sheets referenced same FILE"
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
      local -a match=()
      case ${(@)#${(@u)cuefiletitledirectives}} in
        (0)
          albumtitles+=("${${${cuefiles[$walkcuefiles]:r}%/[0-9A-Z]##[-0-9A-Z]##}:t}")
            eval 'albumtitles[$walkcuefiles]=${albumtitles[$walkcuefiles]:#(CDImage|(|((Various|Unknown) Artist(s|)|(不明[なの]|複数の異なる)アーティスト) - )(Unknown[ _](Album|Title)|不明な(アルバム|タイトル)))}'
            until (( ${#albumtitles[$walkcuefiles]} )); do timeout 0.01 cat >/dev/null || :; vared -ehp 'album> ' "albumtitles[$walkcuefiles]"; done
          ;|
        (<1->)
          albumtitles[$walkcuefiles]=${cuefiletitledirectives[$walkcuefiles]%[ 　]#([\[\(（<]|)(#i)Disc([＊*#＃. ]|)(#b)(<1->)(#B)(#I)([\]\)）>]|)}
          if (( ${#albumtitles[$walkcuefiles]} && ${(@)#${(@M)albumtitles:#${albumtitles[$walkcuefiles]}}} > 1 )); then
            :
          else
            if (( ! ${#albumtitles[$walkcuefiles]} )) || [[ "${albumtitles[$walkcuefiles]}" = (Unknown (Album|Title)|不明な(アルバム|タイトル)) ]]; then
              albumtitles[$walkcuefiles]=${${${cuefiles[$walkcuefiles]:r}%/[0-9A-Z]##[-0-9A-Z]##}:t}
              eval 'albumtitles[$walkcuefiles]=${albumtitles[$walkcuefiles]:#(CDImage|(|((Various|Unknown) Artist(s|)|(不明[なの]|複数の異なる)アーティスト) - )(Unknown[ _](Album|Title)|不明な(アルバム|タイトル)))}'
            fi
            while timeout 0.01 cat >/dev/null || :; do vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
              if (( ${#albumtitles[$walkcuefiles]} )); then break; fi
            done
          fi
          ;|
        (<0->)
          totaldiscs[$walkcuefiles]=${cuetotaldiscsdirectives[$walkcuefiles]}
          if (( ${(@)#${(@M)albumtitles:#${albumtitles[$walkcuefiles]}}} > 1)); then
            totaldiscs[$walkcuefiles]=${totaldiscs[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
          elif (( ! totaldiscs[walkcuefiles] )); then
            totaldiscs[$walkcuefiles]=$(( ${(@)#${(@M)cuefiletitledirectives:#${albumtitles[$walkcuefiles]}*}} ? ${(@)#${(@M)cuefiletitledirectives:#${albumtitles[$walkcuefiles]}*}} : $#cuefiles ))
            until vared -ep 'dc> ' "totaldiscs[$walkcuefiles]" && [[ "${totaldiscs[walkcuefiles]}" == [1-9][0-9]# ]] && (( totaldiscs[walkcuefiles] > 0 )); do timeout 0.01 cat >/dev/null || :; done
          fi

          discnumbers[$walkcuefiles]=${cuediscnumberdirectives[$walkcuefiles]:-$(( match[1] ))}
          match=()
          if (( !${discnumbers[$walkcuefiles]} )); then
            if [[ "${cuefiles[$walkcuefiles]:t:r}" = (*[^a-zA-Z]##|)(#i)disc([＊*#＃. ]|)(#b)([1-9][1-90]#) ]] || [[ "${cuefiles[$walkcuefiles]:r}" != (#i)Disc(#b)([1-9][1-90]#)/[^/]## ]]; then
              discnumbers[$walkcuefiles]=$(( match[1] ))
            fi
            if (( discnumbers[walkcuefiles] > totaldiscs[walkcuefiles] )); then
              .warn "totaldiscs < discnumbers"
            fi
          fi
          if (( !${discnumbers[$walkcuefiles]} )); then
            if (( totaldiscs[walkcuefiles] > 1 )); then
              discnumbers[$walkcuefiles]=${(@)#${(@M)albumtitles:#${albumtitles[$walkcuefiles]}}}
              until vared -ep 'dn> ' "discnumbers[$walkcuefiles]" && (( discnumbers[walkcuefiles] > 0 && discnumbers[walkcuefiles] <= totaldiscs[walkcuefiles] )); do timeout 0.01 cat >/dev/null || :; done
            else
              discnumbers[$walkcuefiles]=1
            fi
          fi

          catnos[$walkcuefiles]=${cuecatnodirectives[$walkcuefiles]}
          if (( !${#catnos[$walkcuefiles]} )); then
            match=()
            : ${(M)${cuefiledirectives[$walkcuefiles]:t:r}:#(#b)([A-Z][A-Z0-9](#c1,4)(-[A-Z](#c0,3)[0-9](#c1,5)[A-Z](#c0,3))(#c1,2))}
            if (( totaldiscs[walkcuefiles] > 1 )); then
              catnos[$walkcuefiles]=${${catnos[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}:-${match[1]}}
            fi
            if (( !${#catnos[$walkcuefiles]} )) && (( $#acuefiles == totaldiscs[walkcuefiles] )) && (( 1 == ${(@)#${(@u)albumtitles}} )); then
              if [[ ${cuefiles[$walkcuefiles]} == ?*/?* && ${cuefiles[$walkcuefiles]:r} != (#i)Disc[0-9]##/[^/]## ]]; then
                : ${(M)${cuefiles[$walkcuefiles]:h:t}:#*\[(#b)([A-Z][A-Z0-9](#c1,4)(-[A-Z](#c0,3)[0-9](#c1,5)[A-Z](#c0,3))(#c1,2))\]*}
              else
                : ${(M)${PWD:t}:#*\[(#b)([A-Z][A-Z0-9](#c1,4)(-[A-Z](#c0,3)[0-9](#c1,5)[A-Z](#c0,3))(#c1,2))\]*}
              fi
              catnos[$walkcuefiles]=${match[1]}
            fi
            while :;do
              timeout 0.01 cat > /dev/null||:
              vared -ehp 'pn> ' "catnos[$walkcuefiles]"
              if [[ "${catnos[$walkcuefiles]}" = ([A-Z][A-Z0-9]##([-_][A-Z0-9]##)#|) ]]; then
                break
              fi
            done
          fi

          if [[ "$mmode" = tidy ]]; then
            match=()
            dates[$walkcuefiles]=${cuedatedirectives[$walkcuefiles]}
            if [[ "${dates[$walkcuefiles]}" != (#b)(<1980-2099>)([/-](<1-12>)([/-](<1-31>)|)|) ]] || (( !${#match[5]} )); then
              if (( totaldiscs[walkcuefiles] > 1 )); then
                dates[$walkcuefiles]=${dates[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
              fi
              match=()
              if (( !${#dates[$walkcuefiles]} || !${#match[5]} )) && (( $#acuefiles == totaldiscs[walkcuefiles] )) && (( 1 == ${(@)#${(@u)albumtitles}} )); then
                if [[ ${cuefiles[$walkcuefiles]} == ?*/?* && ${cuefiles[$walkcuefiles]:r} != (#i)Disc[0-9]##/[^/]## ]]; then
                  : ${(M)${cuefiles[$walkcuefiles]:h:t}:#*\[(#b)([0-9](#c2))([0-9x](#c2))([0-9x](#c2))\]*}
                else
                  : ${(M)${PWD:t}:#*\[(#b)([0-9](#c2))([0-9x](#c2))([0-9x](#c2))\]*}
                fi
                if (( ${#match[3]} )); then
                  dates[$walkcuefiles]=${match[3]:+$(( match[1]>=80 ? 1900+match[1] : 2000+match[1] ))${${(M)match[2]:#*x*|00|<13->}:-/$(( match[2] ))${${(M)match[3]:#*x*|00|<32->}:-/$(( match[3] ))}}}
                fi
              fi
              while :;do
                timeout 0.01 cat > /dev/null||:
                vared -ehp 'date> ' "dates[$walkcuefiles]"
                if [[ "${dates[$walkcuefiles]}" = (#b)(<1980-2099>)([ /-](<1-12>)([ /-](<1-31>)|)|) ]]; then
                  dates[$walkcuefiles]=$(( match[1] ))${match[3]:+/$(( match[3] ))${match[5]:+/$(( match[5] ))}}
                  break
                fi
              done
            else
              dates[$walkcuefiles]=${match[1]}${match[2]:+/$(( match[3] ))${match[4]:+/$(( match[5] ))}}
            fi

            labels[$walkcuefiles]=${cuelabeldirectives[$walkcuefiles]}
            if (( !${#labels[$walkcuefiles]} )); then
              if (( totaldiscs[walkcuefiles] > 1 )); then
                labels[$walkcuefiles]=${labels[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
              fi
              timeout 0.01 cat > /dev/null||:
              vared -ehp 'la> ' "labels[$walkcuefiles]"
            fi

            if [[ -n "${cueperformerdirectives[$walkcuefiles]}" && "${cueperformerdirectives[$walkcuefiles]}" != "${labels[$walkcuefiles]}" && "${cueperformerdirectives[$walkcuefiles]}" != ((Various|Unknown) Artist(s|)|(不明[なの]|複数の異なる)アーティスト) ]]; then
              aarts[$walkcuefiles]=${cueperformerdirectives[$walkcuefiles]}
            fi
            if (( !${#aarts[$walkcuefiles]} )) || [[ "${aarts[$walkcuefiles]}" = "${labels[$walkcuefiles]}" ]]; then
              if (( totaldiscs[walkcuefiles] > 1 )); then
                aarts[$walkcuefiles]=${aarts[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
              fi
              timeout 0.01 cat > /dev/null||:
              vared -ehp 'aart> ' "aarts[$walkcuefiles]"
            fi

            if (( totaldiscs[walkcuefiles] > 1 )); then
              ssdlwids[$walkcuefiles]=${ssdlwids[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
            fi
            if (( !${#ssdlwids[$walkcuefiles]} )) && (( $#acuefiles == totaldiscs[walkcuefiles] )) && (( 1 == ${(@)#${(@u)albumtitles}} )); then
              match=()
              : ${(M)${PWD:t}:#*{(#b)(M[-.][0-9](#c7))}*}
              ssdlwids[$walkcuefiles]=${match[1]}
            fi
            if (( !${#ssdlwids[$walkcuefiles]} )) && (( $#ssdlwtxt )); then
              ssdlwids[$walkcuefiles]="$(fzf --wrap < $ssdlwtxt | sed -Ee 's%^\{M-([0-9]{7})}.*%M.\1%')" || :
            fi

            if (( totaldiscs[walkcuefiles] > 1 )) && (( ${(@)#${(M@)albumtitles:#${albumtitles[$walkcuefiles]}}} > 1 )); then
              suris[$walkcuefiles]=${suris[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
              vgmdbids[$walkcuefiles]=${vgmdbids[${(@)albumtitles[(ie)${albumtitles[$walkcuefiles]}]}]}
            else
              if (( !${#suris[$walkcuefiles]} )) && (( $#acuefiles == totaldiscs[walkcuefiles] )) && (( 1 == ${(@)#${(@u)albumtitles}} )); then
                match=()
                if [[ ${cuefiles[$walkcuefiles]} == ?*/?* && ${cuefiles[$walkcuefiles]:r} != (#i)Disc[0-9]##/[^/]## ]]; then
                  eval : '${(M)${cuefiles[$walkcuefiles]:h:t}:#*\[(#b)((@('${(@j.|.)suriscms}'))##)\]*}'
                else
                  eval : '${(M)${PWD:t}:#*\[(#b)((@('${(@j.|.)suriscms}'))##)\]*}'
                fi
                suris[$walkcuefiles]=${match[1]}
              fi
              if (( !${#suris[$walkcuefiles]} )) && (( !${#ssdlwids[$walkcuefiles]} )); then
                while :; do
                  local suri=
                  vared -ehp 'suri+> ' suri
                  if [[ "$suri" = https://m[.]miaola[.]work/read/(#b)([1-9][0-9]#)/sf/([0-9a-f](#c3))(#B)(|/keyword*) ]]; then
                      suris[$walkcuefiles]+="@kf.${match[1]}.sf${match[2]}"
                  elif [[ "$suri" = http(s|)://(bgm|bangumi).tv/subject/topic/(#b)([1-9][0-9]#)(#B)(|\#*) ]]; then
                      suris[$walkcuefiles]+="@bgm.subj.t${match[1]}"
                  elif [[ "$suri" = http(s|)://tieba[.]baidu[.]com/p/(#b)([1-9][0-9]#)(#B)(|\?*)(|\#*) ]]; then
                      suris[$walkcuefiles]+="@tb.p${match[1]}"
                  fi
                  if (( ${#suris[$walkcuefiles]} )); then
                    suris[$walkcuefiles]="@"${(j.@.)${(s.@.u)suris[$walkcuefiles]}}
                  fi
                  if (( !$#suri )); then break; fi
                done
              fi
              if (( !${#vgmdbids[$walkcuefiles]} )) && (( $#acuefiles == totaldiscs[walkcuefiles] )) && (( 1 == ${(@)#${(@u)albumtitles}} )); then
                match=()
                if [[ ${cuefiles[$walkcuefiles]} == ?*/?* && ${cuefiles[$walkcuefiles]:r} != (#i)Disc[0-9]##/[^/]## ]]; then
                  : ${(M)${cuefiles[$walkcuefiles]:h:t}:#*\[VGMdb(#b)(<1->)\]*}
                else
                  : ${(M)${PWD:t}:#*\[VGMdb(#b)(<1->)\]*}
                fi
                vgmdbids[$walkcuefiles]=${match[1]}
              fi
              if (( !${#vgmdbids[$walkcuefiles]} )); then
                while :; do
                  vared -ep 'vgmdburi> ' "vgmdbids[$walkcuefiles]"
                  match=()
                  case "${vgmdbids[$walkcuefiles]}" in
                    (https://vgmdb.net/album/<1->|<1->)
                      vgmdbids[$walkcuefiles]=${vgmdbids[$walkcuefiles]##*/}
                      break
                    ;;
                  esac
                done
              fi
            fi

          fi
          ;|
      esac
    done
    if [[ "$mmode" = tidy ]] && (( 1 == ${(@)#${(@u)albumtitles}} )); then
      for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
        match=()
        : ${dates[$walkcuefiles]:#(#b)(<1980-2099>)(#B)(|/(#b)(<1-12>)(#B)(|/(#b)(<1-31>)))}
        albumtidydirs[$walkcuefiles]="[${match[1]:2:2}${${match[2]:+${${(M)match[2]:#?}:+0}${match[2]}}:-xx}${${match[3]:+${${(M)match[3]:#?}:+0}${match[3]}}:-xx}][${${labels[$walkcuefiles]:+${labels[$walkcuefiles]}${aarts[$walkcuefiles]:+ (${aarts[$walkcuefiles]})}}:-${aarts[${walkcuefiles}]}}] ${albumtitles[$walkcuefiles]} ${${(@j..)catnos}:+[${(@j.,.)${(@nu)catnos}}]}${suris[$walkcuefiles]:+[${suris[$walkcuefiles]}]}[VGMdb${vgmdbids[$walkcuefiles]}]${ssdlwids[$walkcuefiles]:+{${ssdlwids[${walkcuefiles}]}\}}"
        albumtidyfiles[$walkcuefiles]=${${catnos[$walkcuefiles]:+${catnos[$walkcuefiles]}${${totaldiscs[$walkcuefiles]:#${(@)#${(@u)catnos}}}:+.disc${discnumbers[$walkcuefiles]}}}:-VGMdb.album${vgmdbids[$walkcuefiles]}${${(M)totaldiscs[$walkcuefiles]:#<2->}:+.disc${discnumbers[$walkcuefiles]}}}${suris[$walkcuefiles]}
      done
      for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
        if (( ${(@)#${(@u)albumtidydirs}} == 1 )); then
          if [[ ${cuefiles[$walkcuefiles]} == ?*/?* && ${cuefiles[$walkcuefiles]:r} != (#i)Disc[0-9]##/[^/]## && \
            "${cuefiles[$walkcuefiles]:h}" != "${albumtidydirs[$walkcuefiles]}"(|*/) && "${PWD:t}" != "${albumtidydirs[$walkcuefiles]}" ]] || \
            [[ "${PWD:t}" != "${albumtidydirs[$walkcuefiles]}" ]]; then
            if (( walkcuefiles==1 )); then
              mkdir -vp -- "${albumtidydirs[$walkcuefiles]}"
            fi
            if function { return $(( $#==0 )); } {${cuefiles[$walkcuefiles]:r},${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}}.*(.N); then rename -vo -- ${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)} ${albumtidydirs[$walkcuefiles]}/${albumtidyfiles[$walkcuefiles]} {${cuefiles[$walkcuefiles]:r},${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}}.*(.N); fi
            cuefiles[$walkcuefiles]=${cuefiles[$walkcuefiles]/${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}/${albumtidydirs[$walkcuefiles]}\/${albumtidyfiles[$walkcuefiles]}}
          elif [[ "${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}" != "${albumtidyfiles[$walkcuefiles]}" ]]; then
            if function { return $(( $#==0 )); } {${cuefiles[$walkcuefiles]:r},${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}}.*(.N); then rename -vo -- ${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)} ${albumtidyfiles[$walkcuefiles]} {${cuefiles[$walkcuefiles]:r},${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}}.*(.N); fi
            cuefiles[$walkcuefiles]=${cuefiles[$walkcuefiles]/${${cuefiles[$walkcuefiles]:r}%%\#soxStatExclNull.Samples[0-9]##(|.XXH3_[0-9a-f](#c16))(|\#*)}/${albumtidyfiles[$walkcuefiles]}}
          fi
        fi
      done
    fi
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      local -a match=() mbegin=() mend=()
      .msg "${cuefiles[$walkcuefiles]} (\"${cuefiledirectives[$walkcuefiles]}\")"
      : ${cuefiledirectives[$walkcuefiles]/%.(#b)([0-9a-zA-Z]##)}
      local ifmtstr= ifile=
      if [[ "$mmode" != fifo ]]; then
      case "${match[1]}" in
        ((#i)(flac|wav|tak|tta|ape))
          ifile=${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${cuefiledirectives[$walkcuefiles]}
          .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
          if ! [[ -f "$ifile" ]]; then
            function {
              argv=({${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${cuefiledirectives[$walkcuefiles]:r},${cuefiles[$walkcuefiles]:r}}.(#i)(flac|wav|tak|tta|ape)(.N))
              if ((#)); then
                ifile=$1
                albumfiles[$walkcuefiles]=${${${(M)cuefiles[$walkcuefiles]:#*/*}:+${ifile#"${cuefiles[$walkcuefiles]%/*}"/}}:-$ifile}
                .msg "${cuefiles[$walkcuefiles]} (\"${cuefiledirectives[$walkcuefiles]}\" -> \"${albumfiles[$walkcuefiles]}\" [NOTE: fallback])"
                return
              fi
            }
          else
            albumfiles[$walkcuefiles]=${${${(M)cuefiles[$walkcuefiles]:#*/*}:+${ifile#"${cuefiles[$walkcuefiles]%/*}"/}}:-$ifile}
          fi
          local ifmt=${${ifile:l}##*.}
        ;;
        (*)
          .fatal "unsupported extension specified in FILE directive: ${cuefiles[$walkcuefiles]} (\"${cuefiledirectives[$walkcuefiles]}\")"
        ;;
      esac
      case "${ifmt}" in
        ((#i)(tta|ape|tak))
          ifmtstr=${fmtstr[$ifmt]}
          ;;
      esac
      fi ## if [[ "$mmode" != fifo ]]; then
      local mbufs=()
      local mbuf=
      gawk -E <(print -r -- ${${(M)mmode:#fifo}:-'
        BEGIN {
          d["d"]["FILE"]="'"${${albumfiles[$walkcuefiles]//\\/\\\\}//\"/\\\"}"'";
        }'}'
        BEGIN {
          d["d"]["TITLE"]="'"${${albumtitles[$walkcuefiles]//\"/＂}//\\/\\\\}"'";
          d["d"]["REM DISCNUMBER"]="'${${totaldiscs[$walkcuefiles]:#1}:+$(( discnumbers[$walkcuefiles] ))}'";
          d["d"]["REM TOTALDISCS"]="'$(( totaldiscs[$walkcuefiles] ))'";
          d["d"]["REM CATALOGNUMBER"]="'${catnos[$walkcuefiles]}'";

          '"${${(M)mmode:#tidy}:+d[\"d\"][\"REM LABEL\"]=\"${${labels[$walkcuefiles]//\"/＂}//\\/\\\\}\"}"'
          '"${${(M)mmode:#tidy}:+d[\"d\"][\"REM DATE\"]=\"${${dates[$walkcuefiles]//\"/＂}//\\/\\\\}\"}"'
          '"${${(M)mmode:#tidy}:+d[\"d\"][\"PERFORMER\"]=\"${${aarts[$walkcuefiles]//\"/＂}//\\/\\\\}\"}"'
        }
      '$awkcueput) <(print -rn -- ${cuebuffers[$walkcuefiles]}) | readeof mbuf
      print -rn -- ${mbuf} | delta --paging never <(print -rn -- ${cuebuffers[$walkcuefiles]}) - || :
      local awkcuemput='
      ARGIND==1 {
        if (NR%2==1) {
          match($0,/^([^.]+)\.([^.]+)$/,parsekeyname)
        } else {
          if (length(parsekeyname[1])) {
            d[parsekeyname[1]][parsekeyname[2]]=$0
          }
        }
      }
      function joinkey(m,n,  k, l) {
        n==0&&n=="" ? n="|" : 1
        for (k in m) {
          l=(l (l==0&&l=="" ? "" : n) k)
        }
        return l
      }
      function pd(k,  tr, pad) {
        if (k in d[tr==""&&tr==0 ? "d" : tr]) {
          if (length(d[tr==""&&tr==0 ? "d" : tr][k])) {
            printf "%s",(pad==""&&pad==0 ? "" : pad)
            switch (k) {
              case "REM DISCNUMBER" :
              case "REM TOTALDISCS" :
              case "REM DATE" :
              case "REM CATALOGNUMBER" :
                print k " " (tr==""&&tr==0 ? d["d"][k] : d[tr][k]);
                break;
              default :
                print k " \"" (tr==""&&tr==0 ? d["d"][k] : d[tr][k]) "\"" (k=="FILE" ? " WAVE" : "")
                break;
            }
          }
          if (tr==0&&tr=="")
            delete d["d"][k]
          else
            delete d[tr][k]
        }
      }
      ARGIND==2&&/^[ \t]*(TRACK|ISRC|FLAGS|INDEX)/ {
        if (nt && nt in d && length(d[nt])) {
          for (k in d[nt])
            pd(k, nt, matches[1])
        }
      }
      ARGIND==2&&/^[ \t]*(TRACK|FILE)/ {
        if (!nt && "d" in d && length(d["d"])) {
          for (k in d["d"]) {
            if (/^[ \t]*FILE/ && k=="FILE")
              continue;
            pd(k)
          }
        }
      }
      ARGIND==2&&/^[ \t]*TRACK/ {
        ++nt
        jtd[nt]=(nt in d && length(d[nt]) ? joinkey(d[nt]) : "")
        print
        next
      }
      ARGIND==2&&nt&&/[^ \t]/ {
        if (length(jtd[nt]) && match($0,("^([ \t]*)((" jtd[nt] ")( |$)|)"),matches) && length(matches[3])) {
          m=matches[3]
          pd(m, nt, matches[1])
        } else
          print;
      }
      END {
        if (!nt || ("d" in d && length(d["d"]))) exit(1)
        if (nt && nt in d && length(d[nt])) {
          for (k in d[nt])
            pd(k, nt, matches[1])
        }
      }
      BEGINFILE {
        if (ARGIND==2)
          jdd=("d" in d && length(d["d"]) ? joinkey(d["d"]) : "")
      }
      ARGIND==2&&!nt&&/[^ \t]/ {
        if (length(jdd) && match($0,("^([ \t]*)((" jdd ")( |$)|)"),matches) && length(matches[3])) {
          m=matches[3]
          pd(m)
        } else
          print;
      }
      '
      local REPLY=
      mbufs+=($mbuf)
      while :; do
        timeout 0.1 cat >/dev/null || :
        read -k1 "REPLY?${cuefiles[$walkcuefiles]:t} [y/p/e/d/u($((${#mbufs}-1)))/m/t/q] "
        timeout 0.01 cat >/dev/null || :
        case "$REPLY" in
          ([^$'\n']) echo
          ;|
          (y|p)
            if ! print -rn -- ${mbufs[-1]} | cueprint -i cue -d ":: %T\n" -t "%02n.%t\n"; then
              .err 'malformed cuesheet'
              continue
            fi
          ;|
          ([yY])
            if ! print -rn -- ${mbufs[-1]} | cmp -s -- ${cuefiles[$walkcuefiles]}; then
              print -rn -- ${mbufs[-1]} | rw -- ${cuefiles[$walkcuefiles]}
            fi
          ;|
          (y|[pP])
            if [[ "$ofmt" != none ]]; then
              cuedump=("${(@Q)${(@z)${(@f)$(gawk -E <(print -rn -- $awkcuedump) - <<< ${mbufs[-1]})}}}") || continue
              local -A ffprobe
              if [[ "$mmode" == fifo ]]; then
              ffprobe=()
              else
              ffprobe=("${(@Q)${(@z)${(@f)"$(ffprobe -err_detect explode -show_entries streams:format -of flat -hide_banner -loglevel warning -select_streams a -i $ifile)"}/=/ }}")
              case "${ffprobe[format.format_name]}" in
                (flac)
                ;&
                (wv)
                ;&
                (wav|tak|tta|ape)
                  [[ "${ffprobe[streams.stream.0.sample_rate]}:c${ffprobe[streams.stream.0.channels]}:${ffprobe[streams.stream.0.sample_fmt]}" = 44100:c2:s16(|p) ]] || .fatal "unsupported rate/channel/samplefmt setup: ${ffprobe[streams.stream.0.sample_rate]}:c${ffprobe[streams.stream.0.channels]}:${ffprobe[streams.stream.0.sample_fmt]}"
                  (( ffprobe[streams.stream.0.duration_ts]%588==0 )) || .warn 'uneven number of samples, not a CD-DA source?'
                  if (( ffprobe[streams.stream.0.duration_ts] - cuedump[${cuedump[tc]}.pskip] < 44100*3 )); then
                    .warn 'last track only last '$(( (ffprobe[streams.stream.0.duration_ts] - cuedump[${cuedump[tc]}.pskip]) / 44100 ))' seconds'
                  elif (( ffprobe[streams.stream.0.duration_ts] < cuedump[${cuedump[tc]}.pskip]+588 )); then
                    .fatal 'cuesheet specified a timestamp beyond the duration of FILE (mismatched FILE?)'
                  fi
                ;;
                (*)
                .fatal 'unsupported fmt: '${format.format_name}
              esac
              fi ## if [[ "$mmode" != fifo ]]; then
              local runenc rundec tn
              case "$ofmt" in
                (null) runenc=$'pv\n-qX;:\n' ;|
                (aotuv) runenc=$'oggenc\n-Qq5\n-s\n....\n' ;|
                (flac) runenc=$'flac\n-V8cs\n' ;|
                (fdkaac|qaac|exhale) runenc=${ostr[$ofmt]// ##/
} ;|
                (exhale)
                if [[ "${#ofmtargs}" -ge 1 ]]; then
                  runenc+=$'\n'"${(@pj.\n.)ofmtargs}"$'\n'
                  ofmtargs=()
                else
                  runenc+=$'\n3\n'
                fi
                runenc+='"$outfnpref/$outfnsuff".m4a'
                runenc+=';if
[[
-n
"${${cuedump[$tn.REM VOCALIST]}:-${cuedump[d.REM VOCALIST]}}"
]];
then
MP4Box
$outfnpref/$outfnsuff.m4a
-inter
0
-keep-utc
-bo
-lang
ja;
fi;
mp4tagcli
--
"$outfnpref/$outfnsuff".m4a'
                ;|
                (aotuv|flac)
                runenc+='
--comment=TRACKNUMBER=${cuedump[$tn.tnum]/#0}
'
                ;|
                (aotuv|flac|fdkaac|qaac|exhale)
                runenc+='
${${${cuedump[$tn.TITLE]/#[    ]#}/%[   ]#}:+--comment=TITLE=${${cuedump[$tn.TITLE]/#[    ]#}/%[   ]#}}
${${${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM COMPOSER]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM COMPOSER]:-${cuedump[d.SONGWRITER]}}}}}}}/#[	 ]##}/%[	 ]##}:+--comment=COMPOSER=}${^${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM COMPOSER]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM COMPOSER]:-${cuedump[d.SONGWRITER]}}}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM ARRANGER]:-${cuedump[d.REM ARRANGER]}}}}}/#[	 ]##}/%[	 ]##}:+--comment=ARRANGER=}${^${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM ARRANGER]:-${cuedump[d.REM ARRANGER]}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM LYRICIST]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM LYRICIST]:-${cuedump[d.SONGWRITER]}}}}}}}/#[	 ]##}/%[	 ]##}:+--comment=LYRICIST=}${^${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM LYRICIST]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM LYRICIST]:-${cuedump[d.SONGWRITER]}}}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.VOCALIST]:-${cuedump[d.VOCALIST]}}}}}/#[	 ]##}/%[	 ]##}:+--comment=VOCALIST=}${^${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.VOCALIST]:-${cuedump[d.VOCALIST]}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.PERFORMER]:-${cuedump[d.PERFORMER]}}}}}/#[	 ]##}/%[	 ]##}:+--comment=ARTIST=}${^${${(s|・|)${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.PERFORMER]:-${cuedump[d.PERFORMER]}}}}}/#[	 ]##}/%[	 ]##}
${${${cuedump[d.TITLE]/#[    ]#}/%[   ]#}:+--comment=ALBUM=${${cuedump[d.TITLE]/#[    ]#}/%[   ]#}}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[d.PERFORMER]}}}//#[	 ]##}//%[	 ]##}:+--comment=ALBUMARTIST=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[d.PERFORMER]}}}/#[	 ]##}/%[	 ]##}
'
                ;|
                (aotuv|flac)
                runenc+='
${cuedump[d.REM DISCNUMBER]:+--comment=DISCNUMBER=${cuedump[d.REM DISCNUMBER]}}
${cuedump[date]:+--comment=DATE=${cuedump[date]}}
'
                ;|
                (fdkaac|qaac|exhale)
                runenc+='
${${${(M)${#cuedump[date]}:#10}:+--tag=day:${cuedump[date]}T00:00:00Z}:-${cuedump[date]:+--tag=day:${cuedump[date]}}}
'
                ;|
                (aotuv|flac|fdkaac|qaac|exhale)
                runenc+='
${${${${(s| / |)${(s|×|)${(s|、|)cuedump[d.REM LABEL]}}}//#[	 ]##}//%[	 ]##}:+--comment=LABEL=}${^${${(s| / |)${(s|×|)${(s|、|)cuedump[d.REM LABEL]}}}/#[	 ]##}/%[	 ]##}
${${${${cuedump[$tn.REM COMMENT]:-${cuedump[d.REM COMMENT]}}//#[	 ]#}//%[	 ]#}:+--comment=COMMENT=${${${cuedump[$tn.REM COMMENT]:-${cuedump[d.REM COMMENT]}}/#[	 ]#}/%[	 ]#}}
${cuedump[d.REM CATALOGNUMBER]:+--comment=CATALOGNUMBER=${cuedump[d.REM CATALOGNUMBER]}}
${${cuedump[$tn.REM GENRE]:-${cuedump[d.REM GENRE]}}:+--comment=GENRE=${cuedump[$tn.REM GENRE]:-${cuedump[d.REM GENRE]}}}
'
                ;|
                (aotuv|flac)
                runenc+='
${cuedump[d.REM TOTALDISCS]:+--comment=DISCTOTAL=${cuedump[d.REM TOTALDISCS]}}
--comment=TRACKTOTAL=${cuedump[tc]}
'
                ;|
                (fdkaac|qaac|exhale)
                runenc+='
${${${(M)cuedump[d.REM TOTALDISCS]:#1}:+--tag=disk:1/1}:-${cuedump[d.REM DISCNUMBER]:+--tag=disk:${cuedump[d.REM DISCNUMBER]}${cuedump[d.REM TOTALDISCS]:+/${cuedump[d.REM TOTALDISCS]}}}}
--tag=trkn:${cuedump[$tn.tnum]/#0}/${cuedump[tc]}
'
                ;|
                (aotuv|flac|fdkaac|qaac|exhale)
                runenc+='
${cuedump[$tn.ISRC]:+--comment=ISRC=${cuedump[$tn.ISRC]}}
${cuedump[d.REM MUSICBRAINZ_ALBUMID]:+--comment=MUSICBRAINZ_ALBUMID=${cuedump[d.REM MUSICBRAINZ_ALBUMID]}}
${cuedump[$tn.REM MUSICBRAINZ_RELEASETRACKID]:+--comment=MUSICBRAINZ_RELEASETRACKID=${cuedump[$tn.REM MUSICBRAINZ_RELEASETRACKID]}}
${cuedump[$tn.REM BPM]+--comment=BPM=${cuedump[$tn.REM BPM]}}
${${${ofmt:#exhale}:-${replaygain:#0}}:+${${cuedump[$tn.REM REPLAYGAIN_TRACK_GAIN]:-${REPLAYGAIN_TRACK_GAINs[$tn]}}:+--comment=REPLAYGAIN_TRACK_GAIN=${cuedump[$tn.REM REPLAYGAIN_TRACK_GAIN]:-${REPLAYGAIN_TRACK_GAINs[$tn]}}}
${${cuedump[$tn.REM REPLAYGAIN_TRACK_PEAK]:-${REPLAYGAIN_TRACK_PEAKs[$tn]}}:+--comment=REPLAYGAIN_TRACK_PEAK=${cuedump[$tn.REM REPLAYGAIN_TRACK_PEAK]:-${REPLAYGAIN_TRACK_PEAKs[$tn]}}}
${cuedump[d.REM REPLAYGAIN_ALBUM_GAIN]:+--comment=REPLAYGAIN_ALBUM_GAIN=${cuedump[d.REM REPLAYGAIN_ALBUM_GAIN]}}
${cuedump[d.REM REPLAYGAIN_ALBUM_PEAK]:+--comment=REPLAYGAIN_ALBUM_PEAK=${cuedump[d.REM REPLAYGAIN_ALBUM_PEAK]}}}
'
                ;|
                (aotuv|flac|fdkaac|qaac)
                runenc+='-o
"$outfnpref/$outfnsuff"'
                ;|
                (aotuv) runenc+=.ogg ;|
                (flac) runenc+=.flac ;|
                (fdkaac|qaac) runenc+=.m4a ;|
                ## bypass the trailing `-` in for loop
                (exhale) runenc+=$';:\n' ;|
                (fdkaac|qaac)
                function {
                  while ((#)); do
                    if (( ${#vorbiscmt2itunes[$1]} <= 4 )); then
                      runenc="${(@pj.\n.)${(@f)runenc}//--comment=$1=/--tag=${vorbiscmt2itunes[$1]}:}"
                    else
                      runenc="${(@pj.\n.)${(@f)runenc}//--comment=$1=/--long-tag=${vorbiscmt2itunes[$1]}:}"
                    fi
                    shift
                  done
                  local match=()
                  if (( ${(M)#runenc:#*--comment=*} )); then
                    runenc=${runenc//\(s\|[^|]##\|\)}
                    setopt localoptions histsubstpattern
                    runenc=${runenc:gs/--comment=(#b)([^=]##)(#B)=/--long-tag='${match[1]}:'/}
                  fi
                } ${(k)vorbiscmt2itunes}
                ;|
                (exhale)
                function {
                  while ((#)); do
                    if (( ${#vorbiscmt2itunes[$1]} <= 4 )); then
                      runenc="${(@pj.\n.)${(@f)runenc}//--(comment|tag)=$1[=:]/${vorbiscmt2itunes[$1]}=}"
                    else
                      runenc="${(@pj.\n.)${(@f)runenc}//--(comment|long-tag)=$1[=:]/----:com.apple.iTunes:${vorbiscmt2itunes[$1]}=}"
                    fi
                    shift
                  done
                  local match=()
                  if (( ${(M)#runenc:#*--comment=*} )); then
                    runenc=${runenc//\(s\|[^|]##\|\)}
                    setopt localoptions histsubstpattern
                    runenc=${runenc:gs/--comment=(#b)([^=]##)(#B)=/----:com.apple.iTunes:'${match[1]}='/}
                    match=()
                    runenc=${runenc:gs/--tag=(#b)([^=](#c3,4))(#B):/'${match[1]}='/}
                  fi
                } ${(k)vorbiscmt2itunes}
                ;|
                (flac) runenc=${runenc//--comment=/--tag=} ;|
              esac
              local -a seltnums=()
              timeout 0.01 cat >/dev/null||:

              local outfnsuff_t='${${:-${cuedump[d.REM DISCNUMBER]:+${cuedump[d.REM DISCNUMBER]}#}${cuedump[$tn.tnum]}${cuedump[$tn.TITLE]:+.${cuedump[$tn.TITLE]//\//／}}}:0:80}'

              if [[ "$mmode" == lrc ]]; then function {
                  argv=(${cuedump[(I)(d|<1->).REM VOCALIST]})
                  if ((#)); then while ((#)); do
                      if [[ -z "${cuedump[$1]}" ]]; then
                        .warn "empty $1 field, please either edit or remove it."
                        continue
                      fi
                      shift
                    done
                  else
                    .warn 'no track tagged vocalist'
                    continue
                  fi
                }
              fi
              if [[ "$mmode" == lrc ]]; then while :; do
                seltnums=("${(@f)$(function {
                  if [[ -n "${cuedump[d.REM VOCALIST]}" ]]; then
                    argv=(${(@)^${(@Mn)${(@k)cuedump}:#<1->.tnum}%.*})
                  else
                    argv=(${(@)^${(@Mn)${(@k)cuedump}:#<1->.REM VOCALIST}%.*})
                  fi
                  setopt histsubstpattern
                  local match=()
                  while ((#)); do
                    printf '%-2d %-4s' $1 ${cuedump[$1.tnum]}
                    function {
                      if ((#)); then
                        argv=(${(@)argv%(#i).lrc})
                        printf "%-8s" '+'${(j|,|)argv:l}
                      else
                        printf "%-8s" ''
                      fi
                    } ${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${(e)outfnsuff_t//\$tn/\$1}.(#i)(|(zh|cn|ja|jp).)lrc(#qN.L+10:s/#%*(#b)(#i)((.(zh|cn|ja|jp|n)|).lrc)/'${match[1]}'/:l)
                    printf ' %s[%s]\n' "${cuedump[$1.TITLE]}		[@${${cuedump[$1.REM VOCALIST]}:-${cuedump[d.REM VOCALIST]}}]" ${$(TZ=UTC date +%H:%M:%S -d @$(( ${cuedump[$1.plen]:-0} / 44100))):#00:}
                    shift
                  done
                  printf '%s\n' 'done [done]'
                  } | fzf --accept-nth=1 --layout=reverse-list --with-nth=2..)}"
                )
                case "${seltnums}"; in
                  (done) break ${${(M)ofmt:#null}:+2};;
                  (<0->)
                    local lrckey=
                    function fetch {
                      command curl -qgLsfy6 -Y1 "${(@)argv}"
                    }
                    while :; do read -k 1 "lrckey?${(e)outfnsuff_t//\$tn/\$seltnums}?lrc.action [ypq]"
                      case "$lrckey" in
                        (y)
                          local ncmquery="${cuedump[$seltnums.TITLE]} ${${cuedump[$seltnums.REM VOCALIST]}:-${cuedump[d.REM VOCALIST]}} ${cuedump[d.TITLE]}"
                          vared -chp 'keyword> ' ncmquery || continue
                          local ncmresult="$(fetch "$NCMAPI/cloudsearch?keywords=$( printf %s $ncmquery|uconv -x ':: NFKC; [^[:Alphabetic=Yes:]1234567890] > \ ;'|basenc --base16 -w0|sed -Ee 's@(..)@%\1@g')" )" || continue
                          if ! printf %s $ncmresult | jq -r 'if (.result.songCount>0) then halt else empty|halt_error end'; then
                            .warn "no result"
                            continue
                          fi
                          local -a ncmresults=(
                            "${(@0)$( printf %s $ncmresult | jq --raw-output0 '.result.songs[]|[.id,.name,([.ar[].name]|join("/")),.al.name,.dt,.cd,.no]|join("\n")' )}"
                          )
                          while :; do
                          local selncmresults="$(printf '%s\0' ${ncmresults} | gawk -v FS=$'\n' -v dt=5 'BEGIN{OFS=FS;RS="\0";ORS=RS}{$(dt)=$(dt)/1000;re_min=($(dt)%60); if (re_min) {$(dt)=(($(dt)-re_min)/60 ":" sprintf("%02d",re_min))} else {$(dt)=("00:" sprintf("%02d",re_min))}}{print}' | fzf --no-sort --layout=reverse-list -d $'\n' --read0 --wrap --accept-nth=1 -n '2..4' --with-nth=$'{6}#{7}.\t{2}\n\t({4})\n[{5}][@{3}]')"
                          (( ${#selncmresults[1]} )) || break
                          local ncmlrcreply="$(fetch $NCMAPI"/lyric/new?id=$selncmresults")"
                          local lrcbuf="$(jq -r '.lrc.lyric' <<< $ncmlrcreply | sed -e '/^[{]/d')"
                          local trcbuf="$(jq -r '.tlyric.lyric' <<< $ncmlrcreply)"
                          if ! [[ -n "$lrcbuf" ]]; then
                            .warn 'no lyric data associated with this song!'
                            read
                            continue
                          fi
                          rw -- ${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${(e)outfnsuff_t//\$tn/\$seltnums}.lrc <<< ${lrcbuf%%[$'\n']##}
                          if [[ -n "$trcbuf" ]]; then
                            rw -- ${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${(e)outfnsuff_t//\$tn/\$seltnums}.zh.lrc  <<< ${trcbuf%%[$'\n']##}
                          fi
                          break
                          done
                          ;;
                        ([ceyp]) local lrcfiles=(${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${(e)outfnsuff_t//\$tn/\$seltnums}.(#i)(|(zh|cn|ja|jp|n).)lrc(N.L+10))
                          ;|
                        ([ce])
                          if (( $#lrcfiles )); then
                            local editthislrc="$(fzf <<< ${(F)lrcfiles})" || continue
                            if (( !$#editthislrc )); then
                              continue
                            fi
                          else
                            .warn 'no lrc file available to process.'
                            continue
                          fi
                          ;|
                        (c)
                          local clrcbuf="$(opencc -c s2t -i $editthislrc | opencc -c t2jp)"
                          if (( $#clrcbuf>10 )) && ! cmp -s $editthislrc - <<< $clrcbuf; then
                            delta --paging never -- $editthislrc - <<< $clrcbuf || :
                            rw -- $editthislrc <<< $clrcbuf
                          fi
                          ;|
                        (e)
                          zed $editthislrc || continue
                          ;|
                        (y|p)
                          mpv --start="#$seltnums" ${${$(( seltnums==cuedump[tc] ))/#%1}/#%0/--end=#$((seltnums+1))} --{,secondary-}sub-delay="$(( 60 * ${${(s|:|)cuedump[$seltnums.INDEX 01]}[1]#0} * 75 + ${${(s|:|)cuedump[$seltnums.INDEX 01]}[2]#0} * 75 + ${${(s|:|)cuedump[$seltnums.INDEX 01]}[3]#0} ))/75" --sub-file=${(@)^lrcfiles} -- ${cuefiles[$walkcuefiles]} ;;
                        (q) break ;;
                      esac
                    done
                  ;;
                esac
              done
              fi
              if [[ "$ofmt" != null ]]; then
              seltnums=("${(@)${(@f)$(function {
  while ((#)); do
    printf '%-2d  %s\n' ${1%%.*} ${cuedump[${1%%.*}.TITLE]}${cuedump[${1%%.*}.PERFORMER]:+		"[@"${cuedump[${1%%.*}.PERFORMER]}"]"}
    shift
  done
} ${(@Mn)${(@k)cuedump}:#<1->.tnum} | fzf -m --layout=reverse-list --prompt="${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} select:")}%% *}") || {
                timeout 0.01 cat >/dev/null||:
                seltnums=(${(@)${(@Mn)${(@k)cuedump}:#<1->.tnum}%.*})
                function {
                  if argv=("${(@)${(@f)$(function {
  while ((#)); do
    printf '%-2d  %s\n' ${1} ${cuedump[${1}.TITLE]}${cuedump[${1}.PERFORMER]:+		"[@"${cuedump[${1}.PERFORMER]}"]"}
    shift
  done
} $seltnums | fzf -m --layout=reverse-list --prompt="${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} skip:")}%% *}"); then
                    seltnums=(${seltnums:|argv})
                  fi
                }
                (( $#seltnums )) || continue
              }
              else
                seltnums=(${(@)${(@Mn)${(@k)cuedump}:#<1->.tnum}%.*})
              fi

              local -a testbpms=()
              local -a testmusicalkeys=()
              local -a REPLAYGAIN_TRACK_GAINs=() REPLAYGAIN_TRACK_PEAKs=()
              case "${ffprobe[format.format_name]}" in
                (wv) wvunpack -qmvz0 -- $ifile
                rundec='wvunpack -q -z0 -o -'
                ;;
                (flac) flac -ts -- $ifile
                rundec='flac -dcs'
                ;;
                (tak)
                  if [[ -v commands[takc] ]]; then
                    local embedmd5="${(@)${(@s.;.)$(takc -fi -fim5 ./$ifile)}[6]}"
                    if (( $#embedmd5 == 32 )); then
                      [[ "${$(ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f s16le -|md5sum --tag -)##* = }" == $embedmd5 ]]
                    fi
                  fi
                ;;
                (ape)
                  if [[ -v commands[wine] ]]; then
                    wine mac $ifile -v
                  fi
                ;;
              esac
            fi
            ;|
          (y)
            if [[ "$mmode" == tidy && "$ofmt" != none ]]; then
              match=()
              : ${(M)${ifile:t:r}:#?*\#soxStatExclNull.Samples(#b)([0-9]##)(#B)(|.XXH3_(#b)([0-9a-fA-F](#c16))(#B))(|\#*)}
              local oldsamplecount=${match[1]}
              local oldxxh3=${match[2]:l}
              if ! (( $#oldxxh3 && $#oldsamplecount )); then
                function {
                  argv=("${(@f)$({ ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f wav -|LC_ALL=C sox -Dtwav - -traw - silence 1 1 0 -1 1 0 stat|xxhsum --tag -H3 -; } 2>&1;)}")
                  oldsamplecount=${argv[(r)Samples read: #[0-9]##]##*: #}
                  oldxxh3=${argv[(r)XXH3 \(?*\) = [0-9a-f](#c16)]##* = }
                  (( $#oldsamplecount && $#oldxxh3==16 ))
                }
              else
                function {
                  argv=("${(@f)$({ ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f wav -|LC_ALL=C sox -Dtwav - -traw - silence 1 1 0 -1 1 0 stat|xxhsum --tag -H3 -; } 2>&1;)}")
                  local newsamplecount=${argv[(r)Samples read: #[0-9]##]##*: #}
                  local newxxh3=${argv[(r)XXH3 \(?*\) = [0-9a-f](#c16)]##* = }
                  [[ "$oldsamplecount" == "$newsamplecount" ]]
                  [[ "$oldxxh3" == "$newxxh3" ]]
                }
              fi
              if [[ -v commands[takc] ]]; then
                local CUESHEET="$(cueconvert -i cue -o toc <<< ${mbufs[-1]}|cueconvert -i toc -o cue|sed -Ee '/("|^$)/d')"
                case "${ffprobe[format.format_name]}" in
                  (flac|wv)
                    command ${(z)rundec} -- $ifile | command ${(z)ostr[takc]} -tt CUESHEET="$CUESHEET" - ./${ifile:r}.tak
                  ;|
                  (wav)
                  command ${(z)ostr[takc]} -tt CUESHEET="$CUESHEET" ./${ifile} ./${ifile:r}.tak
                  ;|
                  (tta)
                  command ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f wav - | command ${(z)ostr[takc]} -tt CUESHEET="$CUESHEET" - ./${ifile:r}.tak
                  ;|
                  (tta|flac|wav|wv)
                  function {
                    argv=("${(@f)$({ ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i ${ifile:r}.tak -f wav -|LC_ALL=C sox -Dtwav - -traw - silence 1 1 0 -1 1 0 stat|xxhsum --tag -H3 -; } 2>&1;)}")
                    local newsamplecount=${argv[(r)Samples read: #[0-9]##]##*: #}
                    local newxxh3=${argv[(r)XXH3 \(?*\) = [0-9a-f](#c16)]##* = }
                    [[ "$oldsamplecount" == "$newsamplecount" ]]
                    [[ "$oldxxh3" == "$newxxh3" ]]
                  }
                  ;|
                esac
              fi
              if [[ "${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3" != "${${ifile:r}%\#convFrom.[^.]##}" ]]; then
                mv -vo -- ${${${commands[takc]:+${(M)ffprobe[format.format_name]:#(flac|wv|wav|tta)}}:+${ifile:r}.tak}:-$ifile} "${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3${${commands[takc]:+${(M)ffprobe[format.format_name]:#(flac|wv|wav|tta)}}:+#convFrom.${ffprobe[format.format_name]}}.${${${commands[takc]:+${(M)ffprobe[format.format_name]:#(flac|wv|wav|tta)}}:+tak}:-${ifile:e}}"
                if [[ -f "${ifile:r}".(#i)log ]]; then
                  mv -- "${ifile:r}".(#i)log "${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3.${ifile:e}.log"
                fi
                ifile="${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3${${commands[takc]:+${(M)ffprobe[format.format_name]:#(flac|wv|wav|tta)}}:+#convFrom.${ffprobe[format.format_name]}}.${${${commands[takc]:+${(M)ffprobe[format.format_name]:#(flac|wv|wav|tta)}}:+tak}:-${ifile:e}}"
                gawk -E <(print -r -- $awkcuemput) <(printf '%s\n%s\n' d.FILE ${ifile#${${(M)cuefiles[$walkcuefiles]:#*/?*}:+${cuefiles[$walkcuefiles]:h}/}}) <(print -r -- ${mbufs[-1]}) | readeof mbuf
                mbufs+=($mbuf)
                if [[ "${cuefiles[$walkcuefiles]}" != ${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3(#i).cue   ]]; then
                  mv -v -- "${cuefiles[$walkcuefiles]}" ${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3.cue
                  cuefiles[$walkcuefiles]=${${ifile:r}%%\#soxStatExclNull.Samples[0-9]##(.XXH3_[0-9a-f](#c16)|)(\#*|)}#soxStatExclNull.Samples$oldsamplecount.XXH3_$oldxxh3.cue
                fi
                if ! print -rn -- ${mbufs[-1]} | cmp -s -- ${cuefiles[$walkcuefiles]}; then
                  print -rn -- ${mbufs[-1]} | rw -- ${cuefiles[$walkcuefiles]}
                fi
                ffprobe=("${(@Q)${(@z)${(@f)"$(ffprobe -err_detect explode -show_entries streams:format -of flat -hide_banner -loglevel warning -select_streams a -i $ifile)"}/=/ }}")
              fi
            fi
            ;|
          (y|[pP])
            if (( $#ofmt )) && [[ "$ofmt" != none ]]; then
              case "${ffprobe[format.format_name]}" in
                (ape)
                  if [[ -v commands[wine] ]] && [[ "$ofmt" == null ]]; then
                    break
                  fi
                ;|
                (tak)
                  if [[ -v commands[takc] ]] && (( $#embedmd5 == 32 )) && [[ "$ofmt" == null ]]; then
                    break
                  fi
                ;|
                (flac|wv)
                  if [[ "$ofmt" == null ]]; then
                    break
                  fi
                ;|
                (*)
                  local outfnpref="${outdir:-/sdcard/Music/albums}/[${${${${cuedump[d.REM LABEL]:-${cuedump[d.PERFORMER]}}:+${cuedump[d.REM LABEL]:-(${cuedump[d.PERFORMER]})}}:-(no label)}//\//∕}]/${${:-${${${cuedump[d.TITLE]:-(no title)}/#./．}//\//∕} ${cuedump[d.REM CATALOGNUMBER]:+[${cuedump[d.REM CATALOGNUMBER]}]}${cuedump[d.REM DATE]:+[${cuedump[d.REM DATE]//\//.}]}}}"

                  if [[ ! -d "$outfnpref" ]]; then
                    mkdir -vp -- $outfnpref
                  fi
                ;|
                (flac|wv)
                  while (( $#seltnums )); do
                    if ! [[ "$ofmt" == exhale && "$replaygain" == (0|) ]] && ! (( ${#cuedump[${seltnums[1]}.REM REPLAYGAIN_TRACK_GAIN]} && ${#cuedump[${seltnums[1]}.REM REPLAYGAIN_TRACK_PEAK]} )) && [[ "$ofmt" != null ]]; then
                      local REPLAYGAIN_TRACK_GAIN= REPLAYGAIN_TRACK_PEAK=
                      command ${(s. .)rundec} ${${(M)cuedump[${seltnums[1]}.skip]:#<1->}:+--skip=${cuedump[${seltnums[1]}.skip]}} ${${(M)cuedump[${seltnums[1]}.until]:#<1->}:+--until=${cuedump[${seltnums[1]}.until]}} -- $ifile | gainstdin
                      REPLAYGAIN_TRACK_GAINs[${seltnums[1]}]=$REPLAYGAIN_TRACK_GAIN
                      REPLAYGAIN_TRACK_PEAKs[${seltnums[1]}]=$REPLAYGAIN_TRACK_PEAK
                    fi
                    local outfnsuff="${(e)outfnsuff_t}"
                    command ${(s. .)rundec} ${${(M)cuedump[${seltnums[1]}.skip]:#<1->}:+--skip=${cuedump[${seltnums[1]}.skip]}} ${${(M)cuedump[${seltnums[1]}.until]:#<1->}:+--until=${cuedump[${seltnums[1]}.until]}} -- $ifile | rw | eval command ${${${${(f)runenc}:#}//\[\$tn./'[${seltnums[1]}.'}//\[\$tn\]/'[${seltnums[1]}]'} "${(@q)ofmtargs}" -
                    shift seltnums
                  done
                ;|
                (wav|tak|tta|ape|)
                  ## match empty fmt in case of fifo mmode
                  case "$ofmt" in
                    (flac) runenc+=$'\n--force-raw-format\n--sign=signed\n--endian=little\n--channels=2\n--bps=16\n--sample-rate=44100\n'
                    ;;
                    (aotuv|fdkaac) runenc+=$'\n--raw\n'
                    ;;
                  esac
                  if [[ "$mmode" != fifo ]] && ! [[ "$ofmt" == exhale && "$replaygain" == (0|) ]] && [[ "$ofmt" != null ]]; then
                    command ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f s16le - | {
                      for ((tn=1;tn<=cuedump[tc];tn++)); do
                        if (( ${seltnums[(I)$tn]} )); then
                          local REPLAYGAIN_TRACK_GAIN= REPLAYGAIN_TRACK_PEAK=
                          dd bs=128K ${${(M)cuedump[$tn.pskip]:#<1->}:+skip=$(( 4 * ${cuedump[$tn.pskip]} ))B} ${${(M)cuedump[$tn.plen]}:+count=$(( 4 * ${cuedump[$tn.plen]} ))B} iflag=fullblock status=none | gainstdin s16le
                          REPLAYGAIN_TRACK_GAINs[$tn]=$REPLAYGAIN_TRACK_GAIN
                          REPLAYGAIN_TRACK_PEAKs[$tn]=$REPLAYGAIN_TRACK_PEAK
                        else
                          pv -qX${cuedump[$tn.plen]:+Ss$((4*cuedump[$tn.plen]+4*cuedump[$tn.pskip]))}
                        fi
                      done
                    }
                  elif [[ "$mmode" == fifo ]]; then
                    ifile=$fifo
                  fi
                  command ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f s16le - | (
                    for ((tn=1;tn<=cuedump[tc];tn++)); do
                      local outfnsuff="${(e)outfnsuff_t}"
                      if (( ${seltnums[(I)$tn]} )); then
                        dd bs=128K ${${(M)cuedump[$tn.pskip]:#<1->}:+skip=$(( 4 * ${cuedump[$tn.pskip]} ))B} ${${(M)cuedump[$tn.plen]}:+count=$(( 4 * ${cuedump[$tn.plen]} ))B} iflag=fullblock status=none | rw | eval command ${${(f)runenc}:#} "${(@q)ofmtargs}" -
                      else
                        pv -qX${cuedump[$tn.plen]:+Ss$((4*cuedump[$tn.plen]+4*cuedump[$tn.pskip]))}
                      fi
                    done
                  )
                ;|
              esac
            fi
            break
          ;|
          (e)
            mbuf="${$(print -rn -- $mbuf | zed):-$mbuf}" || continue
            if (( $#mbuf )) && [[ ${mbufs[-1]} != $mbuf$'\n' ]]; then
              mbufs+=($mbuf$'\n')
              print -rn -- ${mbufs[-1]} | delta --paging=never <(print -rn -- ${mbufs[-2]}) - || :
            else
              mbuf=${mbufs[-1]}
            fi
          ;|
          (d)
            if (( $#mbufs >1 )); then
              print -rn -- ${mbufs[-1]} | delta --paging=never <(print -rn -- ${mbufs[1]}) - || :
            else
              print -rn -- ${mbufs[-1]} | delta --paging=never -- ${cuefiles[$walkcuefiles]} - || :
            fi
          ;|
          (m)
            local askmbid=$askmbid
            timeout 0.01 cat >/dev/null || :
            vared -ehp 'm:mbid> ' askmbid
            function {
              argv=(${(f)mbufs[-1]})
              if (( ${argv[(i)[ 	]#TRACK]} <= $# && ${argv[(i)[ 	]#TRACK]}>1 )); then argv=(${argv[1,$((${argv[(i)[ 	]#TRACK]}-1))]}); fi
              local testbarcode=${${argv[(R)[ 	]#CATALOG ?(#c12,13)]}#[ 	]#CATALOG }
              if ! python ${ZSH_ARGZERO%/*}/external.deps/mbcue/mbcue.py ${testbarcode:+-b $testbarcode} -n ${discnumbers[$walkcuefiles]} ${(z)${(M)askmbid:#(|https://musicbrainz.org/release/)[0-9a-f](#c8)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c12)(|/*)}:+-r ${${askmbid#https://musicbrainz.org/release/}%%/*}} <(print -rn -- ${mbufs[-1]}) | readeof mbuf; then
                mbuf=${mbufs[-1]}
                continue
              fi
            }
          ;|
          ([ ])
          command bat --file-name buf:${cuefiles[$walkcuefiles]} -pn <(printf '%s' $mbuf)
          ;|
          ([$'\t'])
            local awktxt2tracktitledump='
            /^(|Edit )Disc [0-9]+(| \[[A-Z0-9][-A-Z0-9]*])$/ {
            match($0,/^(|Edit )Disc ([0-9]+) *(|\[([A-Z0-9][-A-Z0-9]*)])$/,ms)
              dn=ms[2]
              if (length(ms[4]))
                catno[dn]=ms[4]
            }
            /^[0-9](|[0-9])\t[^\t]+\t([0-9]+:)+[0-9][0-9]$/ {
              match($0,/^([0-9]+)\t([^\t]+)/,ms)
              ti[0+dn][0+ms[1]]=ms[2]
            }
            /^Submitted by/{
              nextfile
            }
            @include "shellquote"
            END{
              if (0+gdn in ti) {
                for (n in ti[0+gdn]) {
                  print (0+n ".TITLE " shell_quote(ti[0+gdn][n]))
                }
                if (0+gdn in catno)
                  print ("d.REM CATALOGNUMBER " shell_quote(catno[0+gdn]))
              } else if (0 in ti) {
                for (n in ti[0]) {
                  print (0+n ".TITLE " shell_quote(ti[0][n]))
                }
              } else if (1 in ti) {
                for (n in ti[1]) {
                  print (0+n ".TITLE " shell_quote(ti[1][n]))
                }
              } else
                exit(2)
            }
            '
            tracktitledump=(${(@Q)${(@z)${(@f)"$(zed| gawk -v gdn=${discnumbers[$walkcuefiles]:-0} -E <(print -rn -- $awktxt2tracktitledump) -)"}}}) || continue
            function {
              argv=(${(k)tracktitledump})
              while ((#)); do
                printf '%s\n' $1 ${tracktitledump[$1]}
                shift
              done
            } | gawk -E <(print -r -- $awkcuemput) - <(print -r -- ${mbufs[-1]}) | readeof mbuf
          ;|
          ([m$'\t'])
            if (( $#mbuf )) && [[ "${mbufs[-1]}" != "$mbuf" ]]; then
              mbufs+=($mbuf)
              print -rn -- ${mbufs[-1]} | delta --paging=never <(print -rn -- ${mbufs[-2]}) - || :
            else
              mbuf=${mbufs[-1]}
            fi
            continue
          ;|
          (u)
            if (( $#mbufs>1 )); then
              print -rn -- ${mbufs[-1]} | delta --paging=never - <(print -rn -- ${mbufs[-2]}) || :
              shift -p mbufs
            fi
          ;|
          (t)
            cuedump=("${(@Q)${(@z)${(@f)$(gawk -E <(print -rn -- $awkcuedump) - <<< ${mbufs[-1]})}}}") || continue
            while :;do
              local tagkey=
              local -aU tagtnums=()
              local tagvalue=
              timeout 0.01 cat >/dev/null || :
              read -k 1 "tagkey?${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} [${${(@j..)${(@k)commontags}#*:}:l}?q] "
              timeout 0.01 cat >/dev/null || :
              case "$tagkey" in
                ([^$'\n']) echo
                  ;|
                (\?)
                  function {
                    argv=(${${(@)${(@k)commontags}#*:}:l})
                    argv=(${${(@)${(@k)commontags}%:?}:^argv})
                    printf '%s[%s]' ${(@pj.\t.)argv}
                    echo
                  }
                  continue
                ;;
                (q) break
                ;;
              esac
              if [[ "$tagkey" = n ]]; then
                tagtnums=("${(f)$(function {
  while ((#)); do
    printf '%-2d  %s\n' ${1%%.*} ${cuedump[${1%%.*}.TITLE]}${cuedump[${1%%.*}.PERFORMER]:+		"[@"${cuedump[${1%%.*}.PERFORMER]}"]"}
    shift
  done
} ${(@Mn)${(@k)cuedump}:#<1->.tnum} | fzf --layout=reverse-list --prompt="${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).track:")%% *}") || continue
              elif eval '[[ "$tagkey" = ['${(@j..)${(@M)${(@k)commontags#*:}:#[a-z]}:l}'] ]]'; then
                if IFS=" ,	" vared -ehp "${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).tracks:" tagtnums && (( ${(@)#${(@M)tagtnums:#([0-9]##(-[0-9]#|)|d)}} )); then :
                  function {
                    argv=("${(@)${(@Mn)${(@k)cuedump}:#<1->.tnum}%.*}")
                    ((#)) || continue
                    setopt localoptions histsubstpattern
                    local match=()
                    tagtnums=("${(@)${(@)${(@M)tagtnums:#[0-9]##-[0-9]#}/#/<}/%/>}" ${(@)${(@M)tagtnums:#[0-9]##}:s/(#b)(*)(#B)/<'${match[1]}'-'${match[1]}'>/} ${(@M)tagtnums:#d})
                    tagtnums=(${(@M)argv:#${(@)~${(@j.|.)tagtnums}}} ${(@M)tagtnums:#d})
                    argv=(${cuedump[(I)(${(@j.|.)tagtnums}).${(@)commontags[${(@)commontags[(i)*:${tagkey:l}]}]}]})
                    local joinval=
                    while ((#)); do
                      joinval+=${${cuedump[$1]/#[	 ]#}/%[	 ]#}$'\n'
                      shift
                    done
                    argv=(${(fu)joinval})
                    if (( $#==1 )); then
                      tagvalue=${argv[1]}
                    elif (( $#==0 )); then
                      case "$tagkey" in
                        (v) argv=(${cuedump[(I)(${(@j.|.)tagtnums}).PERFORMER]}) ;|
                        (v) joinval=; while ((#)); do
                              joinval+=${${cuedump[$1]/#[	 ]#}/%[	 ]#}$'\n'
                              shift
                            done
                            argv=(${(fu)joinval})
                            if (( $#==1 )); then
                              tagvalue=${argv[1]}
                            elif (( $#==0 )); then
                              tagvalue=${cuedump[d.PERFORMER]}
                            fi
                        ;|
                      esac
                    fi
                  }
                else continue
                fi
              elif eval '[[ "$tagkey" == ['${(@j..)${(@M)${(@k)commontags#*:}:#[A-Z]}:l}'] ]]'; then
                tagvalue=${cuedump[d.${(@)commontags[${(@)commontags[(i)*:${tagkey:u}]}]}]}
              else
                continue
              fi
              if eval '[[ "$tagkey" = ['${(@j..)${(@M)${(@k)commontags#*:}:#[A-Za-z]}:l}'] ]]'; then
                vared -ehp "${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).value:" tagvalue || continue
              fi
              if [[ "$tagkey" = g ]]; then
                tagvalue=${tagvalue:+${(@)genres[(r)($tagvalue|(#i)$tagvalue*)]}}
              fi
              gawk -E <(print -r -- $awkcuemput) <(printf '%s\n' ${^${${(M)tagkey:#[${(@j..)${(@M)${(@k)commontags#*:}:#[A-Z]}:l}]}:+d}:-${^tagtnums}}.${(@)commontags[${(@)${(@k)commontags}[(r)(#i)*:$tagkey]}]}$'\n'${tagvalue}) <(print -rn -- ${mbufs[-1]}) | readeof mbuf
              if (( $#mbuf )) && [[ "${mbufs[-1]}" != "$mbuf" ]]; then
                mbufs+=($mbuf)
                print -rn -- ${mbufs[-1]} | delta --paging=never <(print -rn -- ${mbufs[-2]}) - || :
                break
              else
                mbuf=${mbufs[-1]}
              fi
            done
          ;|
          (q)
            break
          ;|
        esac
      done
    done
  } "${(@)argv}"
}


declare awkcuedump='
BEGIN{
  CONVFMT="%.3f"
}
@include "shellquote"
function Map(re, arr) {
  if (match($0,re,arr)) {
    print (shell_quote((nt==""&&nt==0 ? "d" : nt ) "." arr[1]) " " shell_quote(arr[2]));
    d[nt==""&&nt==0 ? "d" : nt][arr[1]]=arr[2]
    return mkbool(1)
  } else
    return mkbool(0)
}
/^[\t ]*TRACK [0-9][0-9] (AUDIO) *$/{
  match($0,/^[\t ]*TRACK ([0-9][0-9]) ([^ "]+) *$/,rr)
  ++nt
  d[nt]["tnum"]=rr[1]
  tnum2nthtr[rr[1]][length(tnum2thtr[rr[1]])+1]=nt
  d[nt]["mode"]=rr[2]
  d[nt]["tnumoffset"]=0+d[nt]["tnum"]-nt
  if (d[nt]["tnumoffset"] != 0) {
    print ("WARN: non-compliance: nonsequential tracknum found, " nt "th TRACK has a tnum of " d[nt]["tnum"] "(offset " sprintf("%+d",d[nt]["tnumoffset"]) ")") > "/dev/stderr"
  }
  next
}
nt==""&&nt==0&&/[^\t ]/{
  if ((Map("^[\t ]*(REM [A-Z_]+) \"(.*)\" *$",m) || \
   Map("^[\t ]*(REM [A-Z_]+) ([^ \"\t]*) *$",m) || \
   Map("^[\t ]*(CATALOG|CDTEXTFILE|PERFORMER|TITLE|SONGWRITER) \"(.*)\" *$",m) || \
   Map("^[\t ]*(CATALOG) ([^ \"\t]*) *$",m) || \
   Map("^[\t ]*(FILE) \"(.*)\" *(WAVE|FLAC) *$",m)))
    next;
  else {
    print ("FATAL: unrecognized cuesheet command specification found: " shell_quote($0)) > "/dev/stderr"
    exit(1);
  }
}
nt>=0&&nt!=""&&/[^\t ]/{
  if ((Map("^[\t ]*(REM [A-Z_]+) \"(.*)\" *$",m) || \
   Map("^[\t ]*(REM [A-Z_]+) ([^ \"\t]*) *$",m) || \
   Map("^[\t ]*(PERFORMER|TITLE|SONGWRITER) \"(.*)\" *$",m) || \
   Map("^[\t ]*(ISRC) ([^ \"\t]*) *$",m) || \
   Map("^[\t ]*(INDEX [0-9][0-9]|POSTGAP|PREGAP) ([0-9][0-9]:[0-9][0-9]:[0-9][0-9]) *$",m) || \
   Map("^[\t ]*(FLAGS) ((DCP|PRE|4CH|SCMS|DATA)( (DCP|PRE|4CH|SCMS|DATA))*) *$",m))) {
    next
  } else {
    print ("FATAL: unrecognized cuesheet command specification found on TRACK " d[nt]["tnum"] (0+d[nt]["tnum"]!=nt ? " (i.e. " nt "th TRACK)" : "") ": " shell_quote($0)) > "/dev/stderr"
    exit(1);
  }
}
function msfts(msf,  l) {
  if (match(msf,/^([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$/,msfmatches)) {
    return ((msfmatches[1]*60) + msfmatches[2])*44100+msfmatches[3]*588
  } else
    return mkbool(0);
}
END {
  if (nt==0) {
    print "FATAL: no TRACK ever specified" > "/dev/stderr"
    exit(1);
  }
  for (walknt=1;walknt<=nt;walknt++) {
    if ("INDEX 01" in d[walknt]) {
      if ("INDEX 00" in d[walknt]) {
        if (msfts(d[walknt]["INDEX 00"]) > msfts(d[walknt]["INDEX 01"])) {
          print ("ERROR: INDEX 00 > INDEX 01 on TRACK " d[walknt]["tnum"] (0+d[walknt]["tnum"]!=walknt ? " (i.e. " nt "th TRACK)" : "")) > "/dev/stderr"
          exit(2)
        }

        if (walknt>1) {
          if (msfts(d[walknt]["INDEX 00"]) <= msfts(d[walknt-1]["INDEX 01"])) {
            print ("ERROR: bogus INDEX 00 position specified on TRACK " d[walknt]["tnum"] (0+d[walknt]["tnum"]!=walknt ? " (i.e. " walknt "th TRACK)" : "")) > "/dev/stderr"
            exit(2)
          }
          print (walknt-1 ".until " sprintf("%d",auntil[walknt-1]=msfts(d[walknt]["INDEX 00"])))
          if ((rskip[walknt]=msfts(d[walknt]["INDEX 01"]) - msfts(d[walknt]["INDEX 00"]))>44100*3)
            print ("NOTE: found " rskip[walknt]/44100 " secs pregap on TRACK " d[walknt]["tnum"] (0+d[walknt]["tnum"]!=walknt ? " (i.e. " walknt "th TRACK)" : "")) > "/dev/stderr"
        } else if ((hinthtoa=msfts(d[walknt]["INDEX 01"])) > 44100) {
          print ("NOTE: [HTOA] found " hinthtoa/44100 " secs pregap") > "/dev/stderr"
        }
      } else if (walknt>1) {
        if (msfts(d[walknt]["INDEX 01"]) <= msfts(d[walknt-1]["INDEX 01"])) {
          print ("ERROR: bogus INDEX 01 position specified on TRACK " d[walknt]["tnum"] (0+d[walknt]["tnum"]!=walknt ? " (i.e. " walknt "th TRACK)" : "")) > "/dev/stderr"
          exit(3)
        }
        print (walknt-1 ".until " sprintf("%d",auntil[walknt-1]=msfts(d[walknt]["INDEX 01"])))
      } else if (walknt==1 && askip[walknt]) {
        print ("WARN: missing INDEX 00 on first TRACK") > "/dev/stderr"
      }
      print (walknt ".skip " sprintf("%d",askip[walknt]=msfts(d[walknt]["INDEX 01"])))
    } else {
      print ("ERROR: missing INDEX 01 on TRACK " d[walknt]["tnum"] (0+d[walknt]["tnum"]!=walknt ? " (i.e. " walknt "th TRACK)" : "")) > "/dev/stderr"
      exit(4)
    }
  }
  for (k in tnum2nthtr) {
    ll=""
    if (length(tnum2nthtr[k])>1) {
      print ("WARN: there are " length(tnum2nthtr[k]) " TRACKs have a tnum of " k) > "/dev/stderr"
    }
    for (l in tnum2nthtr[k]) {
      ll=(ll (length(ll) ? "|" : "") tnum2nthtr[k][l])
    }
    print ("mat." k " " ll)
  }
  for (walknt=1;walknt<=nt;walknt++) {
    if (!(sprintf("%02d",walknt) in tnum2nthtr)) {
      print ("WARN: missing TRACK " sprintf("%02d",walknt)) > "/dev/stderr"
    }
    print (walknt ".tnum " d[walknt]["tnum"])
    if (walknt<nt)
      print (walknt ".plen " (0+auntil[walknt]-askip[walknt]))
    if (rskip[walknt])
      print (walknt ".pskip " (0+rskip[walknt]))
  }
  if ("REM DATE" in d["d"] && strtonum(normdatestr(d["d"]["REM DATE"])))
    print ("date " normdatestr(d["d"]["REM DATE"]))
  print ("tc " nt)
}
function normdatestr(l,  ll) {
  if (match(l,/^([0-9][0-9][0-9][0-9])($|[/.-])/,normdatestrmatches)) {
    ll=normdatestrmatches[1]
    if (length(normdatestrmatches[2]) && match(l,/^.....([0-9]+)($|[/.-])/,normdatestrmatches) && length(normdatestrmatches[1])<=2) {
      ll=(ll "-" sprintf("%02d",normdatestrmatches[1]))
      if (length(normdatestrmatches[2]) && match(l,/^.....[0-9]+[/.-]([0-9]+)$/,normdatestrmatches) && length(normdatestrmatches[1])<=2)
        ll=(ll "-" sprintf("%02d",normdatestrmatches[1]))
    }
    return ll
  } else
    return mkbool(0)
}
'
declare awkcueput='
function joinkey(m,n,  k, l) {
  n==0&&n=="" ? n="|" : 1
  for (k in m) {
    l=(l (l==0&&l=="" ? "" : n) k)
  }
  return l
}
function pd(k,  tr, pad) {
  if (k in d[tr==""&&tr==0 ? "d" : "t" tr]) {
    if (length(d[tr==""&&tr==0 ? "d" : "t" tr][k])) {
      printf "%s",(pad==""&&pad==0 ? "" : pad)
      switch (k) {
        case "REM DISCNUMBER" :
        case "REM TOTALDISCS" :
        case "REM DATE" :
          print k " " (tr==""&&tr==0 ? d["d"][k] : d["t" tr][k]);
          break;
        default :
          print k " \"" (tr==""&&tr==0 ? d["d"][k] : d["t" tr][k]) "\"" (k=="FILE" ? " WAVE" : "")
          break;
      }
    }
    if (tr==0&&tr=="")
      delete d["d"][k]
    else
      delete d["t" tr][k]
  }
}
/^[ \t]*(TRACK|ISRC|FLAGS|INDEX)/ {
  if (nt && ("t" nt) in d && length(d["t" nt])) {
    for (k in d["t" nt])
      pd(k, nt, matches[1])
  }
}
/^[ \t]*(TRACK|FILE)/ {
  if (!nt && "d" in d && length(d["d"])) {
    for (k in d["d"]) {
      if (/^[ \t]*FILE/ && k=="FILE")
        continue;
      pd(k)
    }
  }
}
/^[ \t]*TRACK/ {
  ++nt
  jtd[nt]=(("t" nt) in d && length(d["t" nt]) ? joinkey(d["t" nt]) : "")
  print
  next
}
nt&&/[^ \t]/ {
  if (length(jtd[nt]) && match($0,("^([ \t]*)((" jtd[nt] ")( |$)|)"),matches) && length(matches[3])) {
    m=matches[3]
    pd(m, nt, matches[1])
  } else
    print;
}
END {
  if (!nt || ("d" in d && length(d["d"]))) exit(1)
  if (nt && ("t" nt) in d && length(d["t" nt])) {
    for (k in d["t" nt])
      pd(k, nt, matches[1])
  }
}
BEGIN {
  jdd=("d" in d && length(d["d"]) ? joinkey(d["d"]) : "")
}
!nt&&/[^ \t]/ {
  if (length(jdd) && match($0,("^([ \t]*)((" jdd ")( |$)|)"),matches) && length(matches[3])) {
    m=matches[3]
    pd(m)
  } else
    print;
}
'

declare openkey2harmony='
BEGIN{
o2h["6m"]="Abm";
o2h["7m"]="Ebm";
o2h["8m"]="Bbm";
o2h["9m"]="Fm";
o2h["10m"]="Cm";
o2h["11m"]="Gm";                                                                        o2h["12m"]="Dm";                                                                        o2h["1m"]="Am";
o2h["2m"]="Em";
o2h["3m"]="Bm";
o2h["4m"]="F#m";
o2h["5m"]="Dbm";
o2h["6d"]="B";
o2h["7d"]="F#";
o2h["8d"]="D#";
o2h["9d"]="Ab";
o2h["10d"]="Eb";
o2h["11d"]="Bb";
o2h["12d"]="F";
o2h["1d"]="C";
o2h["2d"]="G";
o2h["3d"]="D";
o2h["4d"]="A";
o2h["5d"]="E";
}
$0 in o2h {print o2h[$0];}
'

function aubiotrack2bpm {
  awk 'NR > 1 {
            interval = $1 - prev
            if (interval > 0) {
                print interval
            }
        }
        { prev = $1 }' | sort -n | awk '
        { intervals[NR] = $1; count = NR }
        END {
            if (count > 0) {
                # Calculate median from sorted intervals
                if (count % 2 == 1) {
                    median_interval = intervals[int((count + 1) / 2)]
                } else {
                    median_interval = (intervals[count / 2] + intervals[count / 2 + 1]) / 2
                }

                bpm = 60 / median_interval
                printf "%.0f\n", bpm
            } else {
                print "0"
            }
        }'
}

function gainstdin {
  local ffmpeg=
  ffmpeg -xerror -err_detect explode -hide_banner -nostats ${1:+-f} $1 -i - -af "ebur128=peak=true:framelog=quiet" -f null - |& readeof ffmpeg
  local ffmpegs=(${(f)ffmpeg})
  local peak=${${${(M)ffmpegs[${ffmpegs[(i)[	 ]##True peak:]}+1]:#[   ]##Peak:[   ]##[-+0-9.]## dBFS}#*:}% *}
  local i=${${${(M)ffmpegs[${ffmpegs[(i)[	 ]##Integrated loudness:]}+1]:#[   ]##I:[   ]##[-+0-9.]## LUFS}#*:}% *}
  if (( ${#i} && ${#peak} )); then
  REPLAYGAIN_TRACK_GAIN="$(echo "scale=2; -18-(${i}/1)" | bc -l) dB"
  REPLAYGAIN_TRACK_PEAK="${${${$(echo "scale=6; e(l(10)*${peak}/20)" | bc -l)/#./0.}/#+./+0.}#-./-0.}"
  else
    REPLAYGAIN_TRACK_GAIN=
    REPLAYGAIN_TRACK_PEAK=
  fi
}

declare -A cuedump
declare -A tracktitledump

declare -A suriscms
suriscms=(
  'kf' 'kf.<1->.sf[0-9a-f](#c3)'
  'bangumi.subj.t' 'bgm.subj.t<1->'
  'tieba.p' 'tb.p<1->'
)
## https://picard-docs.musicbrainz.org/downloads/MusicBrainz_Picard_Tag_Map.html
declare -A vorbiscmt2itunes
vorbiscmt2itunes=(
  TITLE nam
  COMPOSER wrt
  ARTIST ART
  ALBUM alb
  ALBUMARTIST aART
  COMMENT cmt
  MUSICBRAINZ_ALBUMARTISTID 'MusicBrainz Album Id'
  MUSICBRAINZ_RELEASETRACKID 'MusicBrainz Release Track Id'
  BPM tmpo
  GENRE gen
)

declare -A commontags
commontags=(
  'albumartist:A' 'PERFORMER'
  'date:Y' 'REM DATE'
  'catalognumber:O' 'REM CATALOGNUMBER'
  'label:B' 'REM LABEL'
  'artist:p' 'PERFORMER'
  'title:n' 'TITLE'
  'lyricist:l' 'REM LYRICIST'
  'arranger:r' 'REM ARRANGER'
  'composer:c' 'REM COMPOSER'
  'comment:x' 'REM COMMENT'
  'songwriter:w' 'SONGWRITER'
  'vocalist:v' 'REM VOCALIST'
  'genre:g' 'REM GENRE'
)

## https://mutagen-specs.readthedocs.io/en/latest/id3/id3v1-genres.html
declare -a genres=(
  Soundtrack
  Anime
  JPop
  Classical
  Game
  Indie
  Doujin ## https://xiami-music-genre.readthedocs.io/zh-cn/latest/list.html#doujin
  'National Folk'
  'Audio Theatre'
  Other
)
declare -a exts=(wav flac tta ape tak wv)

declare NCMAPI=${${(M)NCMAPI:#http(s|)://?*}:-https://163api.qijieya.cn}

declare -A fmtstr
declare -A ostr
function .deps {
  fzf --version &>/dev/null
  aconv --version &>/dev/null
  ffprobe -version &>/dev/null
  ffmpeg -version &>/dev/null
  rw --help &>/dev/null
  bat --version &>/dev/null
  cueprint --version &>/dev/null
  cueconvert --version &>/dev/null
  xxhsum --version &>/dev/null
  fmtstr[tta]='tta ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f tta -i %f -bitexact -f wav -'
  fmtstr[ape]='ape ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f ape -i %f -bitexact -f wav -'
  fmtstr[tak]='tak ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -i %f -bitexact -f wav -'

  flac --version &>/dev/null
  ostr[flac]='flac -scV8 '

  if [[ -v commands[takc] ]]; then
    ostr[takc]='takc -e -p4e -wm0 -md5 -silent '
  fi

  if oggenc --help | grep -qse "aoTuV"; then
    ostr[aotuv]='oggenc -Qq5 -s .... '
  fi

  if [[ -v commands[fdkaac] ]]; then
    ostr[fdkaac]='fdkaac -m3 -G2 -S --no-timestamp '
  fi

  if [[ -v commands[exhale] ]] && [[ -v commands[mp4tagcli] ]]; then
    ostr[exhale]='ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -f s16le -ac 2 -ar 44100 -i - -f wav - | exhale '
  fi

  if [[ -v commands[qaac64] ]] && (( ${(@)argv[1,2][(I)qaac]} )) && qaac64 --check 2>&1 | grep -qsEe 'CoreAudioToolbox [0-9.]+'; then
    ostr[qaac]='sox -Dtraw -Lc2 -r44100 -b16 -e signed-integer - -twav - | qaac64 -sV64 --gapless-mode 2 '
  fi
}
function .uninorm {
  uconv -i -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' --remove-signature
}
function .msg {
  if [[ -t 1 ]]; then
    print -rPn -- '%B%F{green}==> %f'
    print -rn -- $1
    print -rP '%b'
  else
    print -r -- "==> $1"
  fi
}
function .msgl {
  if [[ -t 1 ]]; then
    print -rPn -- '%B%F{blue}  -> %f'
    print -rn -- $1
    print -rP '%b'
  else
    print -r -- "  -> $1"
  fi
}
function .warn {
  if [[ -t 2 ]]; then
    print -rPnu 2 -- '%B%F{yellow}==> %fWARNING: '
    print -rnu 2 -- $1
    print -rPu 2 '%b'
  else
    print -ru 2 -- "==> WARNING: $1"
  fi
}
function .err {
  if [[ -t 2 ]]; then
    print -rPnu 2 -- '%B%F{red}==> %fERROR: '
    print -rnu 2 -- $1
    print -rPu 2 '%b'
  else
    print -ru 2 -- "==> ERROR: $1"
  fi
}
function .fatal {
  if [[ -t 2 ]]; then
    print -rPnu 2 -- '%B%F{red}==> %fFATAL: '
    print -rnu 2 -- $1
    print -rPu 2 '%b'
  else
    print -ru 2 -- "==> FATAL: $1"
  fi
  return ${${(M)2:#<1->}:-1}
}

.deps "${(@)argv}"
trap - ZERR
.main "${(@)argv}"
return err
