;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(use-modules ((gxd testbox-relay server) #:select (run-relay)))

;; One process owns the listener and all connection workers until testbox teardown.
;; Listen -> connect observation (ready) -> accept -> forward both halves -> terminal.
(let ((arguments (command-line)))
  (unless (= 4 (length arguments))
    (error "usage: guix repl -- relay.scm RELAY-SOCKET DAEMON-SOCKET OBSERVATION-SOCKET"))
  (run-relay (cadr arguments) (caddr arguments) (cadddr arguments)))
