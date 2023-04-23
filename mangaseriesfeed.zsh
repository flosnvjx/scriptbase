#!/usr/bin/env shorthandzsh
alias furl='command curl -qgsf --compressed'
alias fie='furl -A "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv 11.0) like Gecko"'
alias fios='furl -A "Mozilla/5.0 (iPhone; CPU iPhone OS 14_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 EdgiOS/46.3.7 Mobile/15E148 Safari/605.1.15"'
builtin zmodload -Fa zsh/datetime p:EPOCHSECONDS b:strftime

function main {
  case "$1" in
    (s|sync|syncdb)
      shift; syncdb "${(@)argv}" ;;
    (u|update|update-queued)
      shift; update-queued "${(@)argv}" ;;
    (us)
      shift
      syncdb "${(@)argv}"
      update-queued "${(@)argv}"
      ;;
    (f|fetch-complement)
      shift; fetch-complement "${(@)argv}" ;;
    (g|get)
      shift; get "${(@)argv}" ;;
    (q|query)
      shift; query "${(@)argv}" ;;
    (rss|generate-atomxml)
      shift; generate-xml "${(@)argv}" ;;
    (uss)
      shift
      syncdb "${(@)argv}"
      update-queued "${(@)argv}"
      generate-xml "${(@)argv}"
      ;;
    (*)
      functions main
      exit 128 ;;
  esac
}

main "${(@)argv}"
