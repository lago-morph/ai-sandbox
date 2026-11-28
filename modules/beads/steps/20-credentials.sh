# shellcheck shell=bash
# The DoltHub account and API token are available, and the Dolt credential key is stored in
# ai-sandbox, imported into ~/.dolt/creds, selected, and registered on DoltHub. Each comes from
# its environment variable first, then the secrets backend. See modules/beads/README.md.

# shellcheck source=../lib/beads.sh
source "$AI_SANDBOX_MODULE_DIR/lib/beads.sh"
KEY_PAGE=https://www.dolthub.com/settings/credentials
TOKEN_PAGE=https://www.dolthub.com/settings/tokens

# _key_id_for_secret: the key id of the stored key if ~/.dolt/creds has it (matched by public key).
_key_id_for_secret() {
  cred_get DOLT_CREDS_JWK dolthub-creds | python3 -c '
import glob, json, os, sys
x = json.loads(sys.stdin.read()).get("x")
root = os.environ.get("DOLT_ROOT_PATH", os.path.expanduser("~"))
for f in glob.glob(os.path.join(root, ".dolt", "creds", "*.jwk")):
    try:
        if json.load(open(f)).get("x") == x:
            print(os.path.basename(f)[:-4]); break
    except ValueError:
        pass'
}
_selected() { "$BEADS_DOLT" config --global --get user.creds 2>/dev/null; }
_registered() { timeout 60 "$BEADS_DOLT" creds check >/dev/null 2>&1; }
_pubkey_help() {
  info "register this public key on DoltHub ($KEY_PAGE: Public key, Description), then re-run setup:"
  "$BEADS_DOLT" creds ls -v 2>/dev/null | sed 's/^/     /' >&2
}

check() {
  secrets_init
  local ok=0 id
  cred_source DOLTHUB_ACCOUNT dolthub-account >/dev/null || { info "no DoltHub account (DOLTHUB_ACCOUNT or secret dolthub-account)"; ok=1; }
  cred_source DH_TOKEN dolthub >/dev/null || { info "no DoltHub API token (DH_TOKEN or secret dolthub)"; ok=1; }
  if ! cred_source DOLT_CREDS_JWK dolthub-creds >/dev/null; then
    info "no Dolt credential key (DOLT_CREDS_JWK or secret dolthub-creds)"; return 1
  fi
  id=$(_key_id_for_secret)
  [ -n "$id" ] || { info "the stored Dolt key isn't in ~/.dolt/creds"; return 1; }
  [ "$(_selected)" = "$id" ] || { info "dolt doesn't use the stored key (user.creds is '$(_selected)', the key is $id)"; ok=1; }
  [ $ok = 1 ] || _registered || { info "DoltHub doesn't accept the key (dolt creds check)"; ok=1; }
  return $ok
}

apply() {
  secrets_init
  local id sel f
  cred_source DOLTHUB_ACCOUNT dolthub-account >/dev/null ||
    die "store your DoltHub account name: ai-sandbox-secret set dolthub-account (or export DOLTHUB_ACCOUNT), then re-run setup"
  cred_source DH_TOKEN dolthub >/dev/null ||
    die "store a DoltHub API token ($TOKEN_PAGE): ai-sandbox-secret set dolthub (or export DH_TOKEN), then re-run setup"
  if ! cred_source DOLT_CREDS_JWK dolthub-creds >/dev/null; then
    sel=$(_selected)
    f=${DOLT_ROOT_PATH:-$HOME}/.dolt/creds/$sel.jwk
    if [ -n "$sel" ] && [ -f "$f" ]; then
      info "storing dolt's current key ($sel) as secret dolthub-creds"
    else
      info "creating a Dolt credential key"
      "$BEADS_DOLT" creds new >/dev/null
      sel=$(_selected); f=${DOLT_ROOT_PATH:-$HOME}/.dolt/creds/$sel.jwk
      [ -f "$f" ] || die "dolt creds new didn't leave a key in ~/.dolt/creds"
    fi
    secret_set dolthub-creds < "$f"
  fi
  id=$(_key_id_for_secret)
  if [ -z "$id" ]; then
    info "importing the stored Dolt key into ~/.dolt/creds"
    cred_get DOLT_CREDS_JWK dolthub-creds | "$BEADS_DOLT" creds import >/dev/null
    id=$(_key_id_for_secret)
    [ -n "$id" ] || die "dolt creds import didn't import the stored key"
  fi
  sel=$(_selected)
  if [ -n "$sel" ] && [ "$sel" != "$id" ]; then
    die "dolt is set to use key $sel, but ai-sandbox's key is $id; select it (dolt creds use $id) or store the other one, then re-run setup"
  fi
  [ "$sel" = "$id" ] || "$BEADS_DOLT" creds use "$id" >/dev/null
  _registered || { _pubkey_help; die "DoltHub doesn't accept the Dolt key yet (one-time registration above)"; }
}
