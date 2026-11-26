#!/bin/zsh
set -eu

bridge="${0:A:h}/mcp/blockbook-mcp"
connection_code="$(/usr/bin/pbpaste)"
if [[ "$connection_code" == BB1:* ]]; then
  if print -r -- "$connection_code" | "$bridge" pair; then
    unset connection_code
  else
    unset connection_code
    "$bridge" pair
  fi
elif ! "$bridge" status >/dev/null 2>&1; then
  unset connection_code
  print 'On your iPad, open Goodest Notes, start an agent session and tap Copy connection code.'
  "$bridge" pair
fi

print 'Ready. Use Codex in a local ChatGPT Mac chat, or open Claude Desktop on this Mac.'
print 'Keep Goodest Notes open on the iPad while the agent works.'
