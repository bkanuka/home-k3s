#!/bin/bash
# Seal plaintext Secret manifest(s) into SealedSecrets, written next to the input
# as <name>-sealed.yaml, using the committed pub-cert.pem (--fetch refreshes it
# from the live controller first). Requires kubeseal + mikefarah/yq.
#
#   platform/sealed-secrets/seal.sh [--fetch] <secret.yaml>...
#
# The input must be git-ignored and must set metadata.namespace (the ciphertext is
# bound to it). Input annotations land only in the SealedSecret's spec.template.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT="$DIR/pub-cert.pem"
CONTROLLER_NS=sealed-secrets
CONTROLLER_NAME=sealed-secrets-controller

die() { echo "ERROR: $*" >&2; exit 1; }

command -v kubeseal >/dev/null || die "kubeseal not found (install.sh installs it)."
yq --version 2>/dev/null | grep -q mikefarah \
    || die "mikefarah/yq v4 not found on PATH (install.sh installs it)."

if [ "${1:-}" = "--fetch" ]; then
    shift
    echo "==> Fetching public cert from the live controller..."
    kubeseal --controller-namespace "$CONTROLLER_NS" \
        --controller-name "$CONTROLLER_NAME" --fetch-cert > "$CERT"
fi
[ $# -ge 1 ] || die "usage: $0 [--fetch] <secret.yaml>..."
[ -s "$CERT" ] || die "$CERT missing/empty — run '$0 --fetch ...' against the cluster first."

for src in "$@"; do
    [ -f "$src" ] || die "$src: no such file."
    read -r kind name ns <<< "$(yq -r '[.kind // "-", .metadata.name // "-", .metadata.namespace // "-"] | join(" ")' "$src")"
    [ "$kind" = "Secret" ] || die "$src: kind is '$kind', expected Secret."
    [ "$name" != "-" ] && [ "$ns" != "-" ] \
        || die "$src: metadata.name and metadata.namespace are both required."
    git -C "$(dirname "$src")" check-ignore -q "$(basename "$src")" \
        || die "$src: is not git-ignored — rename it to match .gitignore (e.g. *secret*.yaml) so the plaintext can never be committed."

    out="${src%.*}-sealed.yaml"
    echo "==> $ns/$name: $src -> $out"
    # Write via a temp file so a kubeseal failure can't truncate the committed one.
    tmp="$(mktemp "$out.XXXXXX")"
    kubeseal --cert "$CERT" --format yaml < "$src" > "$tmp" || { rm -f "$tmp"; die "$src: kubeseal failed."; }
    mv "$tmp" "$out"

    kust="$(dirname "$src")/kustomization.yaml"
    if [ -f "$kust" ] && ! yq -e ".resources[] | select(. == \"$(basename "$out")\")" "$kust" >/dev/null 2>&1; then
        echo "    ⚠ $(basename "$out") is not listed under resources: in $kust"
    fi
done
