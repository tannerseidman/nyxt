;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(hooks:define-hook-type minibuffer (function (minibuffer)))
(hooks:define-hook-type download (function (download-manager:download)))

(hooks:define-hook-type resource (function (request-data) (or request-data null)))
(export-always '(make-hook-resource make-handler-resource))

(define-class proxy ()
  ((server-address (quri:uri "socks5://127.0.0.1:9050")
                   :documentation "The address of the proxy server.
It's made of three components: protocol, host and port.
Example: \"http://192.168.1.254:8080\".")
   (allowlist '("localhost" "localhost:8080")
              :type list-of-strings
              :documentation "A list of URIs not to forward to the proxy.")
   (proxied-downloads-p t
                        :documentation "Non-nil if downloads should also use the proxy."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer #'class*:name-identity)
  (:documentation "Enable forwarding of all network requests to a specific host.
This can apply to specific buffer."))

(export-always 'combine-composed-hook-until-nil)
(defmethod combine-composed-hook-until-nil ((hook hooks:hook) &optional arg)
  "Return the result of the composition of the HOOK handlers on ARG, from
oldest to youngest.  Stop processsing when a handler returns nil.
Without handler, return ARG.  This is an acceptable `combination' for
`hook'."
  (labels ((compose-handlers (handlers result)
             (if handlers
                 (let ((new-result (funcall (first handlers) result)))
                   (when new-result
                     (compose-handlers (rest handlers) new-result)))
                 result)))
    (compose-handlers (mapcar #'hooks:fn (hooks:handlers hook)) arg)))

(define-class browser ()
  ((remote-execution-p nil
                       :type boolean
                       :documentation "When non-nil, execute Lisp code that is sent to the socket.
You must understand the risks before enabling this: a privliged user with access
to your system can then take control of the browser and execute arbitrary code
under your user profile.")
;; TODO: is it always user's data? Better name maybe?
   (user-data-cache (make-hash-table :test #'equal)
                    :type hash-table
                    :documentation "Table that maps the expanded `data-path's to the `user-data' (possibly) stored there.")
   (socket-thread nil                   ; TODO: Unexport?
                  :type t
                  :documentation "Thread that listens on socket.
See `*socket-path*'.
This slot is mostly meant to clean up the thread if necessary.")
   (password-interface (password:make)
                       :export nil)
   (messages-content '()
                     :export nil
                     :documentation "A list of all echoed messages.
Most recent messages are first.")
   (clipboard-ring (make-ring)
                   :export nil)
   (minibuffer-generic-history (make-ring))
   (minibuffer-search-history (make-ring))
   (minibuffer-set-url-history (make-ring))
   (minibuffer-session-restore-history (make-ring))
   (recent-buffers (make-ring :size 50)
                   :export nil
                   :documentation "A ring that keeps track of deleted buffers.")
   (focus-on-reopened-buffer-p t ; TODO: Replace this with minibuffer Helm-style actions.
                               :documentation "When reopening a closed buffer,
focus on it instead of opening it in the background.

Warning: This setting may be deprecated in a future release, don't rely on it.")
   (windows (make-hash-table :test #'equal)
            :export nil)
   (total-window-count 0
                       :export nil
                       :documentation "This is used to generate unique window
identifiers in `get-unique-window-identifier'.  We can't rely on the windows
count since deleting windows may reseult in duplicate identifiers.")
   (last-active-window nil
                       :type (or window null)
                       :export nil
                       :documentation "Records the last active window.  This is
useful when no Nyxt window is focused and we still want `ffi-window-active' to
return something.
See `current-window' for the user-facing function.")
   (buffers :initform (make-hash-table :test #'equal)
            :documentation "To manipulate the list of buffers,
see `buffer-list', `buffers-get', `buffers-set' and `buffers-delete'.")
   (total-buffer-count 0
                       :export nil
                       :documentation "This is used to generate unique buffer
identifiers in `get-unique-buffer-identifier'.  We can't rely on the windows
count since deleting windows may result in duplicate identifiers.")
   (startup-function (make-startup-function)
                     :type (or function null)
                     :documentation "The function run on startup.  It takes a
list of URLs (strings) as optional argument (the command line positional
arguments).  It is run after the renderer has been initialized and after the
`*after-init-hook*' has run.")
   (startup-error-reporter-function nil
                                    :type (or function null)
                                    :export nil
                                    :documentation "When supplied, upon startup,
if there are errors, they will be reported by this function.")
   (open-external-link-in-new-window-p nil
                                       :documentation "When open links from an external program, or
when C-cliking on a URL, decide whether to open in a new
window or not.")
   (download-watcher nil
                     :type t
                     :export nil
                     :documentation "List of downloads.")
   (startup-timestamp (local-time:now)
                      :export nil
                      :documentation "`local-time:timestamp' of when Nyxt was started.")
   (init-time 0.0
              :export nil
              :documentation "Init time in seconds.")
   (session-restore-prompt :always-ask
                           :documentation "Ask whether to restore the
session. Possible values are :always-ask :always-restore :never-restore.")
   ;; Hooks follow:
   (before-exit-hook (hooks:make-hook-void)
                     :type hooks:hook-void
                     :documentation "Hook run before both `*browser*' and the
renderer get terminated.  The handlers take no argument.")
   (window-make-hook (make-hook-window)
                     :type hook-window
                     :documentation "Hook run after `window-make'.
The handlers take the window as argument.")
   (buffer-make-hook (make-hook-buffer)
                     :type hook-buffer
                     :documentation "Hook run after `buffer-make' and before `ffi-buffer-load'.
It is run before `initialize-modes' so that the default mode list can still be
altered from the hooks.
The handlers take the buffer as argument.")
   (buffer-before-make-hook (make-hook-buffer)
                            :type hook-buffer
                            :documentation "Hook run before `buffer-make'.
This hook is mostly useful to set the `cookies-path'.
The buffer web view is not allocated, so it's not possible to run any
parenscript from this hook.  See `buffer-make-hook' for a hook.
The handlers take the buffer as argument.")
   (minibuffer-make-hook (make-hook-minibuffer)
                         :type hook-minibuffer
                         :documentation "Hook run after the `minibuffer' class
is instantiated and before initializing the minibuffer modes.
The handlers take the minibuffer as argument.")
   (before-download-hook (make-hook-download)
                         :type hook-download
                         :documentation "Hook run before downloading a URL.
The handlers take the URL as argument.")
   (after-download-hook (make-hook-download)
                        :type hook-download
                        :documentation "Hook run after a download has completed.
The handlers take the `download-manager:download' class instance as argument.")
   (autofills (list (make-autofill :key "Name" :fill "My Name")
                    (make-autofill :name "Hello Printer"
                                   :key "Function example"
                                   :fill (lambda () (format nil "hello!"))))
              :documentation "To autofill run the command `autofill'.
Use this slot to customize the autofill values available.

The fill can be a string value it or a function.  The latter allows you to
provide content dynamic to the context.")

   (spell-check-language "en_US"
                         :documentation "Spell check language used by Nyxt. For
a list of more languages available, please view the documentation for
cl-enchant (broker-list-dicts).")
   (external-editor-program nil
                            :type (or string null)
                            :documentation "The external editor to use for
editing files. It should be specified as a complete string path to the
editor executable."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer #'class*:name-identity))

(define-user-class browser)

(defun %get-user-data (profile path cache)
  (sera:and-let* ((expanded-path (expand-path path)))
    (multiple-value-bind  (user-data found?)
        (gethash expanded-path cache)
      (if found?
          user-data
          (let ((user-data (make-instance 'user-data)))
            (setf (gethash expanded-path cache)
                  user-data)
            (bt:with-recursive-lock-held ((lock user-data))
              (restore profile path))
            user-data)))))

(defmethod get-user-data ((profile default-data-profile) (path data-path))
  (%get-user-data profile path (user-data-cache *browser*)))

(defmethod get-containing-window-for-buffer ((buffer buffer)
                                             (browser browser))
  "Get the window containing a buffer."
  (find buffer (alex:hash-table-values (windows browser)) :key #'active-buffer))

(defmethod finalize ((browser browser) urls startup-timestamp)
  "Run `*after-init-hook*' then BROWSER's `startup-function'."
  ;; `messages-appender' requires `*browser*' to be initialized.
  (log4cl:add-appender log4cl:*root-logger* (make-instance 'messages-appender))
  (handler-case
      (hooks:run-hook *after-init-hook*)
    (error (c)
      (log:error "In *after-init-hook*: ~a" c)))
  (chanl:pexec ()
    (funcall-safely (startup-function browser) urls)
    ;; Set 'init-time at the end of finalize to take the complete startup time
    ;; into account.
    (setf (slot-value *browser* 'init-time)
          (local-time:timestamp-difference (local-time:now) startup-timestamp))))

;; Catch a common case for a better error message.
(defmethod buffers :before ((browser t))
  (when (null browser)
    (error "There is no current *browser*. Is Nyxt started?")))


(defun download-watch ()
  "Update the *Downloads* buffer.
This function is meant to be run in the background."
  ;; TODO: Add a (sleep ...)?  If we have many downloads, this loop could result
  ;; in too high a frequency of refreshes.
  (when download-manager:*notifications*
    (loop for d = (chanl:recv download-manager:*notifications*)
          while d
          when (download-manager:finished-p d)
            do (hooks:run-hook (after-download-hook *browser*))
          do (let ((buffer (find-buffer 'download-mode)))
               ;; Only update if buffer exists.  We update even when out of focus
               ;; because if we switch to the buffer after all downloads are
               ;; completed, we won't receive notifications so the content needs
               ;; to be updated already.
               ;; TODO: Disable when out of focus?  Maybe need hook for that.
               (when buffer
                 (ffi-within-renderer-thread *browser* #'download-refresh))))))

;; TODO: To download any URL at any moment and not just in resource-query, we
;; need to query the cookies for URL.  Thus we need to add an IPC endpoint to
;; query cookies.
(declaim (ftype (function (quri:uri &key
                                    (:cookies (or string null))
                                    (:proxy-address t))
                          (values (or null download-manager:download) &rest t))
                download))
(export-always 'download)
(defun download (url &key
                       cookies
                       (proxy-address :auto))
  "Download URL.
When PROXY-ADDRESS is :AUTO (the default), the proxy address is guessed from the
current buffer."
  (hooks:run-hook (before-download-hook *browser*) url) ; TODO: Set URL to download-hook result?
  (when (eq proxy-address :auto)
    (setf proxy-address (proxy-address (current-buffer)
                                       :downloads-only t)))
  (let* ((path (download-path (current-buffer)))
         (download-dir (expand-path path)))
    (declare (type (or quri:uri null) proxy-address))
    (when download-dir
      (let* ((download nil))
        (flet ((unsafe-download ()
                 (setf download (download-manager:resolve
                                 url
                                 :directory download-dir
                                 :cookies cookies
                                 :proxy proxy-address))
                 (push download (get-data path))
                 download))
          (if *keep-alive*
              (unsafe-download)
              (handler-case
                  (unsafe-download)
                (error (c)
                  (echo-warning "Download error: ~a" c)
                  nil))))))))

(defmethod get-unique-window-identifier ((browser browser))
  (format nil "~s" (incf (slot-value browser 'total-window-count))))

(defmethod get-unique-buffer-identifier ((browser browser))
  (format nil "~s" (incf (slot-value browser 'total-buffer-count))))

(declaim (ftype (function (&optional window buffer)) set-window-title))
(export-always 'set-window-title)
(defun set-window-title (&optional (window (current-window)) (buffer (current-buffer)))
  "Set current window title to 'Nyxt - TITLE - URL.
If Nyxt was started from a REPL, use 'Nyxt REPL...' instead.
This is useful to tell REPL instances from binary ones."
  (let ((url (url buffer))
        (title (title buffer)))
    (setf title (if (str:emptyp title) "" title))
    (setf url (if (url-empty-p url) "<no url/name>" (object-display url)))
    (ffi-window-set-title window
                          (str:concat "Nyxt" (when *keep-alive* " REPL") " - "
                                       title (unless (str:emptyp title) " - ")
                                       url))))

(declaim (ftype (function (list-of-strings &key (:no-focus boolean)))))
(defun open-urls (urls &key no-focus)
  "Create new buffers from URLs.
First URL is focused if NO-FOCUS is nil."
  (handler-case
      (let ((first-buffer (first (mapcar
                                  (lambda (url)
                                    (let ((buffer (make-buffer)))
                                      (buffer-load url :buffer buffer)
                                      buffer))
                                  urls))))
        (when (and first-buffer (not no-focus))
          (if (open-external-link-in-new-window-p *browser*)
              (let ((window (window-make *browser*)))
                (window-set-active-buffer window first-buffer))
              (set-current-buffer first-buffer))))
    (error (c)
      (echo-warning "Could not make buffer to open ~a: ~a" urls c))))

(defun scheme-keymap (buffer buffer-scheme)
  "Return the keymap in BUFFER-SCHEME corresponding to the BUFFER `keymap-scheme-name'.
If none is found, fall back to `scheme:cua'."
  (or (keymap:get-keymap (keymap-scheme-name buffer)
                         buffer-scheme)
      (keymap:get-keymap scheme:cua
                         buffer-scheme)))

(defun request-resource-open-url (&key url &allow-other-keys)
  (open-urls (list url) :no-focus t))

(defun request-resource-open-url-focus (&key url &allow-other-keys)
  (open-urls (list url) :no-focus nil))

(define-class request-data ()
  ((buffer (current-buffer)
           :type buffer
           :documentation "Buffer targetted by the request.")
   (url (quri:uri "")
        :documentation "URL of the request")
   (event-type :other
               :accessor nil ; TODO: No public accessor for now, we first need a use case.
               :export nil
               :documentation "The type of request, e.g. `:link-click'.")
   (new-window-p nil
                 :documentation "Whether the request wants to happen in a new window.")
   (known-type-p nil
                 :documentation "Whether the request is for a contented with
supported MIME-type (e.g. a picture that can be displayed in
the web view.")
   (keys '()
         :documentation "The key sequence that was pressed to generate the request."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer #'class*:name-identity))

(export-always 'request-resource)
(defun request-resource (request-data)
  "Candidate for `request-resource-hook'.
Deal with REQUEST-DATA with the following rules:
- If a binding matches KEYS in `request-resource-scheme', run the bound function.
- If `new-window-p' is non-nil, load in new buffer.
- If `known-type-p' is nil, download the file.
- Otherwise let the renderer load the request."
  (with-slots (url buffer keys) request-data
    (let* ((keymap (scheme-keymap buffer (request-resource-scheme buffer)))
           (bound-function (the (or symbol keymap:keymap null)
                                (keymap:lookup-key keys keymap))))
      (declare (type quri:uri url))
      (cond
        ((and (internal-buffer-p buffer) (equal "lisp" (quri:uri-scheme url)))
         (log:debug "Evaluate Lisp code from internal buffer: ~a"
                    (quri:url-decode (schemeless-url url) :lenient t))
         (evaluate-async (quri:url-decode (schemeless-url url) :lenient t))
         nil)
        ((internal-buffer-p buffer)
         (log:debug "Load URL from internal buffer in new buffer: ~a" (object-display url))
         (open-urls (list (object-string url)))
         nil)
        (bound-function
         (log:debug "Resource request key sequence ~a" (keyspecs-with-optional-keycode keys))
         (funcall-safely bound-function :url url)
         nil)
        ((new-window-p request-data)
         (log:debug "Load URL in new buffer: ~a" (object-display url))
         (open-urls (list (object-string url)))
         nil)
        ((not (known-type-p request-data))
         (log:debug "Buffer ~a initiated download of ~s." (id buffer) (object-display url))
         (download url :proxy-address (proxy-address buffer :downloads-only t)
                       :cookies "")
         (unless (find-buffer 'download-mode)
           (list-downloads))
         nil)
        (t
         (log:debug "Forwarding: ~a" (object-display url))
         request-data)))))

(export-always 'url-dispatching-handler)
(declaim (ftype (function (symbol
                           (function (quri:uri) boolean)
                           (or string (function (quri:uri) (or quri:uri null)))))
                url-dispatching-handler))
(defun url-dispatching-handler (name test action)
  "Return a `resource' handler that, if `add-hook'ed to the `request-resource-hook',
will automatically apply its ACTION on the URLs that conform to TEST.

TEST should be function of one argument, the requested URL.
ACTION can be either a shell command as a string, or a function taking a URL as argument.
In case ACTION returns nil (always the case for shell command), URL request is aborted.
The new URL returned by ACTION is loaded otherwise.

`match-host', `match-scheme', `match-domain' and `match-file-extension'
can be used to create TEST-functions, but any other function of one argument
would fit the TEST slot as well.

The following example does a few things:
- Forward DOI links to the doi.org website.
- Open magnet links with Transmission.
- Open local files (file:// URIs) with Emacs.

\(define-configuration buffer
    ((request-resource-hook (reduce #'hooks:add-hook
                                    (list (url-dispatching-handler
                                           'doi-link-dispatcher
                                           (match-scheme \"doi\")
                                           (lambda (url)
                                             (quri:uri (format nil \"https://doi.org/~a\"
                                                               (quri:uri-path url)))))
                                          (url-dispatching-handler
                                           'transmission-magnet-links
                                           (match-scheme \"magnet\")
                                           \"transmission-remote --add ~a\")
                                          (url-dispatching-handler
                                           'emacs-file
                                           (match-scheme \"file\")
                                           (lambda (url)
                                             (uiop:launch-program
                                              `(\"emacs\" ,(quri:uri-path url)))
                                             nil)))
                                    :initial-value %slot-default))))"
  (make-handler-resource
   #'(lambda (request-data)
       (let ((url (url request-data)))
         (if (funcall-safely test url)
             (etypecase action
               (function
                (let* ((new-url (funcall-safely action url)))
                  (log:info "Applied ~s URL-dispatcher on ~s and got ~s"
                            (symbol-name name)
                            (object-display url)
                            (object-display new-url))
                  (when new-url
                    (setf (url request-data) new-url)
                    request-data)))
               (string (let ((action #'(lambda (url)
                                         (uiop:launch-program
                                          (format nil action
                                                  (object-string url)))
                                         nil)))
                         (funcall-safely action url)
                         (log:info "Applied ~s shell-command URL-dispatcher on ~s"
                            (symbol-name name)
                            (object-display url)))))
             request-data)))
   :name name))

(declaim (ftype (function (string &rest string) (function (quri:uri) boolean))
                match-scheme match-host match-domain
                match-file-extension match-regex match-url))
(export-always 'match-scheme)
(defun match-scheme (scheme &rest other-schemes)
  "Return a predicate for URLs matching one of SCHEME or OTHER-SCHEMES."
  #'(lambda (url)
      (some (alex:curry #'string= (quri:uri-scheme url))
            (cons scheme other-schemes))))

(export-always 'match-host)
(defun match-host (host &rest other-hosts)
  "Return a predicate for URLs matching one of HOST or OTHER-HOSTS."
  #'(lambda (url)
      (some (alex:curry #'string= (quri:uri-host url))
            (cons host other-hosts))))

(export-always 'match-domain)
(defun match-domain (domain &rest other-domains)
  "Return a predicate for URLs matching one of DOMAIN or OTHER-DOMAINS."
  #'(lambda (url)
      (some (alex:curry #'string= (quri:uri-domain url))
            (cons domain other-domains))))

(export-always 'match-file-extension)
(defun match-file-extension (extension &rest other-extensions)
  "Return a predicate for URLs matching one of EXTENSION or OTHER-EXTENSIONS."
  #'(lambda (url)
      (some (alex:curry #'string= (pathname-type (or (quri:uri-path url) "")))
            (cons extension other-extensions))))

(export-always 'match-regex)
(defun match-regex (regex &rest other-regex)
  "Return a predicate for URLs matching one of REGES or OTHER-REGEX."
  #'(lambda (url)
      (some (alex:rcurry #'cl-ppcre:scan (object-display url))
            (cons regex other-regex))))

(export-always 'match-url)
(defun match-url (one-url &rest other-urls)
  "Return a predicate for URLs exactly matching ONE-URL or OTHER-URLS."
  #'(lambda (url)
      (some (alex:rcurry #'string= (object-display url))
            (mapcar (lambda (u) (quri:url-decode u :lenient t))
                    (cons one-url other-urls)))))

(defun javascript-error-handler (condition)
  (echo-warning "JavaScript error: ~a" condition))

(defun print-message (message &optional window)
  (let ((window (or window (current-window))))
    (when window
      (ffi-print-message window message))))

(export-always 'current-window)
(defun current-window (&optional no-rescan)
  ;; TODO: Get rid of the NO-RESCAN option and find a fast way to retrieve
  ;; current window reliably.
  ;; Tests:
  ;; - Make two windows and make sure minibuffer gets spawned in the right window.
  ;; - Delete the second window and see if the minibuffer still works in the first one.
  "Return the currently active window.
If NO-RESCAN is non-nil, fetch the window from the `last-active-window' cache
instead of asking the renderer for the active window.  It is faster but
sometimes yields the wrong reasult."
  (when *browser*
    (if (and no-rescan (slot-value *browser* 'last-active-window))
        (slot-value *browser* 'last-active-window)
        ;; No window when browser is not started or does not implement `ffi-window-active'.
        (ignore-errors (ffi-window-active *browser*)))))

(declaim (ftype (function (buffer)) set-current-buffer))
;; (declaim (ftype (function ((and buffer (not minibuffer)))) set-current-buffer)) ; TODO: Better.
;; But we can't use "minibuffer" here since it's not declared yet.  It will
;; crash Nyxt if we call set-current-buffer before instantiating the first
;; minibuffer.
(export-always 'set-current-buffer)
(defun set-current-buffer (buffer)
  "Set the active buffer for the active window."
  (unless (eq 'minibuffer (class-name (class-of buffer)))
    (if (current-window)
        (window-set-active-buffer (current-window) buffer)
        (make-window buffer))
    buffer))

(export-always 'current-minibuffer)
(defun current-minibuffer ()
  "Return the currently active minibuffer."
  (first (active-minibuffers (current-window))))

(defmethod write-output-to-log ((browser browser))
  "Set the *standard-output* and *error-output* to write to a log file."
  (let ((buffer (current-buffer)))
    (values
     (sera:and-let* ((path (expand-path (standard-output-path buffer))))
       (setf *standard-output*
             (open path
                   :direction :output
                   :if-does-not-exist :create
                   :if-exists :append)))
     (sera:and-let* ((path (expand-path (error-output-path buffer))))
       (setf *error-output*
             (open path
                   :direction :output
                   :if-does-not-exist :create
                   :if-exists :append))))))

(defmacro define-ffi-generic (name arguments)
  `(progn
     (export-always ',name)
     (defgeneric ,name (,@arguments))))

(define-ffi-generic ffi-window-delete (window))
(define-ffi-generic ffi-window-fullscreen (window))
(define-ffi-generic ffi-window-unfullscreen (window))
(define-ffi-generic ffi-buffer-uri (buffer))
(define-ffi-generic ffi-buffer-title (buffer))
(define-ffi-generic ffi-window-make (browser))
(define-ffi-generic ffi-window-to-foreground (window))
(define-ffi-generic ffi-window-set-title (window title))
(define-ffi-generic ffi-window-active (browser))
(define-ffi-generic ffi-window-set-active-buffer (window buffer))
(define-ffi-generic ffi-window-set-minibuffer-height (window height))
(define-ffi-generic ffi-window-set-status-buffer-height (window height))
(define-ffi-generic ffi-window-set-message-buffer-height (window height))
(define-ffi-generic ffi-window-get-status-buffer-height (window))
(define-ffi-generic ffi-window-get-message-buffer-height (window))
(define-ffi-generic ffi-buffer-make (browser))
(define-ffi-generic ffi-buffer-delete (buffer))
(define-ffi-generic ffi-buffer-load (buffer uri))
(define-ffi-generic ffi-buffer-evaluate-javascript (buffer javascript))
(define-ffi-generic ffi-buffer-evaluate-javascript-async (buffer javascript))
(define-ffi-generic ffi-minibuffer-evaluate-javascript (window javascript))
(define-ffi-generic ffi-buffer-enable-javascript (buffer value))
(define-ffi-generic ffi-buffer-enable-javascript-markup (buffer value))
(define-ffi-generic ffi-buffer-enable-smooth-scrolling (buffer value))
(define-ffi-generic ffi-buffer-enable-media (buffer value))
(define-ffi-generic ffi-buffer-webgl-enabled-p (buffer))
(define-ffi-generic ffi-buffer-enable-webgl (buffer value))
(define-ffi-generic ffi-buffer-auto-load-image (buffer value))
(define-ffi-generic ffi-buffer-enable-sound (buffer value))
(define-ffi-generic ffi-buffer-user-agent (buffer value))
(define-ffi-generic ffi-buffer-set-proxy (buffer &optional proxy-uri ignore-hosts))
(define-ffi-generic ffi-buffer-get-proxy (buffer))
(define-ffi-generic ffi-generate-input-event (window event))
(define-ffi-generic ffi-generated-input-event-p (window event))
(define-ffi-generic ffi-within-renderer-thread (browser thunk))
(define-ffi-generic ffi-kill-browser (browser))
(define-ffi-generic ffi-initialize (browser urls startup-timestamp))
(define-ffi-generic ffi-inspector-show (buffer))
(define-ffi-generic ffi-print-status (window text))
(define-ffi-generic ffi-print-message (window message))
(define-ffi-generic ffi-display-uri (text))
(define-ffi-generic ffi-buffer-cookie-policy (buffer value))
(define-ffi-generic ffi-set-preferred-languages (buffer value))
