#!/usr/bin/env shorthandzsh

## split cuesheets in cwd.
## $0 output_fmt output_encoder_add_param shnsplit_param

setopt extendedglob pipefail errreturn xtrace
function .main {
  local ofmt
  function {
    if (( $#1 && ${(@)${(@k)ostr}[(I)(#i)${(q)1}]} )); then
      ofmt=$1
    elif (( !$#1 )); then
      function {
        while ((#)); do if [[ -v ostr[$1] ]]; then
          ofmt=$1
          break
          fi
          shift
        done
      } aotuv fdk flac
    elif [[ "$1" != cue ]]; then
      .fatal "unsupported output fmt: $1"
    fi
  } "$1"

  local -a cuefiles=(**/?*.(#i)cue(.N))
  case $#cuefiles in
    0) return 44 ;;
    1) : ;;
    *) cuefiles=("${(@f)$(printf %s\\n $cuefiles | fzf -m --layout=reverse-list --prompt="Select cuesheets for later operations> ")}") || cuefiles=(**/?*.(#i)cue(.N))
       ;;
  esac
  local -a cuefilecodepages cuebuffers cue{file,discnumber,totaldiscs,filetitle}directives
  local -a albumtitles albumfiles discnumbers totaldiscs
  function {
    local walkcuefiles REPLY
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      cuefilecodepages+=('')
      local buf=
      if ! aconv < ${cuefiles[$walkcuefiles]} | cmp -s -- ${cuefiles[$walkcuefiles]} -; then
        aconv < ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
        printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        while ! read -q "REPLY?Is that okay? ${cuefilecodepages[-1]:+${cuefilecodepages[-1]} }(y/N)" < ${TTY:-/dev/tty}; do
          cuefilecodepages[-1]="${$(iconv -l | fzf --layout=reverse-list --prompt="Select a codepage> ")// *}"
          iconv -f ${cuefilecodepages[-1]} -t UTF-8 -- ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
          printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        done
        if (( ${#cuefilecodepages[-1]} )); then
          uconv -i -f ${cuefilecodepages[-1]} -x '\u000A\u000D > \u000A' --remove-signature < ${cuefiles[$walkcuefiles]} | readeof buf
        else
          aconv < ${cuefiles[$walkcuefiles]} | uconv -i -x '\u000A\u000D > \u000A' | readeof buf
        fi
      else
        uconv -i -x '\u000A\u000D > \u000A' < ${cuefiles[$walkcuefiles]} | readeof buf
      fi
      cuebuffers[$walkcuefiles]=$buf
      unset buf
      cuefiledirectives+=( "${${${${(@)${(@f)${${cuebuffers[$walkcuefiles]:#[ 	]#TRACK *}%%
[ 	]#TRACK *}}[(R)[ 	]#FILE "*" (WAVE|FLAC)]}#*\"}%\"*}:#*\"*}" )
      cuefiletitledirectives+=("${${${${(@)${(@f)${${cuebuffers[$walkcuefiles]:#[ 	]#TRACK *}%%
[ 	]#TRACK *}}[(R)[ 	]#TITLE "*"]}#*\"}%\"*}:#*\"*}")
      cuediscnumberdirectives+=("${${(@)${(@f)${${cuebuffers[$walkcuefiles]:#[ 	]#TRACK *}%%
[ 	]#TRACK *}}[(R)[ 	]#REM DISCNUMBER [1-9][0-9]#]}#[ 	]#REM DISCNUMBER }")
      cuetotaldiscsdirectives+=("${${(@)${(@f)${${cuebuffers[$walkcuefiles]:#[ 	]#TRACK *}%%
[ 	]#TRACK *}}[(R)[ 	]#REM TOTALDISCS [1-9][0-9]#]}#[ 	]#REM TOTALDISCS }")
    done
    exit
    (( $#cuefiledirectives == $#cuefiles )) || .fatal "specified $#cuefiles cue sheet(s), but found $#cuefiledirectives FILE directive(s)"
    (( $#cuefiledirectives == ${(@)#${(@u)cuefiledirectives}} )) || .fatal "multiple cue sheets referenced same audio file"
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
      local -a match=()
      case ${(@)#${(@u)cuefiletitledirectives}} in
        (0)
          albumtitles+=("${${${cuefiles[$walkcuefiles]%(#i).cue}%/[0-9A-Z]##[-0-9A-Z]##}##*/}")
            until (( ${#albumtitles[$walkcuefiles]} )); do vared -ehp 'album> ' "albumtitles[$walkcuefiles]"; done
          ;|
        (<1->)
          albumtitles[$walkcuefiles]=${cuefiletitledirectives[$walkcuefiles]/%( #[\[\(（<]|  #)(#i)Disc #(#b)(<1->)(#B)(#I)([\]\)）>]|)}
          if (( ${#albumtitles[$walkcuefiles]} && ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} > 1 )); then
            albumtitles[$walkcuefiles]=${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}
          else
            if (( ! ${#albumtitles[$walkcuefiles]} )); then
              albumtitles[$walkcuefiles]=${${${cuefiles[$walkcuefiles]%(#i).cue}%/[0-9A-Z]##[-0-9A-Z]##}##*/}
            fi
            while :; do vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
              if (( ${#albumtitles[$walkcuefiles]} )); then break; fi
            done
          fi
          ;|
        (<0->)
          totaldiscs[$walkcuefiles]=${cuetotaldiscsdirectives[$walkcuefiles]}
          if (( ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} > 1)); then
            if (( totaldiscs[walkcuefiles] < ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} )); then
              until (( totaldiscs[${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}] >= ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} )); do vared -ep 'dc!> ' "totaldiscs[${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}]"; done
            fi
            totaldiscs[$walkcuefiles]=${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}
          elif (( ! totaldiscs[walkcuefiles] )); then
            totaldiscs[$walkcuefiles]=$(( ${(@)#${(@M)cuefiletitledirectives:#${(q)albumtitles[$walkcuefiles]}*}} ? ${(@)#${(@M)cuefiletitledirectives:#${(q)albumtitles[$walkcuefiles]}*}} : $#cuefiles ))
            until vared -ep 'dc> ' "totaldiscs[$walkcuefiles]" && (( totaldiscs[walkcuefiles] > 0 )); do :; done
          fi

          : ${#match[1]:-${${cuefiles[$walkcuefiles]%(#i).cue}:#[^a-zA-Z](#i)Disc #(#b)(<1->)}}
          discnumbers[$walkcuefiles]=${cuediscnumberdirectives[$walkcuefiles]:-${match[1]}}
          if (( !${#discnumbers[$walkcuefiles]} )); then
            if (( totaldiscs[walkcuefiles] > 1 )); then
              discnumbers[$walkcuefiles]=${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}}
              until vared -ep 'dn> ' "discnumbers[$walkcuefiles]" && (( discnumbers[walkcuefiles] > 0 && discnumbers[walkcuefiles] <= totaldiscs[walkcuefiles] )); do :; done
            else
              discnumbers[$walkcuefiles]=1
            fi
          fi
          ;|
      esac
    done
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      local -a match=() mbegin=() mend=()
      .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
      : ${cuefiledirectives[$walkcuefiles]/%.(#b)([0-9a-zA-Z]##)}
      local ifmtstr= ifile=
      case "${match[1]}" in
        ((#i)(flac|wv|wav|tak|tta|ape))
          ifile=${cuefiledirectives[$walkcuefiles]}
          .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
          if ! [[ -f "${cuefiledirectives[$walkcuefiles]}" ]]; then
            function {
              argv=(${cuefiledirectives[$walkcuefiles]%.*}.(#i)(flac|wv|wav|tak|tta|ape)(.N))
              if ((#)); then
                ifile=$1
                .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]} -> $ifile. [NOTE: fallback])"
              fi
            }
          fi
        ;;
        (*)
          .fatal "unsupported extension specified in FILE directive: ${cuefiles[$walkcuefiles]} (\"${cuefiledirectives[$walkcuefiles]}\")"
        ;;
      esac
      case "${ifile##*.}" in
        ((#i)(tta|ape|tak))
          ifmtstr=${fmtstr[${fmtstr[(i)(#i)${ifile##*.}]}]}
          ;;
      esac
      if (( $#ofmt )); then
        shntool split ${ifmtstr:+-i} ${ifmtstr} -d /sdcard/Music/albums/${${albumtitles[$walkcuefiles]//\?/？}//\*/＊} -n "${${${(M)totaldiscs[$walkcuefiles]:#<2->}:+${discnumbers[$walkcuefiles]}#%02d}:-%d}" -t '%n.%t@%p' -f ${cuefiles[$walkcuefiles]} -o "${ostr[$ofmt]} $2 - ${${(M)ofmt:#opus}:+%f}" ${(s. .)3} -- $ifile
      else
        shntool split -DD ${ifmtstr:+-i} ${ifmtstr} -n "${${${(M)totaldiscs[$walkcuefiles]:#<2->}:+${discnumbers[$walkcuefiles]}#%02d}:-%d}" -t '%n.%t@%p' -f ${cuefiles[$walkcuefiles]} -o null -- $ifile
      fi
      albumfiles[$walkcuefiles]=$ifile
    done
  } "${(@)argv}"
}

declare -a exts=(wav flac tta ape tak wv)
declare -A fmtstr
declare -A ostr
function .deps {
  fzf --version &>/dev/null
  aconv --version &>/dev/null
  recode --version &>/dev/null
  dos2unix --version &>/dev/null
  rw --help &>/dev/null
  fmtstr[tta]='tta ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f tta -i %f -bitexact -f wav -'
  fmtstr[ape]='ape ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f ape -i %f -bitexact -f wav -'
  fmtstr[tak]='tak ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -i %f -bitexact -f wav -'

  flac --version &>/dev/null
  ostr[flac]='flac flac -sV8co %f'

  if fdkaac --version &>/dev/null; then
    ostr[fdk]='cust ext=m4a fdkaac -m 5 -w 20000 -G 2 -S --no-timestamp -o %f'
  fi
  if oggenc --help | grep -se "aoTuV"; then
    ostr[aotuv]='cust ext=ogg oggenc -Q -q 5 -s .... -o %f'
  fi
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

.deps
trap - ZERR
.main "${(@)argv}"
return err
