#!/bin/bash

# ─────────────────────────────────────────
# Port Whisperer — Dev port monitor
# Part of claude-code-statusline
# ─────────────────────────────────────────
#
# Usage:
#   ports              — one-shot table (dev ports)
#   ports --all        — one-shot table (all ports)
#   ports watch        — persistent dashboard (Ctrl+C to exit)
#   ports <number>     — detail view for a specific port
#   ports kill <num>   — kill process on port (with confirmation)
#
# Environment:
#   PORTS_DEBUG=1      — write diagnostics to ~/.claude/.ports_debug.log

# ── Debug helper ──
DEBUG_LOG="$HOME/.claude/.ports_debug.log"
debug() { [ -n "$PORTS_DEBUG" ] && echo "[$(date -u +%H:%M:%S)] $*" >> "$DEBUG_LOG"; }

# ── ANSI palette ──
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
MAGENTA="\033[35m"
WHITE_BOLD="\033[37;1m"

# ── Dev port ranges and specific ports ──
DEV_RANGES="3000-3999 4000-4999 5000-5999 8000-8999 9000-9999"
DEV_SPECIFIC="80 443 1337 4200 5173 5174 6006 6379 27017 5432 3306 6432"

is_dev_port() {
  local port=$1
  # Check specific ports
  for p in $DEV_SPECIFIC; do
    [ "$port" -eq "$p" ] 2>/dev/null && return 0
  done
  # Check ranges
  [ "$port" -ge 3000 ] && [ "$port" -le 9999 ] && return 0
  return 1
}

# ── Format etime string from ps (MM:SS, HH:MM:SS, DD-HH:MM:SS) ──
format_uptime() {
  local etime
  etime=$(echo "$1" | tr -d ' ')
  [ -z "$etime" ] && echo "—" && return
  echo "$etime" | awk '{
    gsub(/^[ \t]+|[ \t]+$/, "")
    n = split($0, p, /[-:]/)
    s = 0
    if (n == 2) s = p[1]*60 + p[2]
    else if (n == 3) s = p[1]*3600 + p[2]*60 + p[3]
    else if (n == 4) s = p[1]*86400 + p[2]*3600 + p[3]*60 + p[4]
    if (s >= 86400) printf "%dd %dh", int(s/86400), int((s%86400)/3600)
    else if (s >= 3600) printf "%dh %dm", int(s/3600), int((s%3600)/60)
    else if (s >= 60) printf "%dm %ds", int(s/60), s%60
    else printf "%ds", s
  }'
}

# ── Get all listening ports -> lines of "port|pid|command" ──
# Deduplicates by port (first PID per port wins; handles IPv4/IPv6 dups)
get_listening_ports() {
  local filter="${1:-dev}"
  local cur_pid="" cur_cmd=""

  # Emit all matches, then deduplicate by port via awk (first occurrence wins)
  while IFS= read -r line; do
    case "$line" in
      p*) cur_pid="${line#p}" ;;
      c*) cur_cmd="${line#c}" ;;
      n*)
        local addr="${line#n}"
        local port="${addr##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        if [ "$filter" = "dev" ]; then
          is_dev_port "$port" || continue
        fi
        [ -n "$cur_pid" ] && echo "${port}|${cur_pid}|${cur_cmd}"
        ;;
    esac
  done < <(lsof -iTCP -sTCP:LISTEN -P -n -F pcn 2>/dev/null) \
    | awk -F'|' '!seen[$1]++'
}

# ── Get process info; sets globals _PI_CWD _PI_ARGS _PI_ETIME ──
get_process_info() {
  local pid=$1
  _PI_CWD=$(lsof -a -d cwd -p "$pid" -F n 2>/dev/null | grep '^n/' | sed 's/^n//' | head -1)
  _PI_ETIME=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
  _PI_ARGS=$(ps -p "$pid" -o args= 2>/dev/null)
  [ -z "$_PI_CWD" ] && _PI_CWD="n/a"
}

# ── Detect framework from args + CWD ──
detect_framework() {
  local cwd="$1"
  local args="$2"

  # Step 1: args keyword scan (zero I/O)
  case "$args" in
    *next-server*|*"next dev"*|*"next start"*|*"next build"*) echo "Next.js"; return ;;
    *vite*) echo "Vite"; return ;;
    *nuxt*) echo "Nuxt"; return ;;
    *remix*) echo "Remix"; return ;;
    *astro*) echo "Astro"; return ;;
    *gatsby*) echo "Gatsby"; return ;;
    *sveltekit*|*"svelte-kit"*) echo "SvelteKit"; return ;;
    *"ng serve"*|*"@angular"*) echo "Angular"; return ;;
    *nestjs*|*"@nestjs"*) echo "NestJS"; return ;;
    *fastify*) echo "Fastify"; return ;;
    *express*) echo "Express"; return ;;
    *koa*) echo "Koa"; return ;;
    *hono*) echo "Hono"; return ;;
    *"manage.py runserver"*|*django*) echo "Django"; return ;;
    *flask*) echo "Flask"; return ;;
    *uvicorn*) echo "Uvicorn"; return ;;
    *gunicorn*) echo "Gunicorn"; return ;;
    *fastapi*) echo "FastAPI"; return ;;
    *"rails server"*|*puma*) echo "Rails"; return ;;
    *hugo*) echo "Hugo"; return ;;
    *jekyll*) echo "Jekyll"; return ;;
  esac

  # Step 2: package.json deps
  if [ "$cwd" != "n/a" ] && [ -f "$cwd/package.json" ] && command -v python3 &>/dev/null; then
    local fw
    fw=$(python3 -c "
import json,sys
try:
  d=json.load(open('$cwd/package.json'))
  deps={}
  deps.update(d.get('dependencies',{}))
  deps.update(d.get('devDependencies',{}))
  m=[('next','Next.js'),('vite','Vite'),('express','Express'),
     ('fastify','Fastify'),('@angular/core','Angular'),('vue','Vue'),
     ('svelte','SvelteKit'),('nuxt','Nuxt'),('@remix-run/node','Remix'),
     ('astro','Astro'),('gatsby','Gatsby'),('koa','Koa'),
     ('hono','Hono'),('@nestjs/core','NestJS'),('react-scripts','CRA')]
  for p,n in m:
    if p in deps: print(n); sys.exit(0)
  print('Node.js')
except: print('')
" 2>/dev/null)
    [ -n "$fw" ] && echo "$fw" && return
  fi

  # Step 3: marker files
  if [ "$cwd" != "n/a" ]; then
    [ -f "$cwd/Cargo.toml" ]         && echo "Rust"   && return
    [ -f "$cwd/go.mod" ]             && echo "Go"     && return
    [ -f "$cwd/pyproject.toml" ]     && echo "Python" && return
    [ -f "$cwd/requirements.txt" ]   && echo "Python" && return
    [ -f "$cwd/Gemfile" ]            && echo "Ruby"   && return
    [ -f "$cwd/mix.exs" ]            && echo "Elixir" && return
    [ -f "$cwd/pom.xml" ]            && echo "Java"   && return
    [ -f "$cwd/build.gradle" ]       && echo "Java"   && return
    [ -f "$cwd/composer.json" ]      && echo "PHP"    && return
  fi

  # Step 4: fallback to command name
  local cmd
  cmd=$(echo "$args" | awk '{print $1}')
  basename "$cmd" 2>/dev/null || echo "—"
}

# ── TCP health probe ──
check_health() {
  local port=$1
  if ! nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; then
    echo "down"
    return
  fi
  # HTTP probe for response time
  if command -v curl &>/dev/null; then
    local result
    result=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
      --connect-timeout 1 --max-time 2 \
      "http://127.0.0.1:${port}/" 2>/dev/null)
    local http_code time_total
    http_code=$(echo "$result" | awk '{print $1}')
    time_total=$(echo "$result" | awk '{print $2}')
    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
      if awk -v t="$time_total" 'BEGIN{exit !(t > 1.0)}'; then
        echo "slow"
      else
        echo "healthy"
      fi
      return
    fi
  fi
  echo "healthy"
}

# ── Collect all data -> enriched rows "port|cmd|pid|project|framework|uptime|status" ──
collect_all_data() {
  local filter="${1:-dev}"
  local rows=()

  while IFS='|' read -r port pid cmd; do
    debug "Processing port $port pid $pid cmd $cmd"
    get_process_info "$pid"
    local cwd="$_PI_CWD"
    local args="$_PI_ARGS"
    local etime="$_PI_ETIME"

    local project="—"
    if [ "$cwd" != "n/a" ] && [ -n "$cwd" ]; then
      project=$(basename "$cwd")
    fi

    local uptime
    uptime=$(format_uptime "$etime")

    local framework
    framework=$(detect_framework "$cwd" "$args")
    [ -z "$framework" ] && framework="—"

    local health
    health=$(check_health "$port")

    rows+=("${port}|${cmd}|${pid}|${project}|${framework}|${uptime}|${health}")
  done < <(get_listening_ports "$filter")

  # Sort by port number
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1 -n
}

# ── Truncate string to max length with ellipsis ──
trunc() {
  local s="$1" max="$2"
  if [ ${#s} -gt "$max" ]; then
    echo "${s:0:$((max-1))}…"
  else
    echo "$s"
  fi
}

# ── Render header banner ──
render_header() {
  printf "${DIM} ┌─────────────────────────────────────┐${RESET}\n"
  printf "${DIM} │${RESET}  ${BOLD}🔊 Port Whisperer${RESET}                    ${DIM}│${RESET}\n"
  printf "${DIM} │${RESET}  ${DIM}listening to your ports...${RESET}           ${DIM}│${RESET}\n"
  printf "${DIM} └─────────────────────────────────────┘${RESET}\n"
  printf "\n"
}

# ── Draw a horizontal border line ──
# type: top | mid | bot
# widths: array of column widths
draw_border() {
  local type="$1"; shift
  local widths=("$@")
  local left mid right cross

  case "$type" in
    top) left="┌"; mid="─"; cross="┬"; right="┐" ;;
    mid) left="├"; mid="─"; cross="┼"; right="┤" ;;
    bot) left="└"; mid="─"; cross="┴"; right="┘" ;;
  esac

  printf "${DIM}%s" "$left"
  local first=1
  for w in "${widths[@]}"; do
    [ "$first" -eq 0 ] && printf "%s" "$cross"
    printf "%0.s${mid}" $(seq 1 $((w + 2)))
    first=0
  done
  printf "%s${RESET}\n" "$right"
}

# ── Render table from rows ──
render_table() {
  local -a data_rows=("$@")

  if [ ${#data_rows[@]} -eq 0 ]; then
    printf "  ${DIM}No listening ports found.${RESET}\n"
    return
  fi

  # Column headers
  local -a headers=("PORT" "PROCESS" "PID" "PROJECT" "FRAMEWORK" "UPTIME" "STATUS")
  # Min widths
  local -a widths=(5 7 5 10 9 6 9)

  # Measure actual data widths
  for row in "${data_rows[@]}"; do
    IFS='|' read -ra fields <<< "$row"
    for i in "${!fields[@]}"; do
      [ $i -ge ${#widths[@]} ] && continue
      local val="${fields[$i]}"
      # For status, measure display text not the health keyword
      if [ $i -eq 6 ]; then
        case "$val" in
          healthy) val="● healthy" ;;
          slow)    val="● slow" ;;
          down)    val="● down" ;;
        esac
      fi
      local len=${#val}
      [ "$len" -gt "${widths[$i]}" ] && widths[$i]=$len
    done
  done

  draw_border top "${widths[@]}"

  # Header row
  printf "${DIM}│${RESET}"
  for i in "${!headers[@]}"; do
    local h="${headers[$i]}"
    local w="${widths[$i]}"
    printf " ${BOLD}%-${w}s${RESET} ${DIM}│${RESET}" "$h"
  done
  printf "\n"

  draw_border mid "${widths[@]}"

  # Data rows
  for row in "${data_rows[@]}"; do
    IFS='|' read -ra fields <<< "$row"
    local port="${fields[0]}"
    local cmd="${fields[1]}"
    local pid="${fields[2]}"
    local project="${fields[3]}"
    local framework="${fields[4]}"
    local uptime="${fields[5]}"
    local health="${fields[6]}"

    # Truncate long values
    project=$(trunc "$project" "${widths[3]}")
    framework=$(trunc "$framework" "${widths[4]}")

    # Status display
    local status_text status_color
    case "$health" in
      healthy) status_text="● healthy"; status_color="$GREEN" ;;
      slow)    status_text="● slow";    status_color="$YELLOW" ;;
      down)    status_text="● down";    status_color="$RED" ;;
      *)       status_text="● —";       status_color="$DIM" ;;
    esac

    printf "${DIM}│${RESET}"
    printf " ${CYAN}%-${widths[0]}s${RESET} ${DIM}│${RESET}" ":${port}"
    printf " %-${widths[1]}s ${DIM}│${RESET}" "$cmd"
    printf " ${DIM}%-${widths[2]}s${RESET} ${DIM}│${RESET}" "$pid"
    printf " ${WHITE_BOLD}%-${widths[3]}s${RESET} ${DIM}│${RESET}" "$project"
    printf " ${MAGENTA}%-${widths[4]}s${RESET} ${DIM}│${RESET}" "$framework"
    printf " ${DIM}%-${widths[5]}s${RESET} ${DIM}│${RESET}" "$uptime"
    printf " ${status_color}%-${widths[6]}s${RESET} ${DIM}│${RESET}" "$status_text"
    printf "\n"
  done

  draw_border bot "${widths[@]}"
}

render_footer() {
  local count="$1"
  local mode="${2:-table}"
  local filter="${3:-dev}"

  printf "\n"
  printf "  ${DIM}%d port%s active${RESET}" "$count" "$([ "$count" -ne 1 ] && echo 's')"

  if [ "$mode" = "watch" ]; then
    printf "  ${DIM}·  Ctrl+C to exit${RESET}"
  else
    printf "  ${DIM}·  Run ${RESET}ports <number>${DIM} for details${RESET}"
    [ "$filter" = "dev" ] && printf "  ${DIM}·  ${RESET}--all${DIM} to show everything${RESET}"
  fi
  printf "\n"
}

# ── Detail view for a single port ──
render_detail() {
  local port="$1"
  local pid
  pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1)

  if [ -z "$pid" ]; then
    printf "  ${RED}No process listening on port %s${RESET}\n" "$port"
    return 1
  fi

  get_process_info "$pid"
  local cwd="$_PI_CWD"
  local args="$_PI_ARGS"
  local etime="$_PI_ETIME"

  local cmd; cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
  local ppid; ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  local uptime; uptime=$(format_uptime "$etime")
  local project="—"
  [ "$cwd" != "n/a" ] && [ -n "$cwd" ] && project=$(basename "$cwd")
  local framework; framework=$(detect_framework "$cwd" "$args")
  local health; health=$(check_health "$port")
  local open_fds; open_fds=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ')

  local status_text status_color
  case "$health" in
    healthy) status_text="● healthy"; status_color="$GREEN" ;;
    slow)    status_text="● slow";    status_color="$YELLOW" ;;
    down)    status_text="● down";    status_color="$RED" ;;
  esac

  printf "\n"
  printf "  ${BOLD}Port :${port}${RESET}\n"
  printf "  ${DIM}─────────────────────────────────────${RESET}\n"
  printf "  ${DIM}%-12s${RESET} %s\n"    "Process"   "$cmd"
  printf "  ${DIM}%-12s${RESET} %s\n"    "PID"        "$pid"
  printf "  ${DIM}%-12s${RESET} %s\n"    "PPID"       "$ppid"
  printf "  ${DIM}%-12s${RESET} %s\n"    "CWD"        "$cwd"
  printf "  ${DIM}%-12s${RESET} %s\n"    "Args"       "$args"
  printf "  ${DIM}%-12s${RESET} %s\n"    "Project"    "$project"
  printf "  ${DIM}%-12s${RESET} ${MAGENTA}%s${RESET}\n" "Framework" "$framework"
  printf "  ${DIM}%-12s${RESET} %s\n"    "Uptime"     "$uptime"
  printf "  ${DIM}%-12s${RESET} %s\n"    "Open FDs"   "$open_fds"
  printf "  ${DIM}%-12s${RESET} ${status_color}%s${RESET}\n" "Status" "$status_text"
  printf "\n"
}

# ── Modes ──

_load_rows() {
  # Bash-3-compatible replacement for mapfile
  # Usage: _load_rows filter; result in global _ROWS array
  local filter="${1:-dev}"
  _ROWS=()
  while IFS= read -r line; do
    [ -n "$line" ] && _ROWS+=("$line")
  done < <(collect_all_data "$filter")
}

mode_table() {
  local filter="${1:-dev}"
  render_header
  _load_rows "$filter"
  render_table "${_ROWS[@]}"
  render_footer "${#_ROWS[@]}" "table" "$filter"
}

mode_watch() {
  local filter="${1:-dev}"

  # Require a real terminal
  if [ ! -t 1 ]; then
    mode_table "$filter"
    return
  fi

  tput smcup
  tput civis
  trap 'tput cnorm; tput rmcup; exit 0' EXIT INT TERM

  while true; do
    tput cup 0 0
    render_header
    _load_rows "$filter"
    render_table "${_ROWS[@]}"
    render_footer "${#_ROWS[@]}" "watch" "$filter"
    tput ed
    sleep 2
  done
}

mode_detail() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    printf "  ${RED}Invalid port: %s${RESET}\n" "$port"
    exit 1
  fi
  render_detail "$port"
}

mode_kill() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    printf "  ${RED}Invalid port: %s${RESET}\n" "$port"
    exit 1
  fi

  local pid
  pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1)
  if [ -z "$pid" ]; then
    printf "  ${RED}No process listening on port %s${RESET}\n" "$port"
    exit 1
  fi

  local cmd; cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
  get_process_info "$pid"
  local cwd="$_PI_CWD"

  printf "\n"
  printf "  Kill ${BOLD}%s${RESET} (PID %s) on port ${CYAN}:%s${RESET}?\n" "$cmd" "$pid" "$port"
  printf "  ${DIM}CWD: %s${RESET}\n\n" "$cwd"
  printf "  Confirm (y/N): "
  read -r -n 1 reply
  printf "\n"

  if [[ "$reply" =~ ^[Yy]$ ]]; then
    kill "$pid" 2>/dev/null
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      printf "  ${YELLOW}Process still running. Force kill (kill -9)?${RESET} (y/N): "
      read -r -n 1 reply2
      printf "\n"
      if [[ "$reply2" =~ ^[Yy]$ ]]; then
        kill -9 "$pid" 2>/dev/null
        printf "  ${GREEN}Force killed.${RESET}\n\n"
      else
        printf "  ${DIM}Cancelled.${RESET}\n\n"
      fi
    else
      printf "  ${GREEN}Killed.${RESET}\n\n"
    fi
  else
    printf "  ${DIM}Cancelled.${RESET}\n\n"
  fi
}

show_help() {
  printf "\n"
  printf "  ${BOLD}Port Whisperer${RESET} — dev port monitor\n\n"
  printf "  ${DIM}Usage:${RESET}\n"
  printf "    ports                  one-shot table (dev ports)\n"
  printf "    ports --all            one-shot table (all ports)\n"
  printf "    ports watch            persistent dashboard\n"
  printf "    ports <number>         detail view for a port\n"
  printf "    ports kill <number>    kill process on a port\n"
  printf "    ports --help           this help\n\n"
  printf "  ${DIM}Environment:${RESET}\n"
  printf "    PORTS_DEBUG=1          debug logging to ~/.claude/.ports_debug.log\n\n"
}

# ── Entry point ──
main() {
  local filter="dev"
  local mode="table"
  local target_port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      watch|-w)    mode="watch" ;;
      kill)        mode="kill"; target_port="${2:-}"; shift ;;
      --all|-a)    filter="all" ;;
      --help|-h)   show_help; return 0 ;;
      --debug)     PORTS_DEBUG=1 ;;
      [0-9]*)      mode="detail"; target_port="$1" ;;
      *)           printf "  Unknown option: %s\n" "$1"; show_help; return 1 ;;
    esac
    shift
  done

  case "$mode" in
    table)  mode_table "$filter" ;;
    watch)  mode_watch "$filter" ;;
    detail) mode_detail "$target_port" ;;
    kill)   mode_kill "$target_port" ;;
  esac
}

main "$@"
