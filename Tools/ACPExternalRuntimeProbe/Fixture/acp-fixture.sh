#!/bin/sh
# Safe ACP v1 fixture for the signed XPC probe. It performs no network I/O,
# never receives a prompt, and reports only whether the helper supplied a
# normal user home instead of a sandbox container home.
case "${HOME:-}" in
  /Users/*/Library/Containers/*/Data*) agent_name='ACP fixture (home=not-real-user)' ;;
  /Users/*) agent_name='ACP fixture (home=real-user)' ;;
  *) agent_name='ACP fixture (home=not-real-user)' ;;
esac

while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"name\":\"$agent_name\"},\"agentCapabilities\":{\"mcpCapabilities\":{\"http\":true}}}}"
      ;;
    *'"method":"session/new"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"probe-session"}}'
      ;;
    *)
      exit 64
      ;;
  esac
done
