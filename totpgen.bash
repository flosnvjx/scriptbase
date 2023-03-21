#!/usr/bin/env bash
# pass otp - Password Store Extension (https://www.passwordstore.org/)
# Copyright (C) 2017 Tad Fisher
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.

set -o pipefail
unset IFS

die() {
	echo "$@" >&2
	exit 1
}

VERSION="1.1.1"
OATH=$(command -v oathtool)

## source:  https://gist.github.com/cdown/1163649
urlencode() {
  local l=${#1}
  for (( i = 0 ; i < l ; i++ )); do
    local c=${1:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) printf "%c" "$c";;
      ' ') printf + ;;
      *) printf '%%%.2X' "'$c"
    esac
  done
}

urldecode() {
  # urldecode <string>

  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

# Parse a Key URI per: https://github.com/google/google-authenticator/wiki/Key-Uri-Format
# Vars are consumed by caller
# shellcheck disable=SC2034
otp_parse_uri() {
  local uri="$1"

  uri="${uri//\`/%60}"
  uri="${uri//\"/%22}"

  local pattern='^otpauth:\/\/(totp|hotp)(\/(([^:?]+)?(:([^:?]*))?))?\?(.+)$'
  [[ "$uri" =~ $pattern ]] || die "Cannot parse OTP key URI: $uri"

  otp_uri=${BASH_REMATCH[0]}
  otp_type=${BASH_REMATCH[1]}
  otp_label=${BASH_REMATCH[3]}

  otp_accountname=$(urldecode "${BASH_REMATCH[6]}")
  [[ -z $otp_accountname ]] && otp_accountname=$(urldecode "${BASH_REMATCH[4]}") || otp_issuer=$(urldecode "${BASH_REMATCH[4]}")
  [[ -z $otp_accountname ]] && die "Invalid key URI (missing accountname): $otp_uri"

  local p=${BASH_REMATCH[7]}
  local params
  local IFS=\&; read -r -a params < <(echo "$p") ; unset IFS

  pattern='^([^=]+)=(.+)$'
  for param in "${params[@]}"; do
    if [[ "$param" =~ $pattern ]]; then
      case ${BASH_REMATCH[1]} in
        secret) otp_secret=${BASH_REMATCH[2]} ;;
        digits) otp_digits=${BASH_REMATCH[2]} ;;
        algorithm) otp_algorithm=${BASH_REMATCH[2]} ;;
        period) otp_period=${BASH_REMATCH[2]} ;;
        counter) otp_counter=${BASH_REMATCH[2]} ;;
        issuer) otp_issuer=$(urldecode "${BASH_REMATCH[2]}") ;;
        *) ;;
      esac
    fi
  done

  [[ -z "$otp_secret" ]] && die "Invalid key URI (missing secret): $otp_uri"

  pattern='^[0-9]+$'
  [[ "$otp_type" == 'hotp' ]] && [[ ! "$otp_counter" =~ $pattern ]] && die "Invalid key URI (missing counter): $otp_uri"
}

cmd_otp_code() {
  [[ -z "$OATH" ]] && die "oathtool is not installed."

  [[ $# -gt 0 ]] && die "usage: ... | totpgen [check]"
  [[ -t 0 ]] && die "OTP URI shall not be read from the terminal."

  while read -r -a line; do
    if [[ "$line" == otpauth://* ]]; then
      otp_parse_uri "$line"
      break
    fi
  done

  local cmd
  case "$otp_type" in
    totp)
      cmd="$OATH -b --totp"
      [[ -n "$otp_algorithm" ]] && cmd+=$(echo "=${otp_algorithm}"|tr "[:upper:]" "[:lower:]")
      [[ -n "$otp_period" ]] && cmd+=" --time-step-size=$otp_period"s
      [[ -n "$otp_digits" ]] && cmd+=" --digits=$otp_digits"
      ;;

    *)
      die "OTP secret not found."
      ;;
  esac

  if [[ $checkonly == 1 ]]; then
    printf '%s\n' "$otp_secret" | $cmd - >/dev/null || \
      die "Failure during validation of OTP URI."
    echo "account: $otp_accountname"
  else
    local out
    out=$(printf '%s\n' "$otp_secret" | $cmd -) || \
      die "Failure during generation of OTP code."

    echo "$out"
  fi
}

case "$1" in
  check|test|c|t|validate)
    shift; checkonly=1 cmd_otp_code "$@" ;;
  get|generate-pin-code|generate-pin|genpin|gen)
    shift; checkonly=0 cmd_otp_code "$@" ;;
  *)
    checkonly=0 cmd_otp_code "$@" ;;
esac
exit 0
