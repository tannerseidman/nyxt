(in-package :nyxt)

(declaim (ftype (function (containers:ring-buffer-reverse) string) ring-insert-clipboard))
(export-always 'ring-insert-clipboard)
(defun ring-insert-clipboard (ring)
  "Check if clipboard-content is most recent entry in RING.
If not, insert clipboard-content into RING.
Return most recent entry in RING."
  (let ((clipboard-content (trivial-clipboard:text)))
    (unless (string= clipboard-content (unless (containers:empty-p ring)
                                         (containers:first-item ring)))
      (containers:insert-item ring clipboard-content)))
  (string (containers:first-item ring)))

(export-always 'copy-to-clipboard)
(defun copy-to-clipboard (input)
  "Save INPUT text to clipboard, and ring."
  (containers:insert-item (clipboard-ring *browser*) (trivial-clipboard:text input)))