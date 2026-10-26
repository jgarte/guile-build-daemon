;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build sandbox)
  #:use-module (gxd prelude)
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((gxd isolation)
                #:select (bind-mount! bind-mount-read-only! child-proc
                                      make-mounts-private! pivot-into!
                                      write-self-id-maps! CLONE_NEWUSER CLONE_NEWNS))
  #:use-module ((gnu build accounts)
                #:select (password-entry group-entry write-passwd write-group))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((guix build syscalls) #:select (mount umount unshare set-network-interface-up))
  #:use-module ((ice-9 exceptions) #:select (exception-kind exception-args))
  #:use-module ((ice-9 match) #:select (match-lambda match-let))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (sandbox-config sandbox-root sandbox-input-paths sandbox-build-directory
                           call-with-build-sandbox
                           prepare-sandbox-root! mount-build-inputs! mount-build-devices!
                           enter-sandbox-filesystem! lock-build-mounts!))

(define-record-type <sandbox-config>
  (sandbox-config root input-paths build-directory)
  sandbox-config?
  (root sandbox-root)
  (input-paths sandbox-input-paths)
  (build-directory sandbox-build-directory))

(define (write-root-file sandbox-root name contents)
  (define port (open-output-file (string-append sandbox-root name)))
  (call-with-cleanup
   (lambda () (close-port port))
   (lambda () (display contents port))))

(define (prepare-sandbox-root! sandbox-root store-directory uid gid)
  "Populate fresh SANDBOX-ROOT for an ordinary build by UID and GID.
Create writable /tmp and STORE-DIRECTORY, account and localhost files.
The caller owns SANDBOX-ROOT and its cleanup; no mounts are established."
  (define root-tmp (string-append sandbox-root "/tmp"))
  (define root-store (string-append sandbox-root store-directory))

  (mkdir-p root-tmp)
  (chmod root-tmp #o1777)

  (mkdir-p (string-append sandbox-root "/etc"))

  (write-passwd
   (list (password-entry
          (name "nixbld")
          (uid uid)
          (gid gid)
          (real-name "Nix build user")
          (directory "/")
          (shell "/noshell"))
         (password-entry
          (name "nobody")
          (uid 65534)
          (gid 65534)
          (real-name "Nobody")
          (directory "/")
          (shell "/noshell")))
   (string-append sandbox-root "/etc/passwd"))

  (write-group
   (list (group-entry
          (name "nixbld")
          (password "!")
          (gid gid)))
   (string-append sandbox-root "/etc/group"))

  (write-root-file sandbox-root "/etc/hosts" "127.0.0.1 localhost\n::1 localhost\n")

  (mkdir-p root-store)
  (chmod root-store #o1775))

(define (call-with-build-sandbox drv-path store-directory input-paths uid gid proc)
  "Call PROC with the sandbox-config of a prepared sandbox for DRV-PATH.
Create its root beneath DRV-PATH.chroot on the store filesystem, with a private
STORE-DIRECTORY and account files for UID and GID.  Return PROC's values and
remove the chroot directory on return or exception.  INPUT-PATHS are realized.
The caller holds the output locks and ensures sandbox processes have terminated
before PROC returns or raises."
  (define chroot-directory (string-append drv-path ".chroot"))
  (define root-directory (string-append chroot-directory "/top"))
  (define build-directory (string-append "/tmp/guix-build-" (basename drv-path) "-0"))

  (delete-path! chroot-directory)
  (mkdir chroot-directory #o750)
  (call-with-cleanup
   (lambda () (delete-path! chroot-directory))
   (lambda ()
     (mkdir root-directory #o750)
     (prepare-sandbox-root! root-directory store-directory uid gid)
     (proc (sandbox-config root-directory input-paths build-directory)))))

(define (mount-build-inputs! sandbox-root input-paths)
  "Expose INPUT-PATHS read-only at their original paths beneath SANDBOX-ROOT.
SANDBOX-ROOT is the prepared host-side sandbox directory.  INPUT-PATHS is the
realized input closure, and mounts are private to the caller."
  (for-each (lambda (path)
              (bind-mount-read-only! path (string-append sandbox-root path)))
            input-paths))

(define (mount-build-devices! sandbox-root)
  "Install ordinary build devices beneath SANDBOX-ROOT in the caller's private mounts.
Bind available standard devices and mount private shared memory and, when
supported by the host, pseudo-terminals.  SANDBOX-ROOT is freshly prepared."
  (define dev (string-append sandbox-root "/dev"))
  (define shm (string-append dev "/shm"))
  (define pts (string-append dev "/pts"))

  ;; Expose selected host devices, not the host's entire /dev.
  (mkdir-p dev)
  (for-each
   (lambda (device)
     (when (file-exists? device)
       (bind-mount! device (string-append sandbox-root device))))
   '("/dev/full" "/dev/null" "/dev/random" "/dev/tty" "/dev/urandom" "/dev/zero"))

  ;; Resolve descriptor links through the builder's procfs.
  (for-each
   (match-lambda
     ((name . target) (symlink target (string-append dev "/" name))))
   '(("fd" . "/proc/self/fd")
     ("stdin" . "/proc/self/fd/0")
     ("stdout" . "/proc/self/fd/1")
     ("stderr" . "/proc/self/fd/2")))

  ;; Give builds private shared-memory storage.
  (mkdir-p shm)
  (mount "none" shm "tmpfs")

  ;; Allocate pseudo-terminals independently of the host's devpts instance.
  (when (file-exists? "/dev/pts/ptmx")
    (mkdir-p pts)
    (mount "none" pts "devpts" 0 "newinstance,mode=0620")
    (symlink "/dev/pts/ptmx" (string-append dev "/ptmx"))
    (chmod (string-append pts "/ptmx") #o666)))

(define (enter-sandbox-filesystem! sandbox build-directory)
  "Enter SANDBOX's prepared root, detaching the old root.
Populate its private store with read-only mounts of SANDBOX's input paths, expose
host workspace BUILD-DIRECTORY at its sandbox build directory, and install build
devices and procfs.  The caller has private user, mount, PID and network namespaces."
  (define root-directory (sandbox-root sandbox))

  (make-mounts-private!)
  (set-network-interface-up "lo") ;; Allow sandbox-local connections, not external access.
  (sethostname "localhost")
  (bind-mount! build-directory (string-append root-directory (sandbox-build-directory sandbox)))
  (mount-build-inputs! root-directory (sandbox-input-paths sandbox))
  (mount-build-devices! root-directory)
  (pivot-into! root-directory)
  (chmod "/" #o555))

(define (lock-build-mounts!)
  "Enter user and mount namespaces that lock the inherited build mounts.
Preserve the caller's UID and GID.  Call after pivoting into the build filesystem
and closing unwanted descriptors, before executing the builder."
  (define owner (getpid))
  (define uid (getuid))
  (define gid (getgid))

  ;; The helper retains authority in the preceding user namespace to write maps.
  (match-let (((pid => <= disconnect!)
               (child-proc
                SIGCHLD
                (lambda (=> <=)
                  (<= 'namespace-ready)
                  (write-self-id-maps! owner uid gid)
                  (=> 'ids-mapped)))))
    (define waited? #f)
    (call-with-cleanup
     (lambda ()
       (call-with-cleanup
        disconnect!
        (lambda ()
          (unless waited?
            (false-if-exception (kill pid SIGKILL))
            (waitpid pid)))))
     (lambda ()
       (unshare (logior CLONE_NEWUSER CLONE_NEWNS))
       (=> 'namespace-ready)
       (<= 'ids-mapped)
       (define status (cdr (waitpid pid)))
       (set! waited? #t)
       (unless (zero? status)
         (error "identity-map helper failed" status)))))

  ;; Like nixd, require inherited mounts to be locked together before exec.
  (define locked?
    (with-exception-handler
      (lambda (exception)
        (if (and (eq? 'system-error (exception-kind exception))
                 (= EINVAL (system-error-errno
                            (cons (exception-kind exception) (exception-args exception)))))
            #t
            (raise-exception exception)))
      (lambda () (umount "/proc") #f)
      #:unwind? #t))

  (unless locked? (error "build mounts are not locked")))
