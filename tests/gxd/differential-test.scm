;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

;;; Differential test for fallback guix-daemon vs gxd relay.
;;; It runs one client command in two containers and compares results.

(define-module (gxd differential-test)
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
;; Use a deterministic host PATH to find core tools.
(define host-command-path
  "/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin")

(define helper-script-dir
  "tests/gxd/scripts")

(define (helper-script-path name)
  "Return absolute repository-relative helper script path by NAME."
  (string-append helper-script-dir "/" name))

(define (run-shell-script label script . args)
  "Run shell SCRIPT with stable PATH and pass ARGS as `$1`, `$2`, ..."
  (apply system*
         "/bin/sh"
         "-c"
         (string-append "PATH=\"" host-command-path "\"; export PATH; " script)
         label
         args))

(define (run-helper-script! label helper-script . args)
  "Run helper shell script and raise on failure."
  (let ((status (apply run-shell-script
                       label
                       "set -eu
helper=$1
shift
/bin/sh \"$helper\" \"$@\""
                       helper-script
                       args)))
    (unless (= status 0)
      (error (format #f "~a helper failed" label)
             helper-script
             status))))

(define (prepare-artifacts! path)
  "Recreate artifact directory PATH from scratch."
  (run-helper-script! "prepare-artifacts"
                      (helper-script-path "prepare-artifacts.sh")
                      path))

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

(define (ensure-distinct-roots! regular-root relay-root)
  "Fail when both scenarios share the same overlay root."
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
  "Write deterministic filesystem snapshot for ROOT to OUTPUT-FILE."
  (run-helper-script! "snapshot-filesystem"
                      (helper-script-path "snapshot-filesystem.sh")
                      root
                      output-file))

(define (write-diff! before-file after-file diff-file)
  "Write unified diff between BEFORE-FILE and AFTER-FILE into DIFF-FILE."
  (run-helper-script! "write-diff"
                      (helper-script-path "write-diff.sh")
                      before-file
                      after-file
                      diff-file))

(define (run-command-in-container! pid socket-path command stdout-file stderr-file exit-file)
  "Run COMMAND inside container PID with GUIX_DAEMON_SOCKET=SOCKET-PATH."
  (run-helper-script! "run-command-in-container"
                      (helper-script-path "run-command-in-container.sh")
                      pid
                      socket-path
                      command
                      stdout-file
                      stderr-file
                      exit-file))

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
    (mkdir scenario-dir)
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
  "Read GUIX_GD_TEST_* configuration and return an alist."
  (let* ((command (env-ref "GUIX_GD_TEST_COMMAND" "guix gc --list-roots"))
         (artifacts-root (env-ref "GUIX_GD_TEST_ARTIFACTS_DIR"
                                  "tmp/daemon-differential"))
         (expected-exit
          (or (string->number (env-ref "GUIX_GD_TEST_EXPECT_EXIT" "0")) 0))

         (regular-root (env-ref "GUIX_GD_TEST_REGULAR_ROOT"
                                (string-append "/tmp/guix-gd-overlayfs-regular-"
                                               current-user)))
         (regular-pid-env (getenv "GUIX_GD_TEST_REGULAR_CONTAINER_PID"))
         (regular-pid (if (and regular-pid-env
                               (not (string-null? regular-pid-env)))
                          regular-pid-env
                          (read-container-pid "regular" regular-root)))
         (regular-socket (env-ref "GUIX_GD_TEST_REGULAR_SOCKET"
                                  (string-append "/tmp/guix-gd-fallback-regular-"
                                                 current-user
                                                 ".sock")))

         (relay-root (env-ref "GUIX_GD_TEST_RELAY_ROOT"
                              (string-append "/tmp/guix-gd-overlayfs-relay-"
                                             current-user)))
         (relay-pid-env (getenv "GUIX_GD_TEST_RELAY_CONTAINER_PID"))
         (relay-pid (if (and relay-pid-env
                             (not (string-null? relay-pid-env)))
                        relay-pid-env
                        (read-container-pid "relay" relay-root)))
         (relay-socket (env-ref "GUIX_GD_TEST_RELAY_SOCKET"
                                "/var/guix/daemon-socket/socket")))

    (ensure-distinct-roots! regular-root relay-root)

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
    (test "regular daemon and gxd relay behave identically"
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
  "Run suite and return summary; raise on failures and errors."
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
