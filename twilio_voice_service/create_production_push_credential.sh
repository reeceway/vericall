#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/apple_voip_production.cer" >&2
  exit 64
fi

cert_der="$1"
if [[ ! -f "$cert_der" ]]; then
  echo "Certificate not found: $cert_der" >&2
  exit 66
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="$repo_root/release/apple"
cert_pem="$release_dir/VicallVoIPProduction_com.vicall.app.pem"

openssl x509 -inform der -in "$cert_der" -out "$cert_pem"

cert_pubkey_hash="$(
  openssl x509 -in "$cert_pem" -pubkey -noout |
    openssl pkey -pubin -outform der 2>/dev/null |
    shasum -a 256 |
    awk '{print $1}'
)"

private_key=""
for candidate in "$release_dir/VicallVoIPProduction_com.vicall.app.key"; do
  [[ -f "$candidate" ]] || continue
  candidate_hash="$(
    openssl pkey -in "$candidate" -pubout -outform der 2>/dev/null |
      shasum -a 256 |
      awk '{print $1}'
  )"
  if [[ "$candidate_hash" == "$cert_pubkey_hash" ]]; then
    private_key="$candidate"
    break
  fi
done

if [[ -z "$private_key" ]]; then
  echo "No matching private key found for Apple certificate: $cert_der" >&2
  echo "Expected key: $release_dir/VicallVoIPProduction_com.vicall.app.key" >&2
  exit 66
fi

subject="$(openssl x509 -in "$cert_pem" -noout -subject)"
if [[ "$subject" != *"com.vicall.app"* ]]; then
  echo "Certificate subject does not look like the production Vicall App ID:" >&2
  echo "$subject" >&2
  exit 65
fi

sid="$(
  twilio api:chat:v2:credentials:create \
    --friendly-name "Vicall VoIP Production" \
    --type apn \
    --certificate "$(cat "$cert_pem")" \
    --private-key "$(cat "$private_key")" \
    --no-sandbox \
    --properties sid,friendlyName,type,sandbox \
    -o json |
  python3 -c 'import json,sys; data=json.load(sys.stdin); data=data[0] if isinstance(data, list) else data; print(data["sid"])'
)"

flyctl secrets set "TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION=$sid" -a vericall-twilio-voice

echo "Created Twilio production Push Credential and set Fly secret."
echo "SID: $sid"
