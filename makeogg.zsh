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
  local -a cuefilecodepages cuebuffers cue{file,discnumber,totaldiscs,filetitle,catno}directives
  local -a albumtitles albumfiles discnumbers totaldiscs catnos
  function {
    local walkcuefiles REPLY
    for ((walkcuefiles=1;walkcuefiles<=$#cuefiles;walkcuefiles++)); do
      cuefilecodepages+=('')
      local buf=
      if ! aconv < ${cuefiles[$walkcuefiles]} | cmp -s -- ${cuefiles[$walkcuefiles]} -; then
        aconv < ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
        printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        while :; do
          read -k1 "REPLY?Is that okay? ${cuefilecodepages[-1]:+${cuefilecodepages[-1]} }(y/N)" < ${TTY:-/dev/tty}
          case "$REPLY" in
            ([^\n]) echo ;|
            ([yY]) break ;;
          esac
          cuefilecodepages[-1]="${$(iconv -l | fzf --layout=reverse-list --prompt="Select a codepage> ")// *}"
          iconv -f ${cuefilecodepages[-1]} -t UTF-8 -- ${cuefiles[$walkcuefiles]} | sed -ne '/"/p'
          printf '-- %s\n' ${cuefiles[$walkcuefiles]}
        done
        if (( ${#cuefilecodepages[-1]} )); then
          ## perform unicode sanitize
          uconv -i -f ${cuefilecodepages[-1]} -x '\u000A\u000D > \u000A; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >;' --remove-signature < ${cuefiles[$walkcuefiles]} | readeof buf
        else
          aconv < ${cuefiles[$walkcuefiles]} | .uninorm | readeof buf
        fi
      else
        .uninorm < ${cuefiles[$walkcuefiles]} | readeof buf
      fi
      cuebuffers[$walkcuefiles]=$buf
      unset buf
      cuefiledirectives+=( "${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#FILE "*" (WAVE|FLAC) #]#*\"}%\"*}" )
      cuefiletitledirectives+=( "${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#TITLE "*" #]#*\"}%\"*}" )
      cuediscnumberdirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM DISCNUMBER [1-9][0-9]# #]#[ 	 ]#REM DISCNUMBER }% #}")
      cuetotaldiscsdirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM TOTALDISCS [1-9][0-9]# #]#[ 	 ]#REM TOTALDISCS }% #}")
      cuecatnodirectives+=("${${(@)${(@f)cuebuffers[$walkcuefiles]}[1,${(@)${(@f)cuebuffers[$walkcuefiles]}[(i)[ 	 ]#TRACK*]}-1][(R)[ 	 ]#REM CATALOGNUMBER ("[A-Z][-0-9A-Z](#c4,)"|[A-Z][-0-9A-Z](#c4,)) #]#[ 	 ]#REM CATALOGNUMBER (\"|)}%(\"|) #}")
    done
    (( $#cuefiledirectives == $#cuefiles )) || .fatal "specified $#cuefiles cue sheet(s), but found $#cuefiledirectives FILE directive(s)"
    (( $#cuefiledirectives == ${(@)#${(@u)cuefiledirectives}} )) || .fatal "multiple cue sheets referenced same FILE"
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

          catnos[$walkcuefiles]=${cuecatnodirectives[$walkcuefiles]}
          match=()
          : ${(M)${cuefiledirectives[$walkcuefiles]:t:r}:#(#b)([A-Z](#c3,5)-[A-Z](#c0,3)[0-9](#c1,5)[A-Z](#c0,3))}
          if (( !${#catnos[$walkcuefiles]} )); then
            if (( totaldiscs[walkcuefiles] > 1 )); then
              catnos[$walkcuefiles]=${${catnos[${albumtitles[(i)${(q)albumtitles[$walkcuefiles]}]}]}:-${match[1]}}
            fi
            while :;do
              timeout 0.01 cat > /dev/null||:
              vared -ehp 'pn> ' "catnos[$walkcuefiles]"
              if [[ "${catnos[$walkcuefiles]}" = ([-A-Z0-9]#|) ]]; then
                break
              fi
            done
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
      local awkcuedump='
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
            ll=(ll "-" normdatestrmatches[1])
            if (length(normdatestrmatches[2]) && match(l,/^.....[0-9]+[/.-]([0-9]+)$/,normdatestrmatches) && length(normdatestrmatches[1])<=2)
              ll=(ll "-" normdatestrmatches[1])
          }
          return ll
        } else
          return mkbool(0)
      }
      '
      #shntool split ${=ofmt:--P none} ${ifmtstr:+-i} ${ifmtstr} ${ofmt:+-d} ${ofmt:+/sdcard/Music/albums/${${albumtitles[$walkcuefiles]//\?/？}//\*/＊}} -n "${${${(M)totaldiscs[$walkcuefiles]:#<2->}:+$(( discnumbers[$walkcuefiles] ))#%02d}:-%d}" -t '%n.%t@%p' -f <(print -r -- ${cuebuffers[$walkcuefiles]}) -o ${${ofmt:+${ostr[$ofmt]} $2 - ${${(M)ofmt:#opus}:+%f}}:-null} ${(s. .)3} -- $ifile
      #if [[ "$ifmt" != wv ]]; then
      #  shntool split -P none ${ifmtstr:+-i} ${ifmtstr} -f <(print -r -- ${cuebuffers[$walkcuefiles]}) -o null ${(s. .)3} -- $ifile
      #fi
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
      gawk -E <(print -r -- '
        BEGIN {
          d["d"]["FILE"]="'${albumfiles[$walkcuefiles]//\\/\\\\}'";
          d["d"]["TITLE"]="'${${albumtitles[$walkcuefiles]//\"/＂}//\\/\\\\}'";
          d["d"]["REM DISCNUMBER"]="'${${totaldiscs[$walkcuefiles]:#1}:+$(( discnumbers[$walkcuefiles] ))}'";
          d["d"]["REM TOTALDISCS"]="'$(( totaldiscs[$walkcuefiles] ))'";
          d["d"]["REM CATALOGNUMBER"]="'${catnos[$walkcuefiles]}'";
        }
      '$awkcueput) <(print -rn -- ${cuebuffers[$walkcuefiles]}) | readeof mbuf
      print -rn -- ${mbuf} | delta --paging never <(print -rn -- ${cuebuffers[$walkcuefiles]}) - || :
      local REPLY=
      mbufs+=($mbuf)
      while :; do
        timeout 0.1 cat >/dev/null || :
        read -k1 "REPLY?${cuefiles[$walkcuefiles]:t} [y/p/e/d/u($((${#mbufs}-1)))/m/t/q] "
        case "$REPLY" in
          ([^\n]) echo
          ;|
          (y|p)
            if ! print -rn -- ${mbufs[-1]} | cueprint -i cue -d ":: %T\n" -t "%02n.%t\n"; then
              .err 'malformed cuesheet'
              continue
            fi
          ;|
          (y)
            if ! print -rn -- ${mbufs[-1]} | cmp -s -- ${cuefiles[$walkcuefiles]}; then
              print -rn -- ${mbufs[-1]} | rw -- ${cuefiles[$walkcuefiles]}
            fi
          ;|
          (y|[pP])
            if (( $#ofmt )); then
              cuedump=("${(@Q)${(@z)${(@f)$(gawk -E <(print -rn -- $awkcuedump) - <<< ${mbufs[-1]})}}}")
              local -A ffprobe
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
                  if [[ ! -d "/sdcard/Music/albums/${${${${cuedump[d.TITLE]:-
}/#./．}//\//／}:0:85}" ]]; then
                    mkdir -vp -- "/sdcard/Music/albums/${${${${cuedump[d.TITLE]:- }/#./．}//\//／}:0:85}"
                  fi
                ;;
                (*)
                .fatal 'unsupported fmt: '${format.format_name}
              esac
              local runenc rundec tn
              case "$ofmt" in
                (aotuv) runenc=$'oggenc\n-Qq5\n-s\n....\n' ;|
                (flac) runenc=$'flac\n-V8cs\n' ;|
                (aotuv|flac)
                runenc+='
--comment=TRACKNUMBER=${cuedump[$tn.tnum]/#0}
${${${cuedump[$tn.TITLE]/#[    ]#}/%[   ]#}:+--comment=TITLE=${${cuedump[$tn.TITLE]/#[    ]#}/%[   ]#}}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM COMPOSER]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM COMPOSER]:-${cuedump[d.SONGWRITER]}}}}}}/#[	 ]##}/%[	 ]##}:+--comment=COMPOSER=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM COMPOSER]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM COMPOSER]:-${cuedump[d.SONGWRITER]}}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM ARRANGER]:-${cuedump[d.REM ARRANGER]}}}}/#[	 ]##}/%[	 ]##}:+--comment=ARRANGER=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM ARRANGER]:-${cuedump[d.REM ARRANGER]}}}}/#[	 ]##}/%[	 ]##}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM LYRICIST]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM LYRICIST]:-${cuedump[d.SONGWRITER]}}}}}}/#[	 ]##}/%[	 ]##}:+--comment=LYRICIST=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.REM LYRICIST]:-${cuedump[$tn.SONGWRITER]:-${cuedump[d.REM LYRICIST]:-${cuedump[d.SONGWRITER]}}}}}}/#[	 ]##}/%[	 ]##}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.VOCALIST]:-${cuedump[d.VOCALIST]}}}}/#[	 ]##}/%[	 ]##}:+--comment=VOCALIST=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.VOCALIST]:-${cuedump[d.VOCALIST]}}}}/#[	 ]##}/%[	 ]##}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.PERFORMER]:-${cuedump[d.PERFORMER]}}}}/#[	 ]##}/%[	 ]##}:+--comment=ARTIST=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[$tn.PERFORMER]:-${cuedump[d.PERFORMER]}}}}/#[	 ]##}/%[	 ]##}
${${${${(s| / |)${(s|, |)${(s|、|)cuedump[d.PERFORMER]}}}//#[	 ]##}//%[	 ]##}:+--comment=ALBUMARTIST=}${^${${(s| / |)${(s|, |)${(s|、|)cuedump[d.PERFORMER]}}}/#[	 ]##}/%[	 ]##}
${cuedump[d.date]:+--comment=DATE=${cuedump[d.date]}}
${${${${(s| / |)${(s|×|)${(s|、|)cuedump[d.REM LABEL]}}}//#[	 ]##}//%[	 ]##}:+--comment=LABEL=}${^${${(s| / |)${(s|×|)${(s|、|)cuedump[d.REM LABEL]}}}/#[	 ]##}/%[	 ]##}
${${${${cuedump[$th.REM COMMENT]:-${cuedump[d.REM COMMENT]}}//#[	 ]#}//%[	 ]#}:+--comment=COMMENT=${${${cuedump[$th.REM COMMENT]:-${cuedump[d.REM COMMENT]}}/#[	 ]#}/%[	 ]#}}
${cuedump[d.REM CATALOGNUMBER]:+--comment=CATALOGNUMBER=${cuedump[d.REM CATALOGNUMBER]}}
${cuedump[$tn.ISRC]:+--comment=ISRC=${cuedump[$tn.ISRC]}}
${cuedump[d.REM DISCNUMBER]:+--comment=DISCNUMBER=${cuedump[d.REM DISCNUMBER]}}
${cuedump[d.REM TOTALDISCS]:+--comment=DISCTOTAL=${cuedump[d.REM TOTALDISCS]}}
--comment=TRACKTOTAL=${cuedump[tc]}
${cuedump[d.REM MUSICBRAINZ_ALBUMID]:+--comment=MUSICBRAINZ_ALBUMID=${cuedump[d.REM MUSICBRAINZ_ALBUMID]}}
${cuedump[$tn.REM MUSICBRAINZ_RELEASETRACKID]:+--comment=MUSICBRAINZ_RELEASETRACKID=${cuedump[$tn.REM MUSICBRAINZ_RELEASETRACKID]}}
${cuedump[$tn.REM REPLAYGAIN_TRACK_GAIN]:+--comment=REPLAYGAIN_TRACK_GAIN=${cuedump[$tn.REM REPLAYGAIN_TRACK_GAIN]}}
${cuedump[$tn.REM REPLAYPEAK_TRACK_PEAK]:+--comment=REPLAYPEAK_TRACK_PEAK=${cuedump[$tn.REM REPLAYPEAK_TRACK_PEAK]}}
${cuedump[d.REM REPLAYGAIN_ALBUM_GAIN]:+--comment=REPLAYGAIN_ALBUM_GAIN=${cuedump[d.REM REPLAYGAIN_ALBUM_GAIN]}}
${cuedump[d.REM REPLAYPEAK_ALBUM_PEAK]:+--comment=REPLAYPEAK_ALBUM_PEAK=${cuedump[d.REM REPLAYPEAK_ALBUM_PEAK]}}
'
                runenc+='--output=/sdcard/Music/albums/${${${${cuedump[d.TITLE]:- }/#./．}//\//／}:0:85}/${${:-${cuedump[d.REM DISCNUMBER]:+${cuedump[d.REM DISCNUMBER]}#}${cuedump[$tn.tnum]}${cuedump[$tn.TITLE]:+.${cuedump[$tn.TITLE]//\//／}}}:0:81}.ogg'
                runenc+=$'\n-'
                ;|
              esac
              case "${ffprobe[format.format_name]}" in
                (wv) wvunpack -qmvz0 -- $ifile
                rundec='wvunpack -q -z0 -o -'
                ;|
                (flac)
                rundec='flac -dcs'
                ;|
                (flac|wv)
                  for ((tn=1;tn<=cuedump[tc];tn++));do
                    command ${(s. .)rundec} ${${(M)cuedump[$tn.skip]:#<1->}:+--skip=${cuedump[$tn.skip]}} ${${(M)cuedump[$tn.until]:#<1->}:+--until=${cuedump[$1.until]}} -- $ifile | rw | eval command echo ${${(f)runenc}:#}
                    shift
                  done
                ;|
                (wav|tak|tta|ape)
                  command ffmpeg -loglevel warning -xerror -hide_banner -err_detect explode -i $ifile -f s16le - | {
                    for ((tn=1;tn<=cuedump[tc];tn++)); do
                      dd bs=128K ${${(M)cuedump[$tn.pskip]:#<1->}:+skip=${cuedump[$tn.pskip]}B} ${${(M)cuedump[$tn.plen]}:+count=${cuedump[$tn.plen]}B} iflag=fullblock status=none | eval command echo ${${(f)runenc}:#}
                    done
                  }
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
              0=${${argv[(R)[ 	]#CATALOG ?(#c12,13)]}#[ 	]#CATALOG }
              if python ${ZSH_ARGZERO%/*}/external.deps/mbcue/mbcue.py ${0:+-b $0} -n ${discnumbers[$walkcuefiles]} ${(z)${(M)askmbid:#(|https://musicbrainz.org/release/)[0-9a-f](#c8)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c12)(|/*)}:+-r ${${askmbid#https://musicbrainz.org/release/}%%/*}} <(print -rn -- ${mbufs[-1]}) | readeof mbuf && (( $#mbuf )); then
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
          (u)
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

declare -A cuedump
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
)
declare -a exts=(wav flac tta ape tak wv)
declare -A fmtstr
declare -A ostr
function .deps {
  fzf --version &>/dev/null
  aconv --version &>/dev/null
  ffprobe -version &>/dev/null
  ffmpeg -version &>/dev/null
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

.deps
trap - ZERR
.main "${(@)argv}"
return err
