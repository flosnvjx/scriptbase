#!/usr/bin/gawk -f

function ms2mmssfff(l,  m,n,o) {
    l=l/1000
    o=l%60
    m=(l-o)/60
    return sprintf(("%02d:" (o<10 ? "0" : "") "%.03f"),m,o)
}
/^\[[0-9]+,[1-9][0-9]*]/{
  #print "-- " gensub(/^\[([0-9]+),([1-9][0-9]*)].*/,"\\1",1)
  lbegin_ms[++nl]=gensub(/^\[([0-9]+),([1-9][0-9]*)].*/,"\\1",1)
  #print "++ " gensub(/^\[([0-9]+),([1-9][0-9]*)].*/,"\\2",1)
  ldurat_ms[nl]=gensub(/^\[([0-9]+),([1-9][0-9]*)].*/,"\\2",1)
  sub(/^\[[0-9]+,[1-9][0-9]*]/,"")
  gsub(/\([^()]+\)/,"")
  if (nl>1) {
    if (lbegin_ms[nl-1]+ldurat_ms[nl-1] == lbegin_ms[nl]) {
      print $0
    } else {
      print ""
      print ("[" ms2mmssfff(lbegin_ms[nl]) "]" $0)
    }
  } else {
    print ("[" ms2mmssfff(lbegin_ms[nl]) "]" $0)
  }
  printf "%s",("[" ms2mmssfff(lbegin_ms[nl]+ldurat_ms[nl]) "]")
  #match($0,/^(\(([0-9]+),([1-9][0-9]*),0\)[^()]*)+$/,wdm[nl])
  #print (lbegin_ms[nl] "-" (lbegin_ms[nl]+ldurat_ms[nl])),(wdm[nl][2] "-" (wdm[nl][2]+wdm[nl][3])),$0
}
