#!/usr/bin/env shorthandzsh

setopt typesettounset extendedglob errreturn pipefail
zmodload -Fa zsh/stat b:zstat
if (( DEBUG || debug )); then set -x; fi

function .usage {
  echo 'usage: eh2img [<coverImg>|"-"] ["-n"|"+n"] <archive> [<torrent>]...'
  return 'argv[1]'
}

function .main {
  (( $# )) || .usage 3
  local coverImg coverImgStream coverImgFormat

  if [[ "$1" == (-|?*.(#i)(jpg|png)) ]]; then
    coverImg=$1; shift
    (( $# )) || .usage 3
    case $coverImg in
      -)
        .readStream coverImgStream
        .optimImgStream coverImgStream coverImgFormat
        ;;
      *)
        readeof coverImgStream < $coverImg
        .optimPicStream coverImgStream coverImgFormat
        ;;
    esac
  fi
  (( $# )) || .usage 3
  local -i noLookupTorrent noCheckArchive
  local -a torrentCacheDirs=(/sdcard/Download/ $HOME/.local/share/qBittorrent/BT_backup/)
  local -a torrents torrentsinfo
  local archive
  while (( $# )); do
    case "${1}" in
      -n|+n)
        noLookupTorrent=${${${(M)1:#-n}:+1}:-0}
        shift
        continue ;;
      -f)
        noCheckArchive=1
        shift
        continue ;;
      ?*.torrent)
        (( $#archive )) || .usage 3
        test -f $1
        imdl torrent show -i $1
        if (( noCheckArchive )); then
          .note "skipping torrent verification"
        else
          imdl torrent verify -i $1 -c $archive
        fi
        torrents+=($1)
        torrentsinfo+=("$(imdl torrent show -j -i $1 | .remapTorrentsInfo)")
        shift
        continue ;;
      ?*.zip|?*.cbz|?*.rar)
        (( ! $#archive )) || .usage 3
        test -f $1

        if ! (( noCheckArchive )); then
          bsdtar tf $1 | grep -iqEe '.+\.(jpg|png)$' || .dropout "archive does not contain files with supported image format: $1"
        fi
        archive=$1
        shift

        if (( ! ${(@)argv[(I)?*.torrent]} )); then
          if [[ -f $archive.torrent ]]; then
            torrents+=($archive.torrent)
          elif (( !noCheckArchive )) && ((!noLookupTorrent)) && [[ $archive == ?*.zip ]]; then
            local -a archivets=() possiblematchedtorrentsts=() zstats=()
            builtin zstat -A zstats +mtime -- $archive
            archivets=($zstats)
            builtin zstat -A zstats +ctime -- $archive
            archivets+=($zstats)
            archivets=(${(@on)archivets})
            local -a possiblematchedtorrents=(${(@)^torrentCacheDirs}/*.torrent(.NOm))
            if (($#possiblematchedtorrents)); then
              builtin zstat -A possiblematchedtorrentsts +mtime -- $possiblematchedtorrents
              if (( ${(@)possiblematchedtorrentsts[(I)<-$((1+archivets[1]))>]} )); then
                possiblematchedtorrents=(${(@)possiblematchedtorrents[1,${(@)possiblematchedtorrentsts[(I)<-$((1+archivets[1]))>]}]})
                local walkpossiblematchedtorrent= possiblematchedtorrent=; for walkpossiblematchedtorrent in $possiblematchedtorrents; do
                  if imdl torrent show -j -- $walkpossiblematchedtorrent | myEnv=${archive##*/} jq -er 'if (.name==$ENV.myEnv) then halt else empty|halt_error end'; then
                    possiblematchedtorrent=$walkpossiblematchedtorrent
                    break
                  fi
                done
                if (($#possiblematchedtorrent)); then
                  if imdl torrent verify -i $possiblematchedtorrent -c $archive; then
                    imdl torrent show -i $possiblematchedtorrent
                    torrents+=($possiblematchedtorrent)
                    torrentsinfo+=("$(exec imdl torrent show -j -i $possiblematchedtorrent | .remapTorrentsInfo)")
                  else
                    .msg 'fallback. since lookup torrent failed to match: '$possiblematchedtorrent
                  fi
                fi
              fi
            fi
          fi
        fi
        continue ;;
      -h|-help) .usage;exit;;
      *)
        .dropout "unrecognized filename extension: $1"
        .usage 3;;
    esac
  done
  (( $#archive )) || .usage 3
  if (( ! $#torrents )); then
    .note 'no torrent specified for archive: '$archive
    if (( !noCheckArchive )); then
      bsdtar xOf $archive >/dev/null
    else
      .note "skipping archive integrity check"
    fi
  fi
  if [[ ! -v coverImgFormat ]]; then
    [[ -t 0 ]] || .fatal "not a terminal, unable to pick picture interactively within archive"
    if coverImg="${${(@M)$(bsdtar tf $archive | LC_ALL=C sort -V | gawk -v IGNORECASE=1 '/\.(jpeg|jpg|png|gif|webp|bmp|ico|ico|wbmp|heic|heif|avif)$/{if (/\.(jpg|png)$/) {print (sprintf("%d",++i) "\t" $0)} else {++i;print ("\t" $0)}}' | fzf --prompt="${${archive##*/}%.*}/" --layout=reverse-list):#[1-9][0-9]#	?*}/#[1-9][0-9]#	}" && (($#coverImg)); then
      printf '^%s$\0' ${${${${${${coverImg//\\/\\\\}//%\$/\\$}/#\^/\\^}//\[/\\\[}//\*/\\*}//\?/\\?} | bsdtar xqOf $archive --null -T /dev/stdin | .readStream coverImgStream
      .optimPicStream coverImgStream coverImgFormat
      coverImg="$coverImg@$archive"
    fi
  fi
  (($#coverImgFormat)) || .fatal "no picture ever specified"
  printf "==> archive: %s\n" $archive >&2
  printf ' -> coverImg: %s:%s\n' $coverImgFormat $coverImg >&2
  if (( $#torrents )); then
    printf ' -- torrent: %s\n' ${torrents} >&2
  fi
  local ao
  function {
    set -x
    local -Ua archivenfkcbasename{pref,suf,ti}
    local archivetestnfkc="${${${$(print -r -- ${${archive##*/}%.*} | uconv -x ":: NFKC; [[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] >; \u003C > ＜; \u003D > ＞; \u002A > ＊; \u003F > ？; \u002F > \u2571; \u005C > \u2572; \u007C > ｜")//  #/ }/# #}/% #}"
    local -a testarchivebasename=("${(f)$(print -r -- $archivetestnfkc | sed -Ee "s%^(\([^)]+\) *|)(\[[^]]+]) *([^ ].*)%\2\n\3%")}")
    if (($#testarchivebasename==2)); then
      archivenfkcbasenamepref+=(${testarchivebasename[1]})
      testarchivebasename=("${(f)$(print -r -- ${testarchivebasename[2]} | perl -pe 's%^([^ ].*?) *((?: *?\([^)][^)][^)]+\)| *?\[[^]]+])*) *$%$1\n$2%')}")
      archivenfkcbasenamesuf+=("${(f)$(print -r -- ${testarchivebasename[2]} | sed -Ee 's%] *\[%]\n[%g')}")
      archivenfkcbasenameti+=(${testarchivebasename[1]})
    elif (($#testarchivebasename==1)); then
      testarchivebasename=("${(f)$(print -r -- ${testarchivebasename[1]} | perl -pe 's%^([^ ].*?) *((?: *?\([^)][^)][^)]+\)| *?\[[^]]+])*) *$%$1\n$2%')}")
      if (($#testarchivebasename==2)); then
      archivenfkcbasenameti+=(${testarchivebasename[1]})
      archivenfkcbasenamesuf+=("${(f)$(print -r -- ${testarchivebasename[2]} | sed -Ee 's%] *\[%]\n[%g')}")
      else
        archivenfkcbasenameti+=(${testarchivebasename})
      fi
    else .fatal undefined.
    fi
    local -a testarchivebasenameco=($archivenfkcbasenamepref ${(j. + .)archivenfkcbasenameti} ${(j..)archivenfkcbasenamesuf})
    local edtestarchivebasename=${${(j. .)testarchivebasenameco}/ #\(オリジナル\)}
    vared -p "basename> " edtestarchivebasename
    ao=$edtestarchivebasename
  }

  local coverImgCommentStream
  function {
    local -a zstats bt
    builtin zstat -A zstats +size -- $archive
    if (( $#torrents )); then
      integer iwalktorrent; for ((iwalktorrent=1;iwalktorrent<=$#torrents;iwalktorrent++)); do
        bt+=(
          \{\"info\":${torrentsinfo[$iwalktorrent]},\"benc\":\"zstd+b64:$(zstd -4c -- ${torrents[$iwalktorrent]}|basenc --base64 -w0)\"\}
        )
      done
      ## convert jfif/exif to png, since jpg has 64kib segment length limit, preventing us to write comment
      if [[ $coverImgFormat == jpg ]]; then
        print -rn -- $coverImgStream | ffmpeg -hide_banner -loglevel error -xerror -f jpeg_pipe -i - -f apng - | pngquant --nofs --strip -s 2 256 - | readeof coverImgStream
        coverImgFormat=png
      fi
    fi
    ## do not write comment to jfif/exif
    if [[ $coverImgFormat == png ]]; then
      command jo -- -s fnm=$ao.${archive##*.} -n fsz=${zstats[1]} -s fck=xxh3:"$(xxh3sum --tag --binary - < $archive | sed -ne '/^XXH3 (stdin) = ................$/s%.* = %%p')" ${torrents[1]:+"fbt=["}${(j.,.)bt}${torrents[1]:+"]"} | jq -cj . | readeof coverImgCommentStream
      print -rn -- $coverImgStream | exiftool -PNG:Comment=$coverImgCommentStream - | readeof coverImgStream
    fi
  }
#  else
#    local archivetestnfkc="${${${$(print -r -- ${${archives[1]##*/}%.*} | uconv -x ":: NFKC; [[[:General_Category=Format:][:General_Category=Nonspacing_Mark:][:print=No:][:Cc:]] - [\u000A]] >; \u003C > ＜; \u003D > ＞; \u002A > ＊; \u003F > ？; \u002F > \u2571; \u005C > \u2572; \u007C > ｜")//  #/ }/# #}/% #}"
#    if vared -p "basename> " ${vikey:+-m} archivetestnfkc && [[ ${${archives[1]##*/}%.*} != $archivetestnfkc ]]; then
#      local ao=${${(M)archives[1]:#*/*}:+${archives[1]%/*}}${${(M)archives[1]:#*/*}:+/}$archivetestnfkc
#    else
#      local ao=${archives[1]%.*}
#    fi
  local coverImgStreamLength
  function {
    set -x
    setopt localoptions nomultibyte
    coverImgStreamLength=${#coverImgStream}
    printf -v ao '%s-0x%'${${torrents[1]:+X}:-x} $ao.${archive##*.}"${torrentsinfo[1]:+[$(print -r -- ${torrentsinfo[1]} | jq -r .btih | basenc --base16 -d | basenc --base64url)]}" $coverImgStreamLength
    while (($#ao + 1 + ${#coverImgFormat} > 255)); do
      .msg "filename exceeds $(($#ao + 1 + ${#coverImgFormat} - 255)) bytes: $ao.$coverImgFormat"
      vared -p "ao> " -h ao
    done
  }
    .msg 'now writing output: '$ao.$coverImgFormat
  {
    builtin print -rn -- $coverImgStream
    cat -- $archive
  } | tee -- $ao.$coverImgFormat >&-

  function {
    local aopreupload
    set -x
    .expndictsubst ao preUploadRenameKeyword aopreupload
    if [[ "$ao" != "$aopreupload" ]]; then
      mv -v "$ao.$coverImgFormat" "$aopreupload.$coverImgFormat"
    fi
  }
#  integer iwalkarchive=0
#  declare -A vcdiffStream
#  declare -A tmpzip
#  declare -A sha1sumTxtStream
#  if (($#archives==1)); then
#    if [[ ! -v torrentofarchive[${archives[1]}] ]]; then
#    {
#      print -rn -- $picStream
#      cat -- ${archives[1]}
#    } | tee -- $ao.$picFormat >&-
#    else
#    {
#      print -rn -- $picStream
#      7zz rn -tzip -sae -so -- ${archives[1]} "${(f)$(bsdtar tf ${archives[1]} | sed -ne "{p;s/^/[1]\/${torrentmetadata[${torrentofarchive[${archives[1]}]}]#*:}\//;p}")}"
#    } | tee -- ${ao%.*}.tmp >&-
#    sha1sumTxtStream[1]="${$(sha1sum -b -- ${archives[1]})%% *} *${torrentmetadata[${torrentofarchive[${archives[1]}]}]#*:}"
#    local -a btihs=()
#    while ! bsdtar xOf ${ao%.*}.tmp "^\[0].cpio" | bsdtar xOf - "^\[1]:reseed.vcdiff" | xdelta3 -S -A -n -d -s ${ao%.*}.tmp | sha1sum -b - | env -v myVar=${sha1sumTxtStream[1]%% *} gawk '{if ($1!=ENVIRON["myVar"]) {print > "/dev/stderr";exit 99}}'; do
#      echo $pipestatus .... 
#      btihs+=("$(print -r -- ${torrentmetadata[${torrentofarchive[1]}]%%:*}|basenc -d --base16|basenc --base64url)")
#      {
#        eh2pic:stdin2cpiomember "[1]:reseed.torrent" < ${torrentofarchive[${archives[1]}]}
#        print -r -- ${sha1sumTxtStream[1]} | eh2pic:stdin2cpiomember "[1]:reseed.sha1sum.txt"
#        xdelta3 -S -A -n -e -s ${ao%.*}.tmp < ${archives[1]} | eh2pic:stdin2cpiomember "[1]:reseed.vcdiff"
#        eh2pic:printtrailer
#      } | dd bs=64KiB conv=sync status=none iflag=fullblock | 7zz a -tzip -sae -mx=0 -si'[0].cpio' -- ${ao%.*}.tmp
#      read  'REPLY?uux:'
#      sha1sum -b  ${ao%.*}.tmp
#      read  'REPLY?uuz:'
#    done
#      mv -vT -- ${ao%.*}{.tmp,"[${(j:,:)btihs}].${ao##*.}.$picFormat"}
#    fi
#  else
#    exit 66
#  fi
}

function .readStream {
  [[ ! -t 0 ]] || .dropout "unable to read data stream into \$$1 since stdin is a tty"
  readeof $1
  (( ${(P)#1} )) || .dropout "no data is read into \$$1, this is unlikely be expected."
}

function .optimPicStream {
  local optimPicStreamResult=
  local -a optimPicStreamSupportedFormats=(png jpg)
  local -a optimPicStreamPossibleFormats=("${(@s@/@)$(print -rn -- "${(P)1}" | file --brief --extension -)}")
  local -a optimPicStreamTestFormats=(${optimPicStreamSupportedFormats:*optimPicStreamPossibleFormats})
  if (($#optimPicStreamTestFormats == 1)); then case $optimPicStreamTestFormats in
    (png) print -rn -- "${(P)1}" | pngtopnm | pnmtopng -compr 9 -comp_mem_l 9 | readeof optimPicStreamResult ;;
    (jpg) print -rn -- "${(P)1}" | jpegoptim --stdin --stdout | readeof optimPicStreamResult ;;
    esac
    if (( $#optimPicStreamResult )) && (( $#optimPicStreamResult<${(P)#1} )); then
      : ${(P)1::=$optimPicStreamResult}
    fi
    : ${(P)2::=$optimPicStreamTestFormats}
  else
    .dropout "unable to detect format of picStream"
  fi
}

declare -a preUploadRenameKeyword
preUploadRenameKeyword=(
  '[無无](修(正|)|[码碼])(版|)' 'nonmo\$aicism'
  '去[码碼](版|)' 'demo\$aiced'
  'セックス' 'セ＠クス'
  '中出し' '中＠し'
  '性感' '＠感'
  '性欲' '＠欲'
  'エロ' 'エ＠'
  '露出' '露＠'
  'パパ活' 'パ＠活'
)
function .expndictsubst {
  if [[ "${(Pt)2}" == *array* ]] && (( "${(P)#2}" )) && [[ -v "${1}" ]]; then
    local expn=$1 dict=$2 tst=$3
    local evalparamsubst='${'$expn'}'
    argv=(${(P@)dict})
    while ((#)); do
      evalparamsubst='${'$evalparamsubst"//$1/$2}"
      shift 2
    done
    eval 'builtin printf -v ${tst:-$expn} %s' \""$evalparamsubst"\"
  fi
}

function eh2pic:stdin2cpiomember {
  setopt localoptions nomultibyte nocbases
  local bufstdin pathname=${1:--}
  eh2pic:readStream bufstdin
  builtin printf '%s%012o%06o%06o%06o%06o%06o%011o%06o%011o%s\0' 070707 1 $((8#100644)) 0 0 1 0 0 $((1+$#pathname)) $#bufstdin $pathname
  print -rn -- "$bufstdin"
}
function eh2pic:printtrailer {
  builtin printf '%s%012o%06o%06o%06o%06o%06o%011o%06o%011o%s\0' 070707 1 61440 0 0 1 0 0 11 0 "TRAILER!!!"
}
function .fatal {
  .dropout "FATAL: $1"
  return 1
}
function .remapTorrentsInfo {
  jq -ec '{name:.name,btih:.info_hash,contentLength:.content_size,pieceLength:.piece_size,timestamp:.creation_date,tracker:.tracker,comment:.comment,files:(if ((.files|length)>1) then .files else null end)}|map_values(. // empty)'
}
function .note {
  .dropout "NOTE: $1"
}
function .msg {
  .dropout " -> $1"
}
function .dropout {
  0=$?
  print -r -- $1 >&2
  return $0
}

.main "${(@)argv}"
exit $?
