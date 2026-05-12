;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

;;; Differential test for guix-daemon vs guix-gd relay.
;;;
;;; Design summary:
;;; - We run the same Guix client command in TWO separate overlayfs containers.
;;; - Container A talks directly to a regular fallback guix-daemon.
;;; - Container B talks to guix-gd relay (which itself talks to fallback daemon).
;;; - We compare: exit status, stdout, stderr, and filesystem delta.

(define-module (guix-gd daemon differential-test)
  #:use-module (ares suitbl core)
  #:use-module ((ares suitbl runner) #:prefix runner:)
  #:use-module ((ares suitbl reporters) #:prefix reporter:)
  #:use-module ((ares suitbl state) #:prefix state:)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-13)
  #:export (run-daemon-comparison
            daemon-differential-tests
            run-daemon-differential-tests))

(define (assoc-ref alist key)
  "Return the value for KEY in ALIST, or `#f` when KEY is absent."
  (let ((entry (assoc key alist)))
    (and entry (cdr entry))))

(define (env-ref name default)
  "Return environment variable NAME, or DEFAULT when it is unset/empty."
  (let ((value (getenv name)))
    (if (or (not value) (string-null? value))
        default
        value)))

(define (read-file* path)
  "Return full text content of PATH."
  (call-with-input-file path get-string-all))

(define current-user
  (or (getenv "USER") "user"))

;; We run tests from `guix shell --pure`, so PATH is intentionally small.
;; Use a deterministic host PATH to find core tools (`rm`, `find`, `diff`, etc.).
(define host-command-path
  "/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin")

(define (first-existing-path . candidates)
  "Return the first existing path from CANDIDATES, or `#f` if none exist."
  (let loop ((rest candidates))
    (and (pair? rest)
         (let ((path (car rest)))
           (if (file-exists? path)
               path
               (loop (cdr rest)))))))

(define nsenter-bin
  (or (first-existing-path "/run/current-system/profile/bin/nsenter"
                           "/usr/bin/nsenter"
                           "/bin/nsenter")
      "nsenter"))

(define env-bin
  (or (first-existing-path "/run/current-system/profile/bin/env"
                           "/usr/bin/env"
                           "/bin/env")
      "env"))

(define (run-shell-script label script . args)
  "Run shell SCRIPT with stable PATH and pass ARGS as `$1`, `$2`, ...

LABEL becomes `$0` inside the script and improves shell diagnostics."
  (apply system*
         "/bin/sh"
         "-c"
         (string-append "PATH=\"" host-command-path "\"; export PATH; " script)
         label
         args))

(define (mkdir-p! path)
  "Create PATH recursively (`mkdir -p`)."
  (let ((status (run-shell-script "mkdir-p"
                                  "set -eu; dir=$1; mkdir -p \"$dir\""
                                  path)))
    (unless (= status 0)
      (error "mkdir -p failed" path status))))

(define (prepare-artifacts! path)
  "Recreate artifact directory PATH from scratch."
  (let ((status (run-shell-script "prepare-artifacts"
                                  "set -eu; dir=$1; rm -rf \"$dir\"; mkdir -p \"$dir\""
                                  path)))
    (unless (= status 0)
      (error "artifact dir preparation failed" path status))))

(define (pid-file-path root)
  "Return overlay container pid-file path for ROOT."
  (string-append root "/overlayfs-container.pid"))

(define (read-container-pid label root)
  "Read and validate container PID for LABEL from ROOT/overlayfs-container.pid."
  (let ((pid-file (pid-file-path root)))
    (unless (file-exists? pid-file)
      (error (format #f "~a container pid file missing; run `make container/~a/start`"
                     label label)
             pid-file))
    (let* ((raw (string-trim-both (read-file* pid-file)))
           (pid (string->number raw)))
      (unless pid
        (error "container pid is not a number" label raw pid-file))
      raw)))

(define (ensure-path-exists! label path hint)
  "Ensure PATH exists, otherwise raise an error with HINT."
  (unless (file-exists? path)
    (error (format #f "~a does not exist; ~a" label hint) path)))

(define (ensure-distinct-roots! regular-root relay-root)
  "Ensure regular and relay tests use different overlay roots.

Using separate roots keeps filesystem side effects isolated and removes
any need for reset hooks between scenarios."
  (when (string=? regular-root relay-root)
    (error "regular and relay roots must differ" regular-root relay-root)))

(define (read-exit-code path)
  "Read integer process exit code from PATH."
  (let* ((raw (string-trim-both (read-file* path)))
         (value (string->number raw)))
    (unless value
      (error "invalid exit code" raw path))
    value))

(define (snapshot-filesystem! root output-file)
  "Write deterministic filesystem snapshot for ROOT to OUTPUT-FILE.

We capture metadata from three mutable areas used by this test harness:
  - ROOT/gnu/store-upper
  - ROOT/var/guix
  - ROOT/etc/guix

Important: we normalize paths to be relative to ROOT, so snapshots from
`/tmp/guix-gd-overlayfs-regular-<user>` and `/tmp/guix-gd-overlayfs-relay-<user>` can be compared
without false differences caused by different absolute prefixes."
  (let ((status
         (system* "/bin/sh"
                  "-c"
                  (string-append
                   "PATH=\"" host-command-path "\"; export PATH; "
                   "set -eu
out=$1
root=$2
tmp=\"$out.tmp\"
: > \"$tmp\"
for d in \"$root/gnu/store-upper\" \"$root/var/guix\" \"$root/etc/guix\"; do
  if [ -e \"$d\" ]; then
    find \"$d\" -printf '%p|%y|%m|%s|%l\\n' >> \"$tmp\"
  fi
done
while IFS= read -r line; do
  path=${line%%|*}
  rest=${line#*|}
  rel=${path#\"$root\"/}
  printf '%s|%s\\n' \"$rel\" \"$rest\"
done < \"$tmp\" | LC_ALL=C sort > \"$out\"
rm -f \"$tmp\"")
                  "snapshot-filesystem"
                  output-file
                  root)))
    (unless (= status 0)
      (error "filesystem snapshot failed" output-file status))))

(define (write-diff! before-file after-file diff-file)
  "Write unified diff between BEFORE-FILE and AFTER-FILE into DIFF-FILE.

`diff` returns 1 on differences; this is expected and not an error here."
  (let ((status (run-shell-script "write-diff"
                                  "set -eu
before=$1
after=$2
diff_file=$3
diff -u \"$before\" \"$after\" > \"$diff_file\" || true"
                                  before-file
                                  after-file
                                  diff-file)))
    (unless (= status 0)
      (error "diff generation failed" diff-file status))))

(define (run-command-in-container! pid socket-path command stdout-file stderr-file exit-file)
  "Run COMMAND inside container PID using GUIX_DAEMON_SOCKET=SOCKET-PATH.

The command's stdout, stderr, and exit code are persisted in files so test
reports remain inspectable even after failures."
  (let* ((script (format #f
                         "set -eu
pid=$1
socket=$2
cmd=$3
stdout_file=$4
stderr_file=$5
exit_file=$6
rc=0
~a --target \"$pid\" --user --mount --preserve-credentials -- ~a GUIX_DAEMON_SOCKET=\"$socket\" \\
     /bin/sh -lc \"$cmd\" >\"$stdout_file\" 2>\"$stderr_file\" || rc=$?
printf '%s\\n' \"$rc\" > \"$exit_file\""
                         nsenter-bin
                         env-bin))
         (status (run-shell-script "run-command-in-container"
                                   script
                                   pid
                                   socket-path
                                   command
                                   stdout-file
                                   stderr-file
                                   exit-file)))
    (unless (= status 0)
      (error "command wrapper failed" command status))))

(define (run-scenario! scenario command artifacts-root)
  "Run one scenario and return collected artifacts as an alist.

SCENARIO keys:
  - name
  - root
  - container-pid
  - daemon-socket (path visible from inside container)"
  (let* ((name (assoc-ref scenario 'name))
         (root (assoc-ref scenario 'root))
         (pid (assoc-ref scenario 'container-pid))
         (socket (assoc-ref scenario 'daemon-socket))
         (scenario-dir (string-append artifacts-root "/" name))
         (fs-before-file (string-append scenario-dir "/fs-before.txt"))
         (fs-after-file (string-append scenario-dir "/fs-after.txt"))
         (fs-diff-file (string-append scenario-dir "/fs-diff.txt"))
         (stdout-file (string-append scenario-dir "/stdout.txt"))
         (stderr-file (string-append scenario-dir "/stderr.txt"))
         (exit-file (string-append scenario-dir "/exit-code.txt")))
    (mkdir-p! scenario-dir)
    (snapshot-filesystem! root fs-before-file)
    (run-command-in-container! pid socket command stdout-file stderr-file exit-file)
    (snapshot-filesystem! root fs-after-file)
    (write-diff! fs-before-file fs-after-file fs-diff-file)
    `((name . ,name)
      (root . ,root)
      (container-pid . ,pid)
      (daemon-socket . ,socket)
      (stdout . ,(read-file* stdout-file))
      (stderr . ,(read-file* stderr-file))
      (exit-code . ,(read-exit-code exit-file))
      (fs-diff . ,(read-file* fs-diff-file))
      (dir . ,scenario-dir))))

(define (write-report! path config regular relay)
  "Write human-readable comparison report to PATH."
  (call-with-output-file
      path
    (lambda (port)
      (format port "command: ~a~%" (assoc-ref config 'command))
      (format port "expected-exit: ~a~%~%" (assoc-ref config 'expected-exit))
      (format port "regular.root: ~a~%" (assoc-ref regular 'root))
      (format port "relay.root: ~a~%~%" (assoc-ref relay 'root))
      (format port "regular.exit: ~a~%" (assoc-ref regular 'exit-code))
      (format port "relay.exit: ~a~%" (assoc-ref relay 'exit-code))
      (format port "stdout.equal?: ~a~%"
              (string=? (assoc-ref regular 'stdout)
                        (assoc-ref relay 'stdout)))
      (format port "stderr.equal?: ~a~%"
              (string=? (assoc-ref regular 'stderr)
                        (assoc-ref relay 'stderr)))
      (format port "fs-diff.equal?: ~a~%"
              (string=? (assoc-ref regular 'fs-diff)
                        (assoc-ref relay 'fs-diff)))
      (format port "regular.artifacts: ~a~%" (assoc-ref regular 'dir))
      (format port "relay.artifacts: ~a~%" (assoc-ref relay 'dir)))))

(define (comparison-config)
  "Read environment configuration, validate prerequisites, and return alist.

Environment variables:

General:
  GUIX_GD_TEST_COMMAND
  GUIX_GD_TEST_ARTIFACTS_DIR
  GUIX_GD_TEST_EXPECT_EXIT

Regular scenario (direct fallback daemon):
  GUIX_GD_TEST_REGULAR_ROOT
  GUIX_GD_TEST_REGULAR_CONTAINER_PID
  GUIX_GD_TEST_REGULAR_SOCKET

Relay scenario (guix-gd -> fallback):
  GUIX_GD_TEST_RELAY_ROOT
  GUIX_GD_TEST_RELAY_CONTAINER_PID
  GUIX_GD_TEST_RELAY_SOCKET            (inside container)
  GUIX_GD_TEST_RELAY_SOCKET_HOST       (host-visible socket path)
  GUIX_GD_TEST_RELAY_FALLBACK_SOCKET   (host-visible fallback socket)
"
  (let* ((command (env-ref "GUIX_GD_TEST_COMMAND" "guix gc --list-roots"))
         (artifacts-root (env-ref "GUIX_GD_TEST_ARTIFACTS_DIR"
                                  "tmp/daemon-differential"))
         (expected-exit
          (or (string->number (env-ref "GUIX_GD_TEST_EXPECT_EXIT" "0")) 0))

         (regular-root (env-ref "GUIX_GD_TEST_REGULAR_ROOT"
                                (string-append "/tmp/guix-gd-overlayfs-regular-"
                                               current-user)))
         (regular-pid-env (getenv "GUIX_GD_TEST_REGULAR_CONTAINER_PID"))
         (regular-pid (if (or (not regular-pid-env)
                              (string-null? regular-pid-env))
                          (read-container-pid "regular" regular-root)
                          regular-pid-env))
         (regular-socket (env-ref "GUIX_GD_TEST_REGULAR_SOCKET"
                                  (string-append "/tmp/guix-gd-fallback-regular-"
                                                 current-user
                                                 ".sock")))

         (relay-root (env-ref "GUIX_GD_TEST_RELAY_ROOT"
                              (string-append "/tmp/guix-gd-overlayfs-relay-"
                                             current-user)))
         (relay-pid-env (getenv "GUIX_GD_TEST_RELAY_CONTAINER_PID"))
         (relay-pid (if (or (not relay-pid-env)
                            (string-null? relay-pid-env))
                        (read-container-pid "relay" relay-root)
                        relay-pid-env))
         (relay-socket (env-ref "GUIX_GD_TEST_RELAY_SOCKET"
                                "/var/guix/daemon-socket/socket"))
         ;; The relay socket is inside the relay container as /var/guix/...,
         ;; but from the host we can validate it via relay root path.
         (relay-socket-host (env-ref "GUIX_GD_TEST_RELAY_SOCKET_HOST"
                                     (string-append relay-root
                                                    "/var/guix/daemon-socket/socket")))
         (relay-fallback-socket
          (env-ref "GUIX_GD_TEST_RELAY_FALLBACK_SOCKET"
                   (string-append "/tmp/guix-gd-fallback-relay-"
                                  current-user
                                  ".sock"))))

    (ensure-distinct-roots! regular-root relay-root)

    (ensure-path-exists! "regular daemon socket"
                         regular-socket
                         "run `make daemon-fallback/regular/start`")

    (ensure-path-exists! "relay daemon socket"
                         relay-socket-host
                         "run `make daemon/relay/start`")

    (ensure-path-exists! "relay fallback daemon socket"
                         relay-fallback-socket
                         "run `make daemon-fallback/relay/start`")

    `((command . ,command)
      (artifacts-root . ,artifacts-root)
      (expected-exit . ,expected-exit)
      (regular . ((name . "regular")
                  (root . ,regular-root)
                  (container-pid . ,regular-pid)
                  (daemon-socket . ,regular-socket)))
      (relay . ((name . "relay")
                (root . ,relay-root)
                (container-pid . ,relay-pid)
                (daemon-socket . ,relay-socket))))))

(define (run-daemon-comparison)
  "Run full two-container differential comparison and return result alist."
  (let* ((config (comparison-config))
         (artifacts-root (assoc-ref config 'artifacts-root))
         (report-file (string-append artifacts-root "/report.txt"))
         (command (assoc-ref config 'command)))
    (prepare-artifacts! artifacts-root)
    (let* ((regular (run-scenario! (assoc-ref config 'regular)
                                   command
                                   artifacts-root))
           (relay (run-scenario! (assoc-ref config 'relay)
                                 command
                                 artifacts-root)))
      (write-report! report-file config regular relay)
      `((config . ,config)
        (regular . ,regular)
        (relay . ,relay)
        (report-file . ,report-file)))))

(define-suite daemon-differential-tests
  (suite "guix daemon differential (two containers)"
    (test "regular daemon and guix-gd relay behave identically"
      (let* ((result (run-daemon-comparison))
             (config (assoc-ref result 'config))
             (regular (assoc-ref result 'regular))
             (relay (assoc-ref result 'relay)))
        (is (= (assoc-ref config 'expected-exit)
               (assoc-ref regular 'exit-code)))
        (is (= (assoc-ref regular 'exit-code)
               (assoc-ref relay 'exit-code)))
        (is (string=? (assoc-ref regular 'stdout)
                      (assoc-ref relay 'stdout)))
        (is (string=? (assoc-ref regular 'stderr)
                      (assoc-ref relay 'stderr)))
        (is (string=? (assoc-ref regular 'fs-diff)
                      (assoc-ref relay 'fs-diff)))))))

(define default-summary
  '((tests . 0)
    (failures . 0)
    (errors . 0)
    (skipped . 0)
    (assertions . 0)))

(define (run-daemon-differential-tests)
  "Run suitbl tests and return run summary.

`re-raise?` is enabled so runtime exceptions preserve full backtraces."
  (let ((runner-instance
         (runner:make-suitbl
          #:config `((test-reporter . ,reporter:silent)
                     (auto-run? . #t)
                     (re-raise? . #t)))))
    (with-test-runner
     runner-instance
     (daemon-differential-tests)
     (let* ((state (runner:get-state runner-instance))
            (summary (or (state:get-run-summary state)
                         default-summary)))
       (when (or (> (or (assoc-ref summary 'failures) 0) 0)
                 (> (or (assoc-ref summary 'errors) 0) 0))
         (error "daemon differential test failed" summary))
       summary))))
