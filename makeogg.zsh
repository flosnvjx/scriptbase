#!/usr/bin/env shorthandzsh

## split cuesheets in cwd.
## $0 output_fmt output_encoder_add_param shnsplit_param

setopt extendedglob pipefail errreturn xtrace
function .main {
  local ofmt
  function {
    if (( $#1 && ${(@)${(@k)ostr}[(I)(#i)${(q)1}]} )); then
      ofmt=${ostr[$1]}
    elif (( !$#1 )); then
      function {
        while ((#)); do if [[ -v ostr[$1] ]]; then
          ofmt=$1
          break
          fi
          shift
        done
      } aotuv fdk flac
    else
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
  local -a cuefilecodepages cue{file,discnumber,totaldiscs,filetitle}directives
  local -a albumtitles discnumbers totaldiscs
  function {
    local walkcuefiles REPLY
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      cuefilecodepages+=('')
      if ! aconv < ${cuefiles[$walkcuefiles]} | cmp -s -- ${cuefiles[$walkcuefiles]} -; then
        aconv < ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
        printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        while ! read -q "REPLY?Is that okay? ${cuefilecodepages[-1]:+${cuefilecodepages[-1]} }(y/N)" < ${TTY:-/dev/tty}; do
          cuefilecodepages[-1]="${$(iconv -l | fzf --layout=reverse-list --prompt="Select a codepage> ")// *}"
          iconv -f ${cuefilecodepages[-1]} -t UTF-8 -- ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
          printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        done
        if (( ${#cuefilecodepages[-1]} )); then
          recode -t -- ${cuefilecodepages[-1]} ${cuefiles[$walkcuefiles]}
        else
          aconv < ${cuefiles[$walkcuefiles]} | rw -- ${cuefiles[$walkcuefiles]}
        fi
      fi
      dos2unix -- ${cuefiles[$walkcuefiles]}
      cuefiledirectives+=("$(awk '/^ *FILE "([^"]+)" (WAVE|FLAC|AIFF)$/&&++i{sub(/^[^"]+"/,"");sub(/".*$/,"");a[i]=$0}END{if (i!=1) {exit 5} else {print a[i]}}' < ${cuefiles[$walkcuefiles]})")
      cuefiletitledirectives+=("$(awk '/^ *FILE "([^"]+)" (WAVE|FLAC|AIFF)$/{++i}/^ *TITLE "[^"]+"$/&&!i{sub(/^[^"]+"/,"");sub(/".*$/,"");a=$0}END{if (length(a)) {print a}}' < ${cuefiles[$walkcuefiles]})")
      cuediscnumberdirectives+=("$(awk '/^ *FILE "([^"]+)" (WAVE|FLAC|AIFF)$/{++i}/^ *REM DISCNUMBER [1-9][0-9]*$/&&!i{sub(/^^ *REM DISCNUMBER /,"");a=$0}END{if (length(a)) {print a}}' < ${cuefiles[$walkcuefiles]})")
      cuetotaldiscsdirectives+=("$(awk '/^ *FILE "([^"]+)" (WAVE|FLAC|AIFF)$/{++i}/^ *REM TOTALDISCS [1-9][0-9]*$/&&!i{sub(/^^ *REM TOTALDISCS /,"");a=$0}END{if (length(a)) {print a}}' < ${cuefiles[$walkcuefiles]})")
    done
    (( $#cuefiledirectives == $#cuefiles )) || .fatal "provides $#cuefiles cue sheet(s), but found $#cuefiledirectives FILE directive(s)"
    (( $#cuefiledirectives == ${(@)#${(@u)cuefiledirectives}} )) || .fatal "multiple cue sheets referenced same audio file"
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
      local -a match=()
      case ${(@)#${(@u)cuefiletitledirectives}} in
        (0)
          albumtitles+=(${PWD##*/})
          vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
          ;|
        (<1->)
          albumtitles[$walkcuefiles]=${cuefiletitledirectives[$walkcuefiles]/%  #Disc(#b)(<1->)}
          if (( ${(@)#${(@u)cuefiletitledirectives/%  #Disc<1->}} == 1 )); then
            if (( walkcuefiles == 1 )); then
              vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
            else
              albumtitles[$walkcuefiles]=${albumtitles[1]}
            fi
          else
            vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
          fi
          ;|
        (<0->)
          if (( walkcuefiles == 1 )) || [[ ${albumtitles[$walkcuefiles]} != ${albumtitles[1]} ]]; then
            totaldiscs[$walkcuefiles]=${cuetotaldiscsdirectives[$walkcuefiles]}
            if (( ! totaldiscs[walkcuefiles] )); then
              totaldiscs[$walkcuefiles]=$#cuefiles
              until vared -ep 'dc> ' "totaldiscs[$walkcuefiles]" && (( totaldiscs[walkcuefiles] > 0 )); do :; done
            fi
          else
            totaldiscs[$walkcuefiles]=${totaldiscs[1]}
          fi

          discnumbers[$walkcuefiles]=${cuediscnumberdirectives[$walkcuefiles]:-${match[1]}}
          if (( !${#discnumbers[$walkcuefiles]} )); then
            if (( totaldiscs[walkcuefiles] > 1 )); then
              discnumbers[$walkcuefiles]=$(( walkcuefiles<=$#cuefiles ? walkcuefiles : $#cuefiles ))
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
      local ifile= ifmtstr=
      case "${match[1]}" in
        ((#i)(wav|flac|tta|ape|tak|wv))
          ifile=${cuefiledirectives[$walkcuefiles]}
          .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
        ;|
        ((#i)wav)
          if ! [[ -f "${cuefiledirectives[$walkcuefiles]}" ]]; then
            function {
              argv=(${cuefiledirectives[$walkcuefiles]%.*}.(#i)(flac|ape|tak|tta|wv)(.N))
              if ((#)); then
                ifile=$1
                .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]} -> $ifile. [NOTE: fallback])"
              fi
            }
          fi
        ;;
      esac
      case "${ifile##*.}" in
        ((#i)(tta|ape|tak))
          ifmtstr=${fmtstr[${fmtstr[(i)(#i)${ifile##*.}]}]}
          ;;
      esac
      shntool split ${ifmtstr:+-i} ${ifmtstr} -d /sdcard/Music/albums/${${albumtitles[$walkcuefiles]//\?/？}//\*/＊} -n ${${${(M)totaldiscs[$walkcuefiles]:#<2->}:+${discnumbers[$walkcuefiles]}#%02d}:-%d} -t '%n.%t@%p' -f ${cuefiles[$walkcuefiles]} -o "${ostr[$ofmt]} $2 -" ${(s. .)3} -- $ifile
    done
  }
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
  fmtstr[tta]='tta ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f tta -i %f -bitexact -t wav -'
  fmtstr[ape]='ape ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -f ape -i %f -bitexact -t wav -'
  fmtstr[tak]='tak ffmpeg -loglevel quiet -xerror -hide_banner -err_detect explode -i %f -bitexact -t wav -'

  flac --version &>/dev/null
  ostr[flac]='flac flac -sV8co %f'

  if fdkaac --version &>/dev/null; then
    ostr[fdk]='cust ext=m4a fdkaac -m 4 -w 20000 -G 2 -S --no-timestamp -o %f'
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
