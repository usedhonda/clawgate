#!/usr/bin/env bash
set -euo pipefail

# Persisted watcher for tmux question/completion/progress delivery.
# Tracks Host B relay events and whether matching events appear on Host A server/gateway.
#
# Usage:
#   ./scripts/watch-tmux-delivery.sh
#   ./scripts/watch-tmux-delivery.sh --remote-host macmini --duration 300

REMOTE_HOST="macmini"
LOCAL_API="http://127.0.0.1:9765"
INTERVAL=2
DURATION=0
LOG_FILE="/tmp/clawgate-tmux-delivery.log"
SOURCES='question|completion|progress'
PENDING_TIMEOUT=90
PENDING_FILE="/tmp/clawgate-tmux-delivery.pending.tsv"
GATEWAY_FILE="/tmp/clawgate-tmux-delivery.gateway.tsv"
INCLUDE_BACKLOG=false
LOCAL_TOKEN="${RELAY_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --local-api)
      LOCAL_API="$2"; shift 2 ;;
    --interval)
      INTERVAL="$2"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --log-file)
      LOG_FILE="$2"; shift 2 ;;
    --pending-timeout)
      PENDING_TIMEOUT="$2"; shift 2 ;;
    --include-backlog)
      INCLUDE_BACKLOG=true; shift ;;
    --token)
      LOCAL_TOKEN="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$LOCAL_TOKEN" ]]; then
  LOCAL_TOKEN="$(defaults read com.clawgate.app clawgate.federationToken 2>/dev/null || defaults read ClawGate clawgate.federationToken 2>/dev/null || true)"
fi

curl_local() {
  local url="$1"
  if [[ -n "$LOCAL_TOKEN" ]]; then
    curl -fsS -m 3 -H "Authorization: Bearer ${LOCAL_TOKEN}" "$url" 2>/dev/null || true
  else
    curl -fsS -m 3 "$url" 2>/dev/null || true
  fi
}

start_ts="$(date +%s)"
client_cursor=0
server_cursor=0

: > "$PENDING_FILE"
: > "$GATEWAY_FILE"

echo "== watch-tmux-delivery ==" | tee -a "$LOG_FILE"
echo "remote_host=$REMOTE_HOST interval=${INTERVAL}s duration=${DURATION}s pending_timeout=${PENDING_TIMEOUT}s" | tee -a "$LOG_FILE"

if [[ "$INCLUDE_BACKLOG" != "true" ]]; then
  seed_local="$(curl_local "$LOCAL_API/v1/poll")"
  if [[ -n "$seed_local" ]]; then
    seed_cursor="$(echo "$seed_local" | jq -r '.next_cursor // 0')"
    if [[ "$seed_cursor" =~ ^[0-9]+$ ]]; then
      client_cursor="$seed_cursor"
    fi
  fi
  seed_server="$(ssh "$REMOTE_HOST" "curl -fsS -m 3 'http://127.0.0.1:8765/v1/poll'" 2>/dev/null || true)"
  if [[ -n "$seed_server" ]]; then
    seed_cursor="$(echo "$seed_server" | jq -r '.next_cursor // 0')"
    if [[ "$seed_cursor" =~ ^[0-9]+$ ]]; then
      server_cursor="$seed_cursor"
    fi
  fi
  echo "start from current cursors: client=$client_cursor server=$server_cursor" | tee -a "$LOG_FILE"
fi

fallback_hash_key() {
  local src="$1" proj="$2" text="$3"
  printf '%s|%s|%s' "$src" "$proj" "$text" | shasum | awk '{print $1}'
}

build_key() {
  local event_id="$1" src="$2" proj="$3" short="$4"
  if [[ -n "$event_id" && "$event_id" != "null" ]]; then
    printf 'id:%s' "$event_id"
  else
    printf 'hash:%s' "$(fallback_hash_key "$src" "$proj" "$short")"
  fi
}

append_jsonl() {
  local json="$1"
  echo "$json" >> "$LOG_FILE"
}

sanitize_field() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

pending_upsert() {
  local key="$1" started="$2" src="$3" proj="$4" text="$5"
  local tmp
  tmp="$(mktemp)"
  awk -F $'\t' -v k="$key" '$1 != k' "$PENDING_FILE" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$started" "$src" "$proj" "$text" >> "$tmp"
  mv "$tmp" "$PENDING_FILE"
}

pending_get_started() {
  local key="$1"
  awk -F $'\t' -v k="$key" '$1 == k { print $2; exit }' "$PENDING_FILE"
}

pending_remove() {
  local key="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F $'\t' -v k="$key" '$1 != k' "$PENDING_FILE" > "$tmp" || true
  mv "$tmp" "$PENDING_FILE"
}

pending_count() {
  wc -l < "$PENDING_FILE" | tr -d ' '
}

gateway_upsert() {
  local key="$1" started="$2" src="$3" proj="$4" text="$5"
  local tmp
  tmp="$(mktemp)"
  awk -F $'\t' -v k="$key" '$1 != k' "$GATEWAY_FILE" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$started" "$src" "$proj" "$text" >> "$tmp"
  mv "$tmp" "$GATEWAY_FILE"
}

gateway_remove() {
  local key="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F $'\t' -v k="$key" '$1 != k' "$GATEWAY_FILE" > "$tmp" || true
  mv "$tmp" "$GATEWAY_FILE"
}

gateway_count() {
  wc -l < "$GATEWAY_FILE" | tr -d ' '
}

flush_timed_out_gateway() {
  local now_ts="$1" now_iso="$2"
  local tmp
  tmp="$(mktemp)"
  while IFS=$'\t' read -r key started src proj text; do
    [[ -z "$key" ]] && continue
    local age=$((now_ts - started))
    if (( age >= PENDING_TIMEOUT )); then
      append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind gateway_timeout --arg key "$key" --arg src "$src" --arg proj "$proj" --arg text "$text" --argjson age_sec "$age" '{ts:$ts,kind:$kind,key:$key,source:$src,project:$proj,text:$text,age_sec:$age_sec}')"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$started" "$src" "$proj" "$text" >> "$tmp"
    fi
  done < "$GATEWAY_FILE"
  mv "$tmp" "$GATEWAY_FILE"
}

flush_timed_out_pending() {
  local now_ts="$1" now_iso="$2"
  local tmp
  tmp="$(mktemp)"

  while IFS=$'\t' read -r key started src proj text; do
    [[ -z "$key" ]] && continue
    local age=$((now_ts - started))
    if (( age >= PENDING_TIMEOUT )); then
      append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind delivery_timeout --arg key "$key" --arg src "$src" --arg proj "$proj" --arg text "$text" --argjson age_sec "$age" '{ts:$ts,kind:$kind,key:$key,source:$src,project:$proj,text:$text,age_sec:$age_sec}')"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$started" "$src" "$proj" "$text" >> "$tmp"
    fi
  done < "$PENDING_FILE"

  mv "$tmp" "$PENDING_FILE"
}

while true; do
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ts="$(date +%s)"

  local_poll="$(curl_local "$LOCAL_API/v1/poll?since=$client_cursor")"
  if [[ -n "$local_poll" ]]; then
    next_client="$(echo "$local_poll" | jq -r '.next_cursor // 0')"
    if [[ "$next_client" =~ ^[0-9]+$ ]]; then
      client_cursor="$next_client"
    fi

    while IFS= read -r ev; do
      src="$(echo "$ev" | jq -r '.payload.source // ""')"
      proj="$(echo "$ev" | jq -r '.payload.project // .payload.conversation // "unknown"')"
      text="$(echo "$ev" | jq -r '.payload.text // ""')"
      event_id="$(echo "$ev" | jq -r '.payload.event_id // ""')"
      capture="$(echo "$ev" | jq -r '.payload.capture // ""')"
      eid="$(echo "$ev" | jq -r '.id')"
      obs="$(echo "$ev" | jq -r '.observedAt // ""')"
      short="$(printf '%s' "$text" | tr '\n' ' ' | cut -c1-140)"
      key="$(build_key "$event_id" "$src" "$proj" "$short")"

      short_safe="$(sanitize_field "$short")"
      src_safe="$(sanitize_field "$src")"
      proj_safe="$(sanitize_field "$proj")"
      pending_upsert "$key" "$now_ts" "$src_safe" "$proj_safe" "$short_safe"

      append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind client_event --arg id "$eid" --arg event_id "$event_id" --arg key "$key" --arg src "$src" --arg proj "$proj" --arg obs "$obs" --arg capture "$capture" --arg text "$short" '{ts:$ts,kind:$kind,id:$id,event_id:$event_id,key:$key,source:$src,project:$proj,observed_at:$obs,capture:$capture,text:$text}')"
    done < <(echo "$local_poll" | jq -c ".events[]? | select(.adapter==\"tmux\" and ((.payload.source // \"\")|test(\"$SOURCES\")))")
  fi

  server_poll="$(ssh "$REMOTE_HOST" "curl -fsS -m 3 'http://127.0.0.1:8765/v1/poll?since=$server_cursor'" 2>/dev/null || echo '')"
  if [[ -n "$server_poll" ]]; then
    next_server="$(echo "$server_poll" | jq -r '.next_cursor // 0')"
    if [[ "$next_server" =~ ^[0-9]+$ ]]; then
      server_cursor="$next_server"
    fi

    while IFS= read -r ev; do
      src="$(echo "$ev" | jq -r '.payload.source // ""')"
      proj="$(echo "$ev" | jq -r '.payload.project // .payload.conversation // "unknown"')"
      text="$(echo "$ev" | jq -r '.payload.text // ""')"
      event_id="$(echo "$ev" | jq -r '.payload.event_id // ""')"
      eid="$(echo "$ev" | jq -r '.id')"
      obs="$(echo "$ev" | jq -r '.observedAt // ""')"
      short="$(printf '%s' "$text" | tr '\n' ' ' | cut -c1-140)"
      key="$(build_key "$event_id" "$src" "$proj" "$short")"
      short_safe="$(sanitize_field "$short")"
      src_safe="$(sanitize_field "$src")"
      proj_safe="$(sanitize_field "$proj")"

      append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind server_event --arg id "$eid" --arg event_id "$event_id" --arg key "$key" --arg src "$src" --arg proj "$proj" --arg obs "$obs" --arg text "$short" '{ts:$ts,kind:$kind,id:$id,event_id:$event_id,key:$key,source:$src,project:$proj,observed_at:$obs,text:$text}')"

      started="$(pending_get_started "$key")"
      if [[ -n "$started" ]]; then
        latency_ms=$(( (now_ts - started) * 1000 ))
        append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind delivery_ok --arg key "$key" --arg src "$src" --arg proj "$proj" --arg text "$short" --argjson latency_ms "$latency_ms" '{ts:$ts,kind:$kind,key:$key,source:$src,project:$proj,text:$text,latency_ms:$latency_ms}')"
        gateway_upsert "$key" "$started" "$src_safe" "$proj_safe" "$short_safe"
        pending_remove "$key"
      fi
    done < <(echo "$server_poll" | jq -c ".events[]? | select(.adapter==\"tmux\" and ((.payload.source // \"\")|test(\"$SOURCES\")))")
  fi

  gateway_tail="$(ssh "$REMOTE_HOST" "tail -n 280 ~/.openclaw/logs/gateway.log" 2>/dev/null || true)"
  if [[ -n "$gateway_tail" ]]; then
    tmp_gateway="$(mktemp)"
    while IFS=$'\t' read -r key started src proj text; do
      [[ -z "$key" ]] && continue
      case "$src" in
        completion) pattern="tmux completion from \"$proj\"" ;;
        question)   pattern="tmux question from \"$proj\"" ;;
        progress)   pattern="tmux progress from \"$proj\"" ;;
        *)          pattern="tmux .* from \"$proj\"" ;;
      esac
      if echo "$gateway_tail" | grep -q "$pattern"; then
        latency_ms=$(( (now_ts - started) * 1000 ))
        append_jsonl "$(jq -cn --arg ts "$now_iso" --arg kind gateway_ok --arg key "$key" --arg src "$src" --arg proj "$proj" --arg text "$text" --argjson latency_ms "$latency_ms" '{ts:$ts,kind:$kind,key:$key,source:$src,project:$proj,text:$text,latency_ms:$latency_ms}')"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$started" "$src" "$proj" "$text" >> "$tmp_gateway"
      fi
    done < "$GATEWAY_FILE"
    mv "$tmp_gateway" "$GATEWAY_FILE"
  fi

  flush_timed_out_pending "$now_ts" "$now_iso"
  flush_timed_out_gateway "$now_ts" "$now_iso"

  pending_now="$(pending_count)"
  gateway_now="$(gateway_count)"
  printf '[%s] client_cursor=%s server_cursor=%s pending_server=%s pending_gateway=%s\n' "$(date '+%H:%M:%S')" "$client_cursor" "$server_cursor" "$pending_now" "$gateway_now" | tee -a "$LOG_FILE"

  if [[ "$DURATION" -gt 0 ]]; then
    if (( now_ts - start_ts >= DURATION )); then
      echo "done: duration ${DURATION}s" | tee -a "$LOG_FILE"
      exit 0
    fi
  fi

  sleep "$INTERVAL"
done
