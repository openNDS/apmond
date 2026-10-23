# Reference signature helper for tests: sha256(secret|mac|timestamp|payload_hash)
sign() { printf '%s' "$1|$2|$3|$4" | busybox sha256sum | cut -c1-64; }
