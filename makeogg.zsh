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
          ## perform unicode sanitize
          uconv -i -f ${cuefilecodepages[-1]} -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' --remove-signature < ${cuefiles[$walkcuefiles]} | readeof buf
        else
          aconv < ${cuefiles[$walkcuefiles]} | uconv -i -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' --remove-signature | readeof buf
        fi
      else
        uconv -i -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' < ${cuefiles[$walkcuefiles]} | readeof buf
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
    (( $#cuefiledirectives == $#cuefiles )) || .fatal "specified $#cuefiles cue sheet(s), but found $#cuefiledirectives FILE directive(s)"
    (( $#cuefiledirectives == ${(@)#${(@u)cuefiledirectives}} )) || .fatal "multiple cue sheets referenced same audio file"
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
      local -a match=()
      case ${(@)#${(@u)cuefiletitledirectives}} in
        (0)
          albumtitles+=("${${${cuefiles[$walkcuefiles]%(#i).cue}%/[0-9A-Z]##[-0-9A-Z]##}##*/}")
            until (( ${#albumtitles[$walkcuefiles]} )); do timeout 0.01 cat >/dev/null || :; vared -ehp 'album> ' "albumtitles[$walkcuefiles]"; done
          ;|
        (<1->)
          albumtitles[$walkcuefiles]=${cuefiletitledirectives[$walkcuefiles]/%( #[\[\(（<]|  #)(#i)Disc #(#b)(<1->)(#B)(#I)([\]\)）>]|)}
          if (( ${#albumtitles[$walkcuefiles]} && ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} > 1 )); then
            albumtitles[$walkcuefiles]=${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}
          else
            if (( ! ${#albumtitles[$walkcuefiles]} )); then
              albumtitles[$walkcuefiles]=${${${cuefiles[$walkcuefiles]%(#i).cue}%/[0-9A-Z]##[-0-9A-Z]##}##*/}
            fi
            while timeout 0.01 cat >/dev/null || :; do vared -ehp 'album> ' "albumtitles[$walkcuefiles]"
              if (( ${#albumtitles[$walkcuefiles]} )); then break; fi
            done
          fi
          ;|
        (<0->)
          totaldiscs[$walkcuefiles]=${cuetotaldiscsdirectives[$walkcuefiles]}
          if (( ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} > 1)); then
            if (( totaldiscs[walkcuefiles] < ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} )); then
              until [[ "${totaldiscs[walkcuefiles]}" == [0-9]## ]] && (( totaldiscs[${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}] >= ${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}} )); do timeout 0.01 cat >/dev/null || :; vared -ep 'dc!> ' "totaldiscs[${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}]"; done
            fi
            totaldiscs[$walkcuefiles]=${(@)albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}
          elif (( ! totaldiscs[walkcuefiles] )); then
            totaldiscs[$walkcuefiles]=$(( ${(@)#${(@M)cuefiletitledirectives:#${(q)albumtitles[$walkcuefiles]}*}} ? ${(@)#${(@M)cuefiletitledirectives:#${(q)albumtitles[$walkcuefiles]}*}} : $#cuefiles ))
            until vared -ep 'dc> ' "totaldiscs[$walkcuefiles]" && [[ "${totaldiscs[walkcuefiles]}" == [0-9]## ]] && (( totaldiscs[walkcuefiles] > 0 )); do timeout 0.01 cat >/dev/null || :; done
          fi

          : ${#match[1]:-${${cuefiles[$walkcuefiles]%(#i).cue}:#[^a-zA-Z](#i)Disc #(#b)(<1->)}}
          discnumbers[$walkcuefiles]=${cuediscnumberdirectives[$walkcuefiles]:-${match[1]}}
          if (( !${#discnumbers[$walkcuefiles]} )); then
            if (( totaldiscs[walkcuefiles] > 1 )); then
              discnumbers[$walkcuefiles]=${(@)#${(@M)albumtitles:#${(q)albumtitles[$walkcuefiles]}}}
              until vared -ep 'dn> ' "discnumbers[$walkcuefiles]" && (( discnumbers[walkcuefiles] > 0 && discnumbers[walkcuefiles] <= totaldiscs[walkcuefiles] )); do timeout 0.01 cat >/dev/null || :; done
            else
              discnumbers[$walkcuefiles]=1
            fi
          fi
          ;|
      esac
    done
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      local -a match=() mbegin=() mend=()
      .msg "${cuefiles[$walkcuefiles]} (\"${cuefiledirectives[$walkcuefiles]}\")"
      : ${cuefiledirectives[$walkcuefiles]/%.(#b)([0-9a-zA-Z]##)}
      local ifmtstr= ifile=
      case "${match[1]}" in
        ((#i)(flac|wav|tak|tta|ape))
          ifile=${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${cuefiledirectives[$walkcuefiles]}
          .msg "${cuefiles[$walkcuefiles]} (${cuefiledirectives[$walkcuefiles]})"
          if ! [[ -f "$ifile" ]]; then
            function {
              argv=({${${(M)cuefiles[$walkcuefiles]:#*/*}:+${cuefiles[$walkcuefiles]%/*}/}${cuefiledirectives[$walkcuefiles]%.*},${cuefiles[$walkcuefiles]:r}}.(#i)(flac|wav|tak|tta|ape)(.N))
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
      local awkcuedump='
      @include "shellquote"
      function Map(re, arr) {
        if (match($0,re,arr)) {
          print (shell_quote((nt==""&&nt==0 ? "d" : "t" nt ) ":" arr[1]) " " shell_quote(arr[2]));
          d[nt==""&&nt==0 ? "d" : "t" nt][arr[1]]=arr[2]
          return mkbool(1)
        } else
          return mkbool(0)
      }
      /^[\t ]*TRACK [0-9][0-9] (AUDIO|MODE1\/(2048|2352)|(CDI|MODE2)\/(2336|2352)|CDG) *$/{
        match($0,/^[\t ]*TRACK ([0-9][0-9]) ([^ "]+) *$/,rr)
        nt=(rr[1])
        nts[++cnt]=nt
        d["t" nt]["mode"]=rr[2]
        if (strtonum(gensub(/^0/,"","1",nt)) != cnt)
          print ("WARN: nonsequential cuesheet tracknum -- " cnt "th track, but tracknum is " nt) > "/dev/stderr"
        next
      }
      nt==""&&nt==0&&/[^\t ]/{
        if ((Map("^[\t ]*(REM [A-Z_]+) \"(.*)\" *$",m) || \
         Map("^[\t ]*(REM [A-Z_]+) ([^ \"\t]*) *$",m) || \
         Map("^[\t ]*(CATALOG|CDTEXTFILE|PERFORMER|TITLE|SONGWRITER) \"(.*)\" *$",m) || \
         Map("^[\t ]*(CATALOG) ([^ \"\t]*) *$",m) || \
         Map("^[\t ]*(FILE) \"(.*)\" *(BINARY|MOTOROLA|WAVE|FLAC|MP3) *$",m)))
          next;
        else {
          print ("FATAL: unrecognized directive form -- " shell_quote($0)) > "/dev/stderr"
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
          print ("FATAL: unrecognized directive form on track " nts[nt] " -- " shell_quote($0)) > "/dev/stderr"
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
        if (cnt==0) {
          print "FATAL: no track ever specified" > "/dev/stderr"
          exit(1);
        }
        for (walknts=1;walknts<=cnt;walknts++) {
        if (("t" nts[walknts]) in d) {
          if (d["t" nts[walknts]]["mode"] == "AUDIO") {
            if ("INDEX 01" in d["t" nts[walknts]]) {
              if ("INDEX 00" in d["t" nts[walknts]]) {
                if (msfts(d["t" nts[walknts]]["INDEX 00"]) > msfts(d["t" nts[walknts]]["INDEX 01"])) {
                  print ("ERROR: INDEX 00 > INDEX 01 (" (0+nts[walknts]!=walknts ? "on " walknts "th track, " : "") "tracknum: " nts[walknts] ")") > "/dev/stderr"
                  exit(2)
                }

                if (walknts>1) {
                  if (msfts(d["t" nts[walknts]]["INDEX 00"]) <= msfts(d["t" nts[walknts-1]]["INDEX 01"])) {
                    print ("ERROR: (INDEX 00) bogus position specified (" (0+nts[walknts]!=walknts ? "on " walknts "th track, " : "") "tracknum: " nts[walknts] ")") > "/dev/stderr"
                    exit(2)
                  }
                  print ("t" nts[walknts-1] ":until " sprintf("%d",msfts(d["t" nts[walknts]]["INDEX 00"])))
                  if (pregap=(msfts(d["t" nts[walknts]]["INDEX 01"]) - msfts(d["t" nts[walknts]]["INDEX 00"]))>44100*3)
                    print ("NOTE: skip " pregap/44100 " secs pregap on " walknts "th track (#" nts[walknts] ")") > "/dev/stderr"
                } else if (htoa=msfts(d["t" nts[walknts]]["INDEX 01"]) > 44100) {
                  print ("NOTE: [HTOA] skip " htoa/44100 " secs on " walknts "th track (#" nts[walknts] ")") > "/dev/stderr"
                }
              } else if (walknts>1) {
                if (msfts(d["t" nts[walknts]]["INDEX 01"]) <= msfts(d["t" nts[walknts-1]]["INDEX 01"])) {
                  print ("ERROR: (INDEX 01) bogus position specified (" (0+nts[walknts]!=walknts ? "on " walknts "th track, " : "") "tracknum: " nts[walknts] ")") > "/dev/stderr"
                  exit(3)
                }
                print ("t" nts[walknts-1] ":until " sprintf("%d",msfts(d["t" nts[walknts]]["INDEX 01"])))
              }
              print ("t" nts[walknts] ":skip " sprintf("%d",msfts(d["t" nts[walknts]]["INDEX 01"])))
            } else {
              print ("ERROR: missing required index marker 01 (" (0+nts[walknts]!=walknts ? "on " walknts "th track, " : "") "tracknum: " nts[walknts] ")") > "/dev/stderr"
              exit(4)
            }
          } else
              continue
        } else {
          print ("ERROR: missing track num." nts[walknts]) > "/dev/stderr"
          exit(4)
        }
        }
      }
      '
      gawk --debug -E <(print -rn -- $awkcuedump) <(print -rn -- ${cuebuffers[$walkcuefiles]})
      exit
      shntool split ${=ofmt:--P none} ${ifmtstr:+-i} ${ifmtstr} ${ofmt:+-d} ${ofmt:+/sdcard/Music/albums/${${albumtitles[$walkcuefiles]//\?/？}//\*/＊}} -n "${${${(M)totaldiscs[$walkcuefiles]:#<2->}:+$(( discnumbers[$walkcuefiles] ))#%02d}:-%d}" -t '%n.%t@%p' -f <(print -r -- ${cuebuffers[$walkcuefiles]}) -o ${${ofmt:+${ostr[$ofmt]} $2 - ${${(M)ofmt:#opus}:+%f}}:-null} ${(s. .)3} -- $ifile
      local mbufs=()
      local mbuf= \
      awkcueput='
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
        /^[ \t]*TRACK/ {
          if (!nt && "d" in d && length(d["d"])) {
            for (k in d["d"])
              pd(k)
          }
          if (nt && ("t" nt) in d && length(d["t" nt])) {
            for (k in d["t" nt])
              pd(k, nt, matches[1])
          }
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
      gawk -E <(print -r -- '
        BEGIN {
          d["d"]["FILE"]="'${albumfiles[$walkcuefiles]//\\/\\\\}'";
          d["d"]["TITLE"]="'${${albumtitles[$walkcuefiles]//\"/＂}//\\/\\\\}'";
          d["d"]["REM DISCNUMBER"]="'${${totaldiscs[$walkcuefiles]:#1}:+$(( discnumbers[$walkcuefiles] ))}'";
          d["d"]["REM TOTALDISCS"]="'$(( totaldiscs[$walkcuefiles] ))'";
        }
      '$awkcueput) <(print -rn -- ${cuebuffers[$walkcuefiles]}) | readeof mbuf
      print -rn -- ${mbuf} | delta --paging never <(print -rn -- ${cuebuffers[$walkcuefiles]}) - || :
      local REPLY=
      mbufs+=($mbuf)
      while :; do
        timeout 0.1 cat >/dev/null || :
        read -k1 "REPLY?${cuefiles[$walkcuefiles]:t} [y/e/d/p($((${#mbufs}-1)))/m/t/q] "
        case "$REPLY" in
          ([^\n]) echo
          ;|
          (y)
            if print -rn -- ${mbufs[-1]} | cueprint -i cue -d ":: %T" -t "%02n.%t"; then
              if ! print -rn -- ${mbufs[-1]} | cmp -s -- ${cuefiles[$walkcuefiles]}; then
                print -rn -- ${mbufs[-1]} | rw -- ${cuefiles[$walkcuefiles]}
              fi
              break
            else
              .err 'malformed cuesheet'
              continue
            fi
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
            vared -hp 'm:mbid> ' askmbid
            function {
              argv=(${(f)mbufs[-1]})
              if (( ${argv[(i)[ 	]#TRACK]} <= $# && ${argv[(i)[ 	]#TRACK]}>1 )); then argv=(${argv[1,$((${argv[(i)[ 	]#TRACK]}-1))]}); fi
              0=${${argv[(R)[ 	]#CATALOG ?(#c12,13)]}#[ 	]#CATALOG }
              if python ${ZSH_ARGZERO%/*}/external.deps/mbcue/mbcue.py ${0:+-b $0} -n ${discnumbers[$walkcuefiles]} ${${(M)askmbid:#(|https://musicbrainz.org/release/)[0-9a-f](#c8)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c12)(|/*)}:+-r ${${askmbid#https://musicbrainz.org/release/}%%/*}} <(print -rn -- ${mbufs[-1]}) | readeof mbuf && (( $#mbuf )); then
                if [[ ${mbufs[-1]} != $mbuf ]]; then
                  mbufs+=($mbuf)
                  print -rn -- ${mbufs[-1]} | delta --paging=never <(print -rn -- ${mbufs[-2]}) - || :
                fi
              else
                mbuf=${mbufs[-1]}
                continue
              fi
            }
          ;|
          (p)
            if (( $#mbufs>1 )); then
              print -rn -- ${mbufs[-1]} | delta --paging=never - <(print -rn -- ${mbufs[-2]}) || :
              shift -p mbufs
            fi
          ;|
          (t)
            while :;do
              local tagkey=
              local -aU tagtnums=()
              local tagvalue=
              read -k 1 "tagkey?${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} [${${(@j..)${(@k)commontags}#*:}:l}?q] "
              case "$tagkey" in
                ([^\n]) echo
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
                tagtnums=("${(f)$(cueprint -i cue -t "%n. %t\n" <<< "${mbufs[-1]%
}" | fzf --layout=reverse-list --prompt="${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).track:")%%.*}") || continue
              elif eval '[[ "$tagkey" = ['${(@j..)${(@M)${(@k)commontags#*:}:#[a-z]}:l}'] ]]'; then
                if IFS=" ,	" vared -ehp "${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).tracks:" tagtnums && (( ${(@)#${(@M)tagtnums:#[0-9]##(-[0-9]#|)}} )); then :
                  function {
                    argv=("${(f)$(cueprint -i cue -t "%n\n" <<< "${mbufs[-1]%
}")}") || continue
                    tagtnums=("${${${(@M)tagtnums:#*-*}/#/<}/%/>}" "${(@)tagtnums:#*-*}")
                    tagtnums=("${(@M)argv:#${(@)~${(@j.|.)tagtnums}}}")
                  }
                else continue
                fi
              elif eval '[[ "$tagkey" != ['${(@j..)${(@M)${(@k)commontags#*:}:#[A-Z]}:l}'] ]]'; then continue;
              fi
              if eval '[[ "$tagkey" = ['${(@j..)${(@M)${(@k)commontags#*:}:#[A-Za-z]}:l}'] ]]'; then
                vared -ehp "${${cuefiles[$walkcuefiles]:t}:0:${$(( ${WIDTH:-80}/2 ))%.*}} tag(${(@)${(@k)commontags}[(r)(#i)*:$tagkey]%:?}).value:" tagvalue || continue
              fi
              gawk -E <(print -r -- 'BEGIN { ' d\[\"${${${(M)tagkey:#[${(@j..)${(@M)${(@k)commontags#*:}:#[A-Z]}:l}]}:+d}:-t${^tagtnums}}\"\]\[\"${(@)commontags[${(@)${(@k)commontags}[(r)(#i)*:$tagkey]}]}\"\]=\"${${tagvalue//\\/\\\\}//\"/\\\"}\"\; ' };'$awkcueput) <(print -rn -- ${mbufs[-1]}) | readeof mbuf
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
  'vocalist:v' 'REM VOCALIST'
)
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
function .uninorm {
  uconv -i -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >; ' ' {' '} >;'
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
