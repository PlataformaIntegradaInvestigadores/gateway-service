#!/usr/bin/env bash
# Functional check of the gateway: per-client rate limits, the real client address,
# the JSON 429 and unique group names in the aggregate health. Needs Docker.
#
#   bash tests/smoke.sh
set -u

IMAGE=gw-smoke-image
NET=gw-smoke-net
fail=0

cleanup() {
  docker rm -f gw-smoke-gateway gw-smoke-stub >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

check() { # description, ok(0/1)
  if [ "$2" = 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi
}

docker build -q -t "$IMAGE" . >/dev/null || { echo "build failed"; exit 1; }
docker run --rm "$IMAGE" nginx -t >/dev/null 2>&1; check "nginx -t" $?

docker network create "$NET" >/dev/null

# Stub backends: one container answering under every service name.
docker create --name gw-smoke-stub --network "$NET" \
  --network-alias identity-service --network-alias social-service \
  --network-alias search-service --network-alias search-bff-service \
  --network-alias predictive-service --network-alias rag-service \
  --network-alias governance-service --network-alias analytics-service \
  --network-alias ethical-recommender-service \
  --network-alias centinela-front nginx:1.27-alpine >/dev/null
docker cp tests/stub-upstream.conf gw-smoke-stub:/etc/nginx/conf.d/default.conf
docker start gw-smoke-stub >/dev/null

docker run -d --name gw-smoke-gateway --network "$NET" "$IMAGE" >/dev/null
sleep 3

# Run curl from a throwaway container on the same network (so the source address
# is a Docker bridge address, like the host nginx in production).
run() { docker run --rm --network "$NET" --entrypoint sh curlimages/curl:8.10.1 -c "$1"; }
G=http://gw-smoke-gateway

count() { # label  curl-args... ; prints "<200s> <429s>" over N sequential requests
  local n=$1 hdr=$2 method=$3 url=$4
  run "ok=0; limited=0; for i in \$(seq 1 $n); do c=\$(curl -s -o /dev/null -w '%{http_code}' -X $method -H 'X-Real-IP: $hdr' $url); [ \$c = 200 ] && ok=\$((ok+1)); [ \$c = 429 ] && limited=\$((limited+1)); done; echo \$ok \$limited"
}

echo "-- sign-in is limited per client address (30/min, burst 15)"
read ok limited < <(count 40 10.9.9.1 POST $G/api/identity/token/)
echo "     40 requests from 10.9.9.1 -> $ok ok, $limited limited"
[ "$ok" -ge 14 ] && [ "$ok" -le 20 ] && [ "$limited" -ge 20 ]; check "one client is throttled after its burst" $?

read ok limited < <(count 3 10.9.9.2 POST $G/api/identity/token/)
[ "$ok" = 3 ] && [ "$limited" = 0 ]; check "another client address has its own bucket" $?

read ok limited < <(count 40 10.9.9.1 GET $G/api/identity/users/)
[ "$ok" = 40 ]; check "other identity URLs are not subject to the sign-in limit" $?

read ok limited < <(count 40 10.9.9.7 POST $G/api/identity/token/refresh/)
[ "$ok" = 40 ]; check "token refresh (done by the front on its own) is not limited" $?

echo "-- /ask is limited (6/min, burst 3)"
read ok limited < <(count 10 10.9.9.3 POST $G/api/rag/ask)
echo "     10 requests -> $ok ok, $limited limited"
[ "$ok" -ge 3 ] && [ "$ok" -le 6 ] && [ "$limited" -ge 4 ]; check "RAG is throttled" $?

echo "-- general API limit (20/s, burst 100)"
read ok limited < <(count 60 10.9.9.4 GET $G/api/social/feeds/)
[ "$ok" = 60 ]; check "normal page-load traffic is not limited" $?

echo "-- 429 response"
limited_response=$(run "for i in \$(seq 1 25); do curl -s -o /dev/null -X POST -H 'X-Real-IP: 10.9.9.5' $G/api/identity/token/; done; curl -s -i -X POST -H 'X-Real-IP: 10.9.9.5' $G/api/identity/token/")
echo "$limited_response" | grep -q "429" && echo "$limited_response" | grep -qi "retry-after" && echo "$limited_response" | grep -q "Too many requests"; check "429 carries Retry-After and a JSON body" $?
echo "$limited_response" | grep -qi "application/json"; check "429 is application/json" $?

echo "-- rejections are logged with the zone"
docker logs gw-smoke-gateway 2>&1 | grep -q 'limiting requests, excess: .* by zone "auth", client: 10.9.9.1'; check "error log names the zone and the real client" $?
docker logs gw-smoke-gateway 2>&1 | grep -q 'by zone "heavy", client: 10.9.9.3'; check "error log also covers the RAG zone" $?

echo "-- the real client address is used"
docker logs gw-smoke-gateway 2>&1 | grep -q "^10.9.9.1 "; check "access log shows the X-Real-IP address, not the bridge" $?

echo "-- aggregate health"
HEALTH_CHECK='
import json, sys
d = json.load(sys.stdin)
names = [g["group_name"] for g in d["groups"]]
dupes = sorted({n for n in names if names.count(n) > 1})
print("     groups:", names)
ok = not dupes
print("  ok   " if ok else "  FAIL ", "group names are unique" + ("" if ok else f" (repeated: {dupes})"))
q = "Service runtime (governance-service)" in names and "Service runtime (analytics-service)" in names
q = q and "ethical-recommender-service" in names
print("  ok   " if q else "  FAIL ", "repeated names are qualified with the service")
sys.exit(0 if ok and q else 1)
'
run "curl -s $G/api/health" | python3 -c "$HEALTH_CHECK" || fail=1

run "ok=0; for i in \$(seq 1 60); do c=\$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Real-IP: 10.9.9.6' $G/api/health); [ \$c = 200 ] && ok=\$((ok+1)); done; echo \$ok" | grep -q "^60$"; check "health endpoints are never rate limited" $?

echo "-- Q&A goes through governance (S-Q20)"
# upstream METHOD PATH: prints "<code> <port> <uri>" as seen by the stub ("-" if none).
upstream() {
  run "curl -s --path-as-is -o /dev/null -D - -X $1 -H 'X-Real-IP: 10.9.9.8' -H 'Content-Type: application/json' -d '{}' '$G$2'" \
    | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-stub-upstream:"{p=$2; u=$3} END{print c, (p?p:"-"), (u?u:"-")}'
}
expect() { # description METHOD PATH "<code> <port> <uri>"
  got=$(upstream "$2" "$3")
  [ "$got" = "$4" ]; check "$1 ($got)" $?
}
expect "public Q&A POST reaches the governed route" POST \
  /api/search/v1/llm-search/generate-qa/ "200 8005 /api/v1/governed/qa/generate"
expect "query string does not bypass governance" POST \
  "/api/search/v1/llm-search/generate-qa/?format=json" "200 8005 /api/v1/governed/qa/generate?format=json"
expect "percent-encoded path is governed" POST \
  /api/search/v1/llm-search/generate%2Dqa/ "200 8005 /api/v1/governed/qa/generate"
expect "repeated slashes are governed" POST \
  /api/search/v1//llm-search//generate-qa/ "200 8005 /api/v1/governed/qa/generate"
expect "dot segments are governed" POST \
  /api/search/v1/llm-search/./generate-qa/ "200 8005 /api/v1/governed/qa/generate"
for v in generate-qa generate-qa.json generate-qa.json/ generate-qa.api GENERATE-QA/ generate-qa/x; do
  expect "variant $v never reaches the generator" POST /api/search/v1/llm-search/$v "404 - -"
done
expect "internal generator path is not published" POST \
  /api-se/v1/llm-search/generate-qa/ "404 - -"
expect "articles keep going to search-service" GET \
  /api/search/v1/articles/ "200 8001 /api-se/v1/articles/"
expect "semantic search keeps going to search-service" POST \
  /api/search/v1/llm-search/semantic-search/ "200 8001 /api-se/v1/llm-search/semantic-search/"
expect "search v2 keeps going to search-bff-service" GET \
  /api/search/v2/articles/ "200 8002 /api-se/v2/articles/"
expect "review polling is under the governance prefix" GET \
  /api/governance/governed/qa/reviews/00000000-0000-0000-0000-000000000000 \
  "200 8005 /api/v1/governed/qa/reviews/00000000-0000-0000-0000-000000000000"
expect "search admin-token validator is not published" GET \
  /internal/auth/validate-admin-token/ "404 - -"
expect "identity token validator is not published" GET \
  /internal/auth/validate-token/ "404 - -"

echo "-- docs hub"
# Every service linked from the index must have its Swagger page.
pages=$(grep -o 'href="/api/docs/v1/[a-z-]*"' docs/index.html | sed 's#.*/v1/##; s#"##')
for p in $pages; do
  code=$(run "curl -s -o /dev/null -w '%{http_code}' $G/api/docs/v1/$p")
  [ "$code" = 200 ]; check "docs page /api/docs/v1/$p is served" $?
done

[ "$fail" = 0 ] && echo "ALL OK" || echo "FAILURES"
exit $fail
