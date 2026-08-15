#!/usr/bin/env bash
# Fake ssh for the attention harness (CMUX_REMOTE_TMUX_SSH_FOR_TESTING).
#
# Executes the "remote" command LOCALLY so a real tmux server on this Mac
# stands in for a corp machine. SSH options are skipped (flags with values
# consume the next argument); the first non-option argument is the
# destination, everything after it is the remote command. ControlMaster,
# port forwards, and TTY flags are no-ops: locally everything already
# shares one filesystem, and the harness symlinks the "forwarded" agent
# socket to the app's real control socket.
set -euo pipefail

dest=""
cmd=()
expect_value=false
control_op=""
persistent_master=false
for arg in "$@"; do
  if [ ${#cmd[@]} -gt 0 ]; then
    cmd+=("$arg")
    continue
  fi
  if $expect_value; then
    expect_value=false
    continue
  fi
  case "$arg" in
    -O)
      # Mux control operations (check/forward/exit) always "succeed":
      # locally there is no mux, and the harness provides the forwarded
      # agent socket as a symlink.
      control_op="pending" ;;
    -o|-S|-E|-L|-R|-i|-F|-p|-l|-W) expect_value=true ;;
    -M) persistent_master=true ;;
    -*) ;;
    *)
      if [ "$control_op" = "pending" ]; then
        control_op="$arg"
        continue
      fi
      if [ -z "$dest" ]; then
        dest="$arg"
      else
        cmd+=("$arg")
      fi
      ;;
  esac
done

if [ -n "$control_op" ] && [ "$control_op" != "pending" ]; then
  exit 0
fi

if [ ${#cmd[@]} -eq 0 ]; then
  if $persistent_master; then
    # The opener: stay alive as the fake ControlMaster.
    exec sleep 1000000
  fi
  exec "${SHELL:-/bin/zsh}" -l
fi

# Route every `tmux` the "remote" command runs to the harness's dedicated
# server (-L), so the fake host cannot touch the user's default tmux. The
# remote command runs under a NON-login shell: a login shell would rebuild
# PATH from the profile and drop the wrapper (observed live: the bridge's
# env pins landed on the user's default tmux server).
shim_dir="/tmp/attn-harness-tmux-shim"
mkdir -p "$shim_dir"
real_tmux="$(command -v tmux)"
cat > "$shim_dir/tmux" <<WRAP
#!/usr/bin/env bash
exec "$real_tmux" -L cmux-attn-harness "\$@"
WRAP
chmod +x "$shim_dir/tmux"
export PATH="$shim_dir:$PATH"

# Control-mode attach needs a tty (the real flow forces one with `ssh
# -tt`; sshd allocates it remotely). `script` bridges the pipes to a
# local pty for exactly that case; plain one-shot commands keep pipes.
# The transport pre-quotes every remote token, so the flag arrives as
# literal '-CC' (quotes included) in the joined string.
case "${cmd[*]}" in
  *-CC*)
    exec script -q /dev/null /bin/sh -c "${cmd[*]}"
    ;;
esac

exec /bin/sh -c "${cmd[*]}"
