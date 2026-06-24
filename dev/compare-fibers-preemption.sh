#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CHANNELS="./env/guix/gxd/channels.scm"
PRESERVE='.*LANG.*'

run_case () {
  local title="$1"
  local expr="$2"

  echo "== ${title} =="
  guix time-machine --channels="$CHANNELS" -- \
    shell guile guile-fibers --pure --preserve="$PRESERVE" -- \
    guile -c "$expr"
  local ec=$?
  echo "exit=$ec"
  echo
}

run_case "quick" \
  '(use-modules (fibers))(run-fibers (lambda () #t) #:drain? #t)'

run_case "busy default hz" \
  '(use-modules (fibers))(run-fibers (lambda () (let lp ((i 0)) (if (= i 80000000) #t (lp (+ i 1))))) #:drain? #t)'

run_case "busy hz 0" \
  '(use-modules (fibers))(run-fibers (lambda () (let lp ((i 0)) (if (= i 80000000) #t (lp (+ i 1))))) #:hz 0 #:drain? #t)'

run_case "object-doc default hz" \
  '(use-modules (fibers) (ice-9 documentation))(run-fibers (lambda () (object-documentation +)) #:drain? #t)'

run_case "object-doc hz 0" \
  '(use-modules (fibers) (ice-9 documentation))(run-fibers (lambda () (object-documentation +)) #:hz 0 #:drain? #t)'
