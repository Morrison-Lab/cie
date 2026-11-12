#!/bin/bash
# SessionStart hook: install the render toolchain in cloud sessions.
#
# Adapted from Morrison-Lab/lds's .claude/hooks/render-toolchain.sh.
# A fresh cloud container has R and Quarto but not what a render of this site
# needs (measured 2026-11-11, cie#66):
# - none of the R packages the chapters load, so a page with a code chunk fails;
# - no TeX, so the PDF handouts fail;
# - no typos or lintr for the checks before a commit.
#
# The R packages are read from the `r-packages` inputs of the two render
# workflows, so this hook never drifts from CI; if one is still missing
# afterwards, the log ends with `== FAILED`.
# Installing takes several minutes, so it runs detached and the hook returns at
# once; every firing (startup, resume, clear, compact) tells the session where
# the log and the done-marker are, and which export a render needs.
#
# Local sessions are left alone.

set -u

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
state="${TMPDIR:-/tmp}/cie-render-toolchain"
mkdir -p "$state"
log="$state/install.log"
done_marker="$state/done"
lock="$state/lock"

tinytex="$HOME/.TinyTeX/bin/x86_64-linux"
# Always put TinyTeX on PATH: on a fresh container the install below creates the
# directory after this message is written.
exports="export PATH=\"$tinytex:\$PATH\""

say() {
  jq -n --arg m "$1" '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": $m}}'
}

if [ -e "$done_marker" ]; then
  say "The render toolchain is installed (log: $log). Before rendering, run: $exports"
  exit 0
fi

# `quarto install tinytex` fails here: it asks api.github.com for the latest
# release, which the proxy refuses (403). The release asset by tag downloads.
# The small TinyTeX-1 bundle lacks scrartcl, and its tlmgr refuses to install
# from mirrors a TeX Live release ahead, so take the full TinyTeX bundle, which
# holds everything the handouts need with no tlmgr step (measured 2026-11-11).
install_tinytex() {
  local tmp tag year month i
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' RETURN
  year="$(date -u +%Y)"
  month="$((10#$(date -u +%m)))"
  # Newest tag that exists, going back up to 18 months; tags are vYYYY.MM.
  for i in $(seq 0 17); do
    tag="$(printf 'v%d.%02d' "$year" "$month")"
    if curl -fsIL --max-time 30 "https://github.com/rstudio/tinytex-releases/releases/download/$tag/TinyTeX-$tag.tar.gz" >/dev/null; then
      break
    fi
    tag=""
    month=$((month - 1))
    if [ "$month" -eq 0 ]; then month=12; year=$((year - 1)); fi
  done
  [ -n "$tag" ] || { echo "== no TinyTeX release tag found"; return 1; }
  echo "== TinyTeX $tag"
  # The bundle is about 200 MB and the proxy sometimes resets a long transfer,
  # so resume the download a few times before giving up.
  for i in 1 2 3 4 5; do
    curl -fsSL -C - -o "$tmp/tinytex.tar.gz" \
      "https://github.com/rstudio/tinytex-releases/releases/download/$tag/TinyTeX-$tag.tar.gz" && break
    [ "$i" -lt 5 ] || return 1
    sleep $((2 ** i))
  done
  tar -xzf "$tmp/tinytex.tar.gz" -C "$HOME" || return 1
}

install() {
  status=0

  # Every entry of each `r-packages: |` block: the lines indented deeper than
  # the key, skipping blank lines and comments.
  mapfile -t r_entries < <(
    awk '
      /^ *r-packages: *\|/ { match($0, /^ */); ind = RLENGTH; f = 1; next }
      f && /^ *(#.*)?$/ { next }
      f { match($0, /^ */); if (RLENGTH > ind) { sub(/^ +/, ""); sub(/ +$/, ""); print; next } f = 0 }
    ' "$root/.github/workflows/preview.yml" "$root/.github/workflows/publish.yml" | sort -u
  )
  # `any::pkg`, `cran::pkg` or a bare name come from CRAN; this site needs no
  # GitHub packages, so any other kind of entry is reported rather than skipped.
  r_pkgs=()
  for entry in "${r_entries[@]}"; do
    case "$entry" in
      any::* | cran::*) r_pkgs+=("${entry#*::}") ;;
      *::* | */*)
        echo "== r-packages entry of a kind this hook cannot install: $entry"
        status=1
        ;;
      *) r_pkgs+=("$entry") ;;
    esac
  done
  # An empty or knitr-less list means the workflows moved or changed shape;
  # installing only lintr would then report success with nothing usable.
  if ! printf '%s\n' "${r_pkgs[@]}" | grep -qx knitr; then
    echo "== no r-packages (with knitr) found in $root/.github/workflows/{preview,publish}.yml"
    status=1
  fi
  r_pkgs+=(lintr)
  echo "== R packages: ${r_pkgs[*]}"

  # Posit Package Manager serves prebuilt Linux binaries, which needs an R user
  # agent; without binaries, compiling qte's dependencies takes most of an hour.
  # The R code is single-quoted on purpose: its $ belongs to R, not the shell.
  # shellcheck disable=SC2016
  Rscript --no-init-file -e '
    codename <- tryCatch(system("lsb_release -cs", intern = TRUE), error = function(e) "noble")
    options(
      repos = c(CRAN = sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest", codename)),
      HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(),
        paste(getRversion(), R.version$platform, R.version$arch, R.version$os))
    )
    installed <- function(p) vapply(p, requireNamespace, logical(1), quietly = TRUE)
    pkgs <- commandArgs(trailingOnly = TRUE)
    missing <- pkgs[!installed(pkgs)]
    if (length(missing)) install.packages(missing, Ncpus = 4)
    still <- pkgs[!installed(pkgs)]
    if (length(still)) stop("not installed: ", paste(still, collapse = ", "))
  ' "${r_pkgs[@]}" || status=1

  if [ ! -d "$HOME/.TinyTeX/bin/x86_64-linux" ] && ! command -v pdflatex >/dev/null; then
    echo "== TinyTeX"
    install_tinytex || status=1
  fi

  if ! command -v typos >/dev/null; then
    echo "== typos"
    if command -v uv >/dev/null; then
      uv tool install typos || status=1
    else
      pip install -q typos || status=1
    fi
  fi

  if [ "$status" -eq 0 ]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$done_marker"
    echo "== done"
  else
    echo "== FAILED: see the steps above"
  fi
}

# One install at a time: SessionStart also fires on resume, clear and compact,
# and a second run would race the first on R's library lock.
# The installer holds an flock on $lock for as long as it runs; the kernel
# drops it when the process exits or dies, so no lock is ever left stale.
if flock -n "$lock" true; then
  # The installer script is single-quoted: its $ belong to the inner shell.
  # shellcheck disable=SC2016
  env root="$root" done_marker="$done_marker" lock="$lock" \
    setsid nohup bash -c "$(declare -f install_tinytex install)"'
      exec 9>> "$lock"
      if ! flock -n 9; then
        echo "== another install holds $lock; this one exits"
        exit 0
      fi
      echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) install started"
      install' \
    >> "$log" 2>&1 < /dev/null &
  started="is installing in the background"
else
  started="is already being installed by an earlier firing of this hook"
fi

say "The render toolchain (R packages from the CI workflows, lintr, TinyTeX, typos) $started; log: $log. Do not render until $done_marker exists: before then, a page with code fails for want of knitr. If the log ends with '== FAILED', fix that step rather than skipping a check. Before rendering, run: $exports"
