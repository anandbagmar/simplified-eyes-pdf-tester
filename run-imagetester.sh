#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
JARS_DIR="$ROOT_DIR/jars"
CONFIG_FILE="$ROOT_DIR/config/imagetester.properties"
LOGS_DIR="$ROOT_DIR/logs"
DRY_RUN=false
TARGET_PATH=""

print_usage() {
  cat <<'EOF'
Usage:
  ./run-imagetester.sh [-c <config-file>] [--dry-run] -f <path>

Script options:
  -c, --config <file>   Path to the properties file.
  --dry-run             Show the resolved Java command and exit.
  -f <path>             Path to the target folder or file.
  -h, --help            Show this help.

Notes:
  - All ImageTester options other than -f are read from the properties file.
  - apiKey is read from the properties file or APPLITOOLS_API_KEY.
  - serverUrl and proxy are optional in the properties file.
  - -os is auto-set to Windows, Linux, or Mac OSX.
  - -ap is always sent as pdf.
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_quotes() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

print_quoted_command() {
  local arg escaped
  for arg in "$@"; do
    escaped="${arg//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if [[ "$arg" =~ [[:space:]] ]]; then
      printf '"%s" ' "$escaped"
    else
      printf '%s ' "$escaped"
    fi
  done
}

print_field() {
  local label="$1"
  shift
  printf '  %-13s : %s\n' "$label" "$*"
}

is_true() {
  local value
  value="$(trim "${1:-}")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "true" || "$value" == "yes" || "$value" == "1" || "$value" == "y" ]]
}

load_property() {
  local key="$1"
  local file="$2"
  local line value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(trim "$line")" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" == "$key="* ]]; then
      value="${line#*=}"
      strip_quotes "$value"
      return 0
    fi
  done < "$file"
}

append_accessibility_args() {
  local raw_value="$1"
  local normalized level version

  normalized="$(trim "$raw_value")"
  [[ -z "$normalized" ]] && return 0

  normalized="${normalized//;/\:}"
  if [[ "$normalized" == *:* ]]; then
    level="${normalized%%:*}"
    version="${normalized#*:}"
    level="$(trim "$level")"
    version="$(trim "$version")"

    RUN_ARGS+=("-ac")
    if [[ -n "$level" ]]; then
      RUN_ARGS+=("$level")
    fi
    if [[ -n "$version" ]]; then
      RUN_ARGS+=("$version")
    fi
  else
    RUN_ARGS+=("-ac" "$normalized")
  fi
}

detect_host_os() {
  case "$(uname -s)" in
    Darwin) printf 'Mac OSX' ;;
    Linux) printf 'Linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'Windows' ;;
    *) printf 'Linux' ;;
  esac
}

platform_asset_pattern() {
  local uname_s arch
  uname_s="$(uname -s)"
  arch="$(uname -m)"

  case "$uname_s" in
    Darwin)
      if [[ "$arch" == "arm64" ]]; then
        printf 'ImageTester_*_MacArm.jar'
      else
        printf 'ImageTester_*_Mac.jar'
      fi
      ;;
    Linux)
      printf 'ImageTester_*_Linux.jar'
      ;;
    *)
      printf 'ImageTester_*_Windows.jar'
      ;;
  esac
}

find_existing_jar() {
  mkdir -p "$JARS_DIR"
  local pattern candidate
  pattern="$(platform_asset_pattern)"

  candidate="$(find "$JARS_DIR" -maxdepth 1 -type f -name "$pattern" | sort -V | tail -n 1)"
  if [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="$(find "$JARS_DIR" -maxdepth 1 -type f -name 'ImageTester*.jar' | sort -V | tail -n 1)"
  if [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

download_latest_jar() {
  mkdir -p "$JARS_DIR"

  local api_url release_json asset_pattern download_url asset_name output_path
  api_url="https://api.github.com/repos/applitools/ImageTester/releases/latest"
  asset_pattern="$(platform_asset_pattern)"

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download ImageTester." >&2
    return 1
  fi

  echo "No ImageTester jar found in $JARS_DIR" >&2
  echo "Fetching latest release metadata from GitHub..." >&2
  release_json="$(curl -fsSL "$api_url")" || return 1

  download_url="$(printf '%s\n' "$release_json" | grep -Eo '"browser_download_url":[[:space:]]*"[^"]+"' | while IFS= read -r line; do
    line="${line#*:}"
    line="$(strip_quotes "$line")"
    asset_name="${line##*/}"
    if [[ "$asset_name" == $asset_pattern ]]; then
      printf '%s\n' "$line"
      break
    fi
  done)"

  if [[ -z "$download_url" ]]; then
    echo "ERROR: Could not locate a downloadable jar for pattern $asset_pattern" >&2
    return 1
  fi

  asset_name="${download_url##*/}"
  output_path="$JARS_DIR/$asset_name"

  echo "Downloading $asset_name ..." >&2
  curl -fL --retry 3 --retry-delay 2 -o "$output_path" "$download_url" || return 1
  printf '%s' "$output_path"
}

ensure_jar() {
  local jar_path
  if jar_path="$(find_existing_jar)"; then
    printf '%s' "$jar_path"
    return 0
  fi
  download_latest_jar
}

extract_summary_status() {
  local log_file="$1"
  if grep -Eiq 'unresolved|mismatch|different|failed' "$log_file"; then
    printf 'Differences detected or a failure was reported'
  elif grep -Eiq 'new test|new baseline|created baseline' "$log_file"; then
    printf 'A new baseline or test was created'
  elif grep -Eiq 'passed|completed successfully|saved' "$log_file"; then
    printf 'Completed successfully'
  else
    printf 'Execution finished. Review the detailed log below'
  fi
}

print_result_details() {
  local log_file="$1"

  perl -ne '
    BEGIN { $found = 0; %r = (); }

    sub flush_result {
      return unless $r{status};
      $found = 1;
      print "Result    : $r{status}\n";
      print "Test      : $r{name}\n";
      print "Steps     : $r{steps} total, $r{matches} matches, $r{mismatches} mismatches, $r{missing} missing\n";
      if ($r{accessibility}) {
        print "Accessib. : $r{accessibility} ($r{acc_level}, $r{acc_version})\n";
      }
      if ($r{url}) {
        print "URL       : $r{url}\n";
      }
      print "---\n";
      %r = ();
    }

    chomp;
    if (/^\[(Unresolved|Passed|Failed|New|Aborted)\]/) {
      flush_result();
      $r{status} = $1;
      $r{steps} = /steps:\s*(\d+)/ ? $1 : 0;
      $r{name} = /test name:\s*([^,]+)/ ? $1 : "";
      $r{matches} = /matches:\s*(\d+)/ ? $1 : 0;
      $r{mismatches} = /mismatches:\s*(\d+)/ ? $1 : 0;
      $r{missing} = /missing:\s*(\d+)/ ? $1 : 0;
      $r{url} = /URL:\s*(https:\/\/\S+)/ ? $1 : "";
      next;
    }
    if (/^Accessibility:/ && $r{status}) {
      $r{accessibility} = /AccessibilityStatus{name='\''([^'\'']+)'\''}/ ? $1 : "";
      $r{acc_level} = /AccessibilityLevel{name='\''([^'\'']+)'\''}/ ? $1 : "";
      $r{acc_version} = /AccessibilityGuidelinesVersion{name='\''([^'\'']+)'\''}/ ? $1 : "";
      next;
    }
    END {
      flush_result();
      exit($found ? 0 : 1);
    }
  ' "$log_file"
}

format_live_output() {
  perl -ne '
    BEGIN { %r = (); }

    sub flush_result {
      return unless $r{status};
      print "----------------------------------------\n";
      print "Applitools Result\n";
      print "----------------------------------------\n";
      print "Result    : $r{status}\n";
      print "Test      : $r{name}\n";
      print "Steps     : $r{steps} total, $r{matches} matches, $r{mismatches} mismatches, $r{missing} missing\n";
      if ($r{accessibility}) {
        print "Accessib. : $r{accessibility} ($r{acc_level}, $r{acc_version})\n";
      }
      if ($r{url}) {
        print "URL       : $r{url}\n";
      }
      print "\n";
      %r = ();
    }

    chomp;
    if (/^\[(Unresolved|Passed|Failed|New|Aborted)\]/) {
      flush_result();
      $r{status} = $1;
      $r{steps} = /steps:\s*(\d+)/ ? $1 : 0;
      $r{name} = /test name:\s*([^,]+)/ ? $1 : "";
      $r{matches} = /matches:\s*(\d+)/ ? $1 : 0;
      $r{mismatches} = /mismatches:\s*(\d+)/ ? $1 : 0;
      $r{missing} = /missing:\s*(\d+)/ ? $1 : 0;
      $r{url} = /URL:\s*(https:\/\/\S+)/ ? $1 : "";
      next;
    }
    if (/^Accessibility:/ && $r{status}) {
      $r{accessibility} = /AccessibilityStatus{name='\''([^'\'']+)'\''}/ ? $1 : "";
      $r{acc_level} = /AccessibilityLevel{name='\''([^'\'']+)'\''}/ ? $1 : "";
      $r{acc_version} = /AccessibilityGuidelinesVersion{name='\''([^'\'']+)'\''}/ ? $1 : "";
      flush_result();
      next;
    }
    if (/^\[\d+\/\d+\]\s*$/) {
      next;
    }
    flush_result();
    print "$_\n";
    END {
      flush_result();
    }
  '
}

CONFIG_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      CONFIG_OVERRIDE="${2:-}"
      shift 2
      ;;
    -f)
      TARGET_PATH="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "ERROR: Unsupported argument: $1" >&2
      echo "Only -f, --dry-run, -c/--config, and -h/--help are supported." >&2
      exit 1
      ;;
  esac
done

if [[ -n "$CONFIG_OVERRIDE" ]]; then
  CONFIG_FILE="$CONFIG_OVERRIDE"
fi

mkdir -p "$LOGS_DIR"

if ! command -v java >/dev/null 2>&1; then
  echo "ERROR: Java is not installed or not available on PATH." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Properties file not found: $CONFIG_FILE" >&2
  exit 1
fi

API_KEY="$(load_property "apiKey" "$CONFIG_FILE")"
SERVER_URL="$(load_property "serverUrl" "$CONFIG_FILE")"
PROXY_VALUE="$(load_property "proxy" "$CONFIG_FILE")"
APP_NAME="$(load_property "appName" "$CONFIG_FILE")"
MATCH_LEVEL="$(load_property "matchLevel" "$CONFIG_FILE")"
IGNORE_DISPLACEMENTS="$(load_property "ignoreDisplacements" "$CONFIG_FILE")"
ACCESSIBILITY="$(load_property "accessibility" "$CONFIG_FILE")"
IGNORE_REGIONS="$(load_property "ignoreRegions" "$CONFIG_FILE")"
CONTENT_REGIONS="$(load_property "contentRegions" "$CONFIG_FILE")"
LAYOUT_REGIONS="$(load_property "layoutRegions" "$CONFIG_FILE")"

if [[ -z "$API_KEY" && -n "${APPLITOOLS_API_KEY:-}" ]]; then
  API_KEY="$APPLITOOLS_API_KEY"
fi

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: Applitools apiKey is mandatory." >&2
  echo "Provide it in $CONFIG_FILE using apiKey=YOUR_KEY or set APPLITOOLS_API_KEY." >&2
  exit 1
fi

if [[ -z "$TARGET_PATH" ]]; then
  echo "ERROR: Target path is mandatory." >&2
  echo "Run the script with -f <path-to-pdf-folder-or-file>." >&2
  exit 1
fi

HOST_OS="$(detect_host_os)"
JAR_PATH="$(ensure_jar)" || {
  echo "ERROR: Unable to resolve the ImageTester jar." >&2
  exit 1
}

RUN_ARGS=("-f" "$TARGET_PATH" "-k" "$API_KEY")

if [[ -n "$APP_NAME" ]]; then
  RUN_ARGS+=("-a" "$APP_NAME")
fi

if [[ -n "$MATCH_LEVEL" && "$MATCH_LEVEL" != "Strict" ]]; then
  RUN_ARGS+=("-ml" "$MATCH_LEVEL")
fi

if is_true "$IGNORE_DISPLACEMENTS"; then
  RUN_ARGS+=("-id")
fi

if [[ -n "$ACCESSIBILITY" ]]; then
  append_accessibility_args "$ACCESSIBILITY"
fi

if [[ -n "$IGNORE_REGIONS" ]]; then
  RUN_ARGS+=("-ir" "$IGNORE_REGIONS")
fi

if [[ -n "$CONTENT_REGIONS" ]]; then
  RUN_ARGS+=("-cr" "$CONTENT_REGIONS")
fi

if [[ -n "$LAYOUT_REGIONS" ]]; then
  RUN_ARGS+=("-lr" "$LAYOUT_REGIONS")
fi

if [[ -n "$SERVER_URL" ]]; then
  RUN_ARGS+=("-s" "$SERVER_URL")
fi

if [[ -n "$PROXY_VALUE" ]]; then
  RUN_ARGS+=("-p" "$PROXY_VALUE")
fi

RUN_ARGS+=("-os" "$HOST_OS" "-ap" "pdf")

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOGS_DIR/imagetester-$TIMESTAMP.log"

echo
echo "========================================"
echo "Applitools ImageTester PDF Runner"
echo "========================================"
print_field "Jar" "$JAR_PATH"
print_field "Config" "$CONFIG_FILE"
print_field "Target" "$TARGET_PATH"
print_field "Host OS" "$HOST_OS"
print_field "Host App" "pdf"
print_field "App Name" "${APP_NAME:-ImageTester}"
print_field "Match Level" "${MATCH_LEVEL:-Strict} $(if [[ -z "$MATCH_LEVEL" || "$MATCH_LEVEL" == "Strict" ]]; then printf '(default)'; fi)"
print_field "Accessibility" "$(if [[ -n "$ACCESSIBILITY" ]]; then printf '%s' "$ACCESSIBILITY"; else printf 'disabled'; fi)"
print_field "Log File" "$LOG_FILE"
printf '  %-13s : ' 'Command'
print_quoted_command java -jar "$JAR_PATH" "${RUN_ARGS[@]}"
printf '\n'
echo "========================================"
echo

if [[ "$DRY_RUN" == true ]]; then
  printf 'Dry Run    : enabled\n'
  exit 0
fi

java -jar "$JAR_PATH" "${RUN_ARGS[@]}" 2>&1 | tee "$LOG_FILE" | format_live_output
EXIT_CODE="${PIPESTATUS[0]}"

DASHBOARD_URL="$(grep -Eo 'https://[^[:space:]]+' "$LOG_FILE" | tail -n 1 || true)"
SUMMARY_STATUS="$(extract_summary_status "$LOG_FILE")"
RESULT_DETAILS="$(print_result_details "$LOG_FILE" 2>/dev/null || true)"

if [[ -n "$RESULT_DETAILS" ]]; then
  echo
  echo "========================================"
  echo "Applitools Results"
  echo "========================================"
  printf '%s\n' "$RESULT_DETAILS" | sed '$d'
  echo "========================================"
fi

echo
echo "========================================"
echo "Execution Summary"
echo "========================================"
echo "Status     : $SUMMARY_STATUS"
echo "Exit Code  : $EXIT_CODE"
if [[ -n "$DASHBOARD_URL" ]]; then
  echo "Dashboard  : $DASHBOARD_URL"
fi
echo "Detailed Log: $LOG_FILE"
echo "========================================"

exit "$EXIT_CODE"
