#!/usr/bin/env bash
# The deploy key of RunR's origin for one step of the language bot (.github/workflows/lang-test.yml),
# which reads RunR's next with it and never pushes there (the same script as BRF-Tech/runr's
# ci/deps/ssh-key.sh, whose dependency test bot pushes with it): the
# private key in PUSH_KEY (OpenSSH format, the secret GITLAB_RUNR_PUSH_KEY) and GitLab's host key
# line in KNOWN_HOSTS (the repository variable GITLAB_KNOWN_HOSTS) go to DIR/key and
# DIR/known_hosts (mode 0600, DIR 0700). The host key must be the one GitLab publishes for
# gitlab.com: its fingerprint is pinned here (DEPS_GITLAB_HOST_KEY_FINGERPRINT), so a changed
# variable cannot point the push at another host. Prints the GIT_SSH_COMMAND that uses exactly
# them: no other identity, no agent, only that host key (StrictHostKeyChecking=yes, never
# accept-new). Nothing of the key is printed; the workflow removes DIR in a step of its own that
# always runs.
#
#   GIT_SSH_COMMAND="$(bash ci/lang-ssh-key.sh DIR)"
#
# Needs ssh-keygen.
set -euo pipefail

# gitlab.com's ED25519 host key (docs.gitlab.com → SSH host keys fingerprints)
GITLAB_FINGERPRINT="${DEPS_GITLAB_HOST_KEY_FINGERPRINT:-SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8}"

dir="${1:?usage: ci/lang-ssh-key.sh DIR}"
if [ -z "${PUSH_KEY:-}" ] || [ -z "${KNOWN_HOSTS:-}" ]; then
  echo "the secret GITLAB_RUNR_PUSH_KEY and the variable GITLAB_KNOWN_HOSTS are not both set" >&2
  exit 1
fi
case "$PUSH_KEY" in
  *"-----BEGIN OPENSSH PRIVATE KEY-----"*) ;;
  *) echo "GITLAB_RUNR_PUSH_KEY is no private key in OpenSSH format" >&2; exit 1 ;;
esac

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
printf '%s\n' "$KNOWN_HOSTS" | sed '/^[[:space:]]*$/d' > "$dir/known_hosts"
# one host key line of gitlab.com, the one GitLab publishes
lines="$(wc -l < "$dir/known_hosts")"
host="$(awk '{ print $1 }' "$dir/known_hosts")"
fingerprint="$(ssh-keygen -l -E sha256 -f "$dir/known_hosts" 2>/dev/null | awk '{ print $2 }' || true)"
if [ "$lines" != 1 ] || [ "$host" != gitlab.com ] || [ "$fingerprint" != "$GITLAB_FINGERPRINT" ]; then
  rm -rf -- "$dir"
  echo "GITLAB_KNOWN_HOSTS is not the single line of gitlab.com's host key ${GITLAB_FINGERPRINT} (${lines} line(s), host ${host:-none}, fingerprint ${fingerprint:-unreadable})" >&2
  exit 1
fi
# a key file must end in a line end
printf '%s\n' "$PUSH_KEY" | sed -e '$!b' -e '/^$/d' > "$dir/key"
chmod 600 "$dir/key" "$dir/known_hosts"
printf 'ssh -i %s -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes -o BatchMode=yes\n' \
  "$dir/key" "$dir/known_hosts"
