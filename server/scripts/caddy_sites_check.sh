#!/usr/bin/env bash
# Status 203 — the Caddyfile must load with the neighbour-sites folder empty
# and with an example site in it, and reject a broken one. Runs `caddy
# validate` in the built caddy-l4 image (CI `docker-image` job; locally after
# `docker compose -f docker-compose.yml build caddy`).
#
#   cd server && scripts/caddy_sites_check.sh [image]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${1:-$(sed -n 's/^    image: \(sinhron\/caddy-l4:.*\)$/\1/p' docker-compose.yml)}
[[ -n $IMAGE ]] || { echo "[caddy-sites] no caddy image in docker-compose.yml" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/empty" "$WORK/example" "$WORK/broken"
cat >"$WORK/example/datascratch.caddy" <<'EOF'
notes.example.com {
	reverse_proxy datascratch-web:3000
}
EOF
printf 'notes.example.com {\n\tnot_a_directive\n}\n' >"$WORK/broken/broken.caddy"
chmod -R a+rX "$WORK"

validate() {
  docker run --rm \
    -e SINHRON_PUBLIC_HOSTNAME=chat.example.com -e SINHRON_LIVEKIT_HOSTNAME=livekit.chat.example.com \
    -e SINHRON_TURN_HOSTNAME=turn.chat.example.com -e SINHRON_NTFY_HOSTNAME=push.chat.example.com \
    -e ACME_EMAIL=certs@chat.example.com -e TURN_TCP_UPSTREAM=host.docker.internal:3478 \
    -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$WORK/$1:/etc/caddy/sites:ro" \
    "$IMAGE" caddy validate --config /etc/caddy/Caddyfile >"$WORK/$1.log" 2>&1
}

fail=0
for case in empty example; do
  if validate "$case"; then echo "[caddy-sites] ok: valid with the $case folder"; else
    echo "[caddy-sites] FAIL: invalid with the $case folder" >&2; tail -5 "$WORK/$case.log" >&2; fail=1
  fi
done
if validate broken; then echo "[caddy-sites] FAIL: a broken site file passed validation" >&2; fail=1; else
  echo "[caddy-sites] ok: a broken site file is rejected"
fi
exit "$fail"
