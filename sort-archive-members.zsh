#!/usr/bin/env shorthandzsh
set -e
builtin zmodload -Fa zsh/zutil b:zparseopts

usage() {
  printj "usage: ${ZSH_ARGZERO##*/} [flags] archives...

flags:
  -todir DIR, write to DIR instead of source archive directory
  -x LEVEL, default to 0, zip comp level int 0 <= LEVEL <= 9
  -p (TO BE IMPL) prefixing member name in output
  -f, do not detect if archive is correctly sorted, always write sorted archive
  -rm, rm source archive after successful sorting
"
}

main() {
  local -A getopts
  local +x -i complevel=
  local +x prefix=
  local +x -i exit=
  builtin zparseopts -A getopts -D -F - todir: x: p f rm
  if [[ -v getopts[-x] ]]; then
    complevel=$(( getopts[-x] ))
  fi
  if [[ -v getopts[-todir] ]]; then
    [[ -d "${getopts[-todir]}" ]]
  fi
  if [[ -v getopts[-x] ]]; then
    complevel=${getopts[-x]}
    (( complevel >= 0 )) && (( complevel <= 9 )) || return 128
  fi

  if [[ $# -eq 0 ]]; then
    usage
    return 128
  fi
  while [[ $# -gt 0 ]]; do
    local +x if=$1
    [[ -r "$if" ]] || {
      printf '[E] read failure: `%q`\n' $if >&2
      exit=1
      shift
      continue
    }
    local +x of=${if%.*}.cbz
    if [[ -v getopts[-todir] ]]; then
      of=${getopts[-todir]}/${of##*/}
    fi

    local -a if_members=()
    local -a of_members=()
    local +x if_tf=

    command bsdtar -cf - --format mtree --options mtree:!all,type,size @$if | sed -nEe '/^\.\/.+ type=file/s%^\./([^ ]+) type=file size=([0-9]+)$%\2:\1%p' | readarray if_members && let '#if_members > 1' && \
    command bsdtar -tf $if | readeof if_tf || {
      printf '[E] broken: `%q`\n' $if >&2
      exit=2
      shift
      continue
    }
    if_members=(${(@Q)if_members})
    printf '%s\0' ${(@)if_members} | LC_ALL=C sort -zV -t : -k 2 | readarray -t '\0' of_members
    (( ${#if_members} == ${#of_members} )) || return 3
    if [[ ! -v getopts[-f] ]]; then
      ## if_tf is unsorted, while if_members is sorted by mtree writer, since we use -V for sorting (diff than mtree writer), it will produce unexpected result if we use mtree output for comparison.
      if printf %s $if_tf | cmp -s - <(printf %s $if_tf | LC_ALL=C sort -V); then
        printf '[I] skip already sorted: `%q`\n' $if
        shift
        continue
      fi
    fi

    local +x -i availmem=
    command grep -i '^memfree:' /proc/meminfo | command awk '{ print $2 }' | builtin read -r availmem
    availmem=$(( availmem * 1024 ))
    builtin zmodload -Fa zsh/stat b:zstat
    local -a if_fsize=()
    builtin zstat -A if_fsize +size -- $if
    if (( if_fsize[1] > availmem )); then
      local +x -i usetmpfile=1
    else
      local +x -i usetmpfile=0
    fi
    local +x trap_exit=
    function {
      local -x TZ=UTC
      builtin setopt localtraps
      trap '
        printf "[E] exception during sorting: %q\n" $if >&2
        if [[ $usetmpfile == 1 ]]; then
          command rm -- $of.tmp || :
        else
          command pkill -fxnP $$ "rw -- $of"
          local -a ffs=()
          if builtin zstat -A ffs +size -- $of && [[ "${ffs[1]}" == 0 ]]; then
            rm -- $of
          fi
        fi
        trap_exit=1
      ' ZERR
      {
      while (( ${#of_members} > 0 )); do
        printf %s 070707 000000 000000 100666 000000 000000 000001 000000
        printf %011o 315532800 ## epoch:1980-01-01
        local +x -i fnlen=
        function {
          builtin setopt localoptions
          builtin setopt nomultibyte
          fnlen=$(( ${#of_members[1]#*:} + 1 ))
        }
        printf %06o $fnlen
        printf %011o ${of_members[1]%%:*}
        printf '%s\0' ${of_members[1]#*:}
        printf '%s\0' ${${${${${of_members[1]#*:}//\\/\/}//\[/\\[}//\*/\\*}//\?/\\?} | command bsdtar -x --null -T /dev/fd/0 -f $if -O
        shift of_members
      done
        printf '0707070000000000000000000000000000000000010000000000000000000001300000000000TRAILER!!!\0'
      } | {
        if (( complevel > 0 )); then
          command bsdtar -cf - --format zip --options zip:compression-level=$complevel @-
        else
          command bsdtar -cf - --format zip --options zip:compression=store @-
        fi
      } | {
        if [[ $usetmpfile == 1 ]]; then
          > $of.tmp
          command mv -T -- $of.tmp $of
        else
          command rw -- $of
        fi
      }
      printf '[I] ok, written `%q`\n' $of
      trap - ZERR
      if [[ -v getopts[-rm] ]]; then
        local -a farr=()
        if {
          realpath -Pz -- $if $of | readarray -t '\0' farr
        }; then
          if [[ "${farr[1]}" != "${farr[2]}" ]] && [[ ${#farr[2]} -gt 0 ]]; then
            rm -v -- "${farr[1]}"
          fi
        fi
      fi
    }
    if [[ "$trap_exit" == 1 ]]; then
      return 1
    fi
    shift
  done
}

main "${(@)argv}"
