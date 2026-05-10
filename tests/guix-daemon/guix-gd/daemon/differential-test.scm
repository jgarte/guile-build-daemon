;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

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
  (let ((entry (assoc key alist)))
    (and entry (cdr entry))))

(define (env-ref name default)
  (let ((value (getenv name)))
    (if (or (not value) (string-null? value))
        default
        value)))

(define (read-file* path)
  (call-with-input-file path get-string-all))

(define host-command-path
  "/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin")

(define (first-existing-path . candidates)
  (let loop ((rest candidates))
    (and (pair? rest)
         (let ((path (car rest)))
           (if (file-exists? path)
               path
               (loop (cdr rest)))))))

(define sudo-bin
  (or (first-existing-path "/run/setuid-programs/sudo"
                           "/usr/bin/sudo"
                           "/bin/sudo")
      "sudo"))

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
  (apply system*
         "/bin/sh"
         "-c"
         (string-append "PATH=\"" host-command-path "\"; export PATH; " script)
         label
         args))

(define (write-report! path config regular relay)
  (call-with-output-file
      path
    (lambda (port)
      (format port "command: ~a~%" (assoc-ref config 'command))
      (format port "container-pid: ~a~%" (assoc-ref config 'container-pid))
      (format port "fallback-socket: ~a~%" (assoc-ref config 'fallback-socket))
      (format port "relay-socket: ~a~%" (assoc-ref config 'relay-socket))
      (format port "expected-exit: ~a~%~%" (assoc-ref config 'expected-exit))
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
                        (assoc-ref relay 'fs-diff))))))

(define (mkdir-p! path)
  (let ((status (run-shell-script "mkdir-p"
                                  "set -eu; dir=$1; mkdir -p \"$dir\""
                                  path)))
    (unless (= status 0)
      (error "mkdir -p failed" path status))))

(define (prepare-artifacts! path)
  (let ((status (run-shell-script "prepare-artifacts"
                                  "set -eu; dir=$1; rm -rf \"$dir\"; mkdir -p \"$dir\""
                                  path)))
    (unless (= status 0)
      (error "artifact dir preparation failed" path status))))

(define (snapshot-filesystem! dev-root output-file)
  (let ((status
         (system* sudo-bin
                  "/bin/sh"
                  "-c"
                  (string-append
                   "PATH=\"" host-command-path "\"; export PATH; "
                   "set -eu
out=$1
root=$2
: > \"$out\"
for d in \"$root/gnu/store-upper\" \"$root/var/guix\" \"$root/etc/guix\"; do
  if [ -e \"$d\" ]; then
    find \"$d\" -printf '%p|%y|%m|%s|%l\\n'
  fi
done | LC_ALL=C sort > \"$out\"")
                  "snapshot-filesystem"
                  output-file
                  dev-root)))
    (unless (= status 0)
      (error "filesystem snapshot failed" output-file status))))

(define (run-command-in-container! pid socket-path command stdout-file stderr-file exit-file)
  (let* ((script (format #f
                         "set -eu
pid=$1
socket=$2
cmd=$3
stdout_file=$4
stderr_file=$5
exit_file=$6
rc=0
~a ~a --target \"$pid\" --all -- ~a GUIX_DAEMON_SOCKET=\"$socket\" \\
     /bin/sh -lc \"$cmd\" >\"$stdout_file\" 2>\"$stderr_file\" || rc=$?
printf '%s\\n' \"$rc\" > \"$exit_file\""
                         sudo-bin
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

(define (write-diff! before-file after-file diff-file)
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

(define (run-reset-command! pid reset-command)
  (unless (string-null? reset-command)
    (let* ((script (format #f
                           "set -eu
pid=$1
cmd=$2
~a ~a --target \"$pid\" --all -- /bin/sh -lc \"$cmd\""
                           sudo-bin
                           nsenter-bin))
           (status (run-shell-script "run-reset-command"
                                     script
                                     pid
                                     reset-command)))
      (unless (= status 0)
        (error "reset command failed" reset-command status)))))

(define (read-container-pid dev-root)
  (let ((pid-file (string-append dev-root "/overlayfs-container.pid")))
    (unless (file-exists? pid-file)
      (error "container pid file does not exist; run `make container/start`"
             pid-file))
    (let* ((raw (string-trim-both (read-file* pid-file)))
           (pid (string->number raw)))
      (unless pid
        (error "container pid is not a number" raw))
      raw)))

(define (ensure-path-exists! label path hint)
  (unless (file-exists? path)
    (error (format #f "~a does not exist; ~a" label hint) path)))

(define (read-exit-code path)
  (let* ((raw (string-trim-both (read-file* path)))
         (value (string->number raw)))
    (unless value
      (error "invalid exit code" raw path))
    value))

(define (ensure-sudo-ready!)
  (let ((status (system* sudo-bin "-v")))
    (unless (= status 0)
      (error "sudo authentication failed; run `sudo -v` and retry" status))))

(define (run-scenario! label config)
  (let* ((artifacts-root (assoc-ref config 'artifacts-root))
         (scenario-dir (string-append artifacts-root "/" label))
         (fs-before-file (string-append scenario-dir "/fs-before.txt"))
         (fs-after-file (string-append scenario-dir "/fs-after.txt"))
         (fs-diff-file (string-append scenario-dir "/fs-diff.txt"))
         (stdout-file (string-append scenario-dir "/stdout.txt"))
         (stderr-file (string-append scenario-dir "/stderr.txt"))
         (exit-file (string-append scenario-dir "/exit-code.txt")))
    (mkdir-p! scenario-dir)
    (snapshot-filesystem! (assoc-ref config 'dev-root) fs-before-file)
    (run-command-in-container! (assoc-ref config 'container-pid)
                               (assoc-ref config (string->symbol (string-append label "-socket")))
                               (assoc-ref config 'command)
                               stdout-file
                               stderr-file
                               exit-file)
    (snapshot-filesystem! (assoc-ref config 'dev-root) fs-after-file)
    (write-diff! fs-before-file fs-after-file fs-diff-file)
    `((label . ,label)
      (stdout . ,(read-file* stdout-file))
      (stderr . ,(read-file* stderr-file))
      (exit-code . ,(read-exit-code exit-file))
      (fs-diff . ,(read-file* fs-diff-file))
      (dir . ,scenario-dir))))

(define (comparison-config)
  (let* ((dev-root (env-ref "GUIX_GD_DEV_ROOT" "/guix-gd-overlayfs"))
         (container-pid-env (getenv "GUIX_GD_TEST_CONTAINER_PID"))
         (container-pid (if (or (not container-pid-env)
                                (string-null? container-pid-env))
                            (read-container-pid dev-root)
                            container-pid-env))
         (command (env-ref "GUIX_GD_TEST_COMMAND" "guix gc --list-roots"))
         (fallback-socket (env-ref "GUIX_GD_TEST_FALLBACK_SOCKET"
                                   "/tmp/guix-gd-fallback.sock"))
         (relay-socket (env-ref "GUIX_GD_TEST_RELAY_SOCKET"
                                "/var/guix/daemon-socket/socket"))
         (artifacts-root (env-ref "GUIX_GD_TEST_ARTIFACTS_DIR"
                                  "tmp/daemon-differential"))
         (expected-exit
          (or (string->number (env-ref "GUIX_GD_TEST_EXPECT_EXIT" "0")) 0))
         (reset-command (env-ref "GUIX_GD_TEST_RESET_COMMAND" "")))
    (ensure-path-exists! "fallback daemon socket"
                         fallback-socket
                         "run `make daemon-fallback/start`")
    (ensure-path-exists! "relay daemon socket"
                         relay-socket
                         "run `make daemon/start`")
    `((dev-root . ,dev-root)
      (container-pid . ,container-pid)
      (command . ,command)
      (fallback-socket . ,fallback-socket)
      (relay-socket . ,relay-socket)
      (regular-socket . ,fallback-socket)
      (artifacts-root . ,artifacts-root)
      (expected-exit . ,expected-exit)
      (reset-command . ,reset-command))))

(define (run-daemon-comparison)
  (let* ((config (comparison-config))
         (artifacts-root (assoc-ref config 'artifacts-root))
         (report-file (string-append artifacts-root "/report.txt")))
    (ensure-sudo-ready!)
    (prepare-artifacts! artifacts-root)
    (let* ((regular (run-scenario! "regular" config))
           (_ (run-reset-command! (assoc-ref config 'container-pid)
                                  (assoc-ref config 'reset-command)))
           (relay (run-scenario! "relay" config)))
      (write-report! report-file config regular relay)
      `((config . ,config)
        (regular . ,regular)
        (relay . ,relay)
        (report-file . ,report-file)))))

(define-suite daemon-differential-tests
  (suite "guix daemon differential"
    (test "fallback daemon and guix-gd relay match"
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

(define (run-daemon-differential-tests)
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
                         '((tests . 0)
                           (failures . 0)
                           (errors . 0)
                           (skipped . 0)
                           (assertions . 0)))))
       (when (> (or (assoc-ref summary 'failures) 0) 0)
         (error "daemon differential test assertions failed" summary))
       summary))))
