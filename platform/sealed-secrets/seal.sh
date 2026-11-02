#!/bin/bash
# Seal plaintext Secret manifest(s) into SealedSecrets, written next to the input
# with "-sealed" appended to the file name:
#
#   platform/sealed-secrets/seal.sh applications/qbittorrent/pia-credentials.yaml
#   ->
#
# The plaintext file lives in the app dir but is git-ignored (see .gitignore —
# this script refuses to seal a file git would track) and is NOT listed in the
# kustomization; the -sealed.yaml output is what gets committed and listed. Each
# plaintext Secret must set metadata.namespace: the ciphertext is bound to it, so
# leaving it out would seal against kubeseal's default namespace and never unseal.
# Annotations (e.g. sealedsecrets.bitnami.com/patch) are carried through.
#
# Seals against the committed public cert (platform/sealed-secrets/pub-cert.pem) so it
# works offline; --fetch refreshes that cert from the live controller first (once
# after install, and after any key rotation). Requires kubeseal + mikefarah/yq
# (both installed by install.sh).
#
#   platform/sealed-secrets/seal.sh [--fetch] <secret.yaml>...
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
