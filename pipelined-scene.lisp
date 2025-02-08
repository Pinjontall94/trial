(in-package #:org.shirakumo.fraf.trial)

(defclass pipelined-scene (scene pipeline)
  ((to-preload :initarg :to-preload :initform () :accessor to-preload)))

(defmethod preload (object (scene pipelined-scene))
  (pushnew object (to-preload scene)))

(defmethod preload ((name symbol) (scene scene))
  (preload (make-instance name) scene))

(defmethod setup-scene :around (main (scene pipelined-scene))
  (prog1 (call-next-method)
    ;; We only bother packing the pipeline if it's been set up in any way.
    ;; Doing it always will actually clear the pipeline even if it's already
    ;; been set up.
    (when (nodes scene)
      (multiple-value-bind (w h) (frame-size (context main))
        (pack-pipeline scene w h)))
    (loop for pass across (passes scene)
          do (enter scene pass)
             (dolist (thing (to-preload scene))
               (when (typep thing '(or class entity))
                 (enter thing pass))))
    ;; KLUDGE: this will trigger class changed events which we can ignore.
    ;;         we have to do this both because it's a waste of time, but also
    ;;         because not doing so leads to real ???? OpenGL driver state.
    (discard-events scene 'class-changed)))

(defmethod stage :before ((scene pipelined-scene) (area staging-area))
  (loop for texture across (textures scene)
        do (stage texture area))
  (loop for entity in (to-preload scene)
        do (stage entity area))
  (loop for pass across (passes scene)
        do (stage pass area)))

(defmethod handle :after ((event resize) (scene pipelined-scene))
  (multiple-value-bind (w h) (frame-size event)
    (resize scene w h)))

(defmethod register :after ((entity renderable) (scene pipelined-scene))
  (loop for pass across (passes scene)
        do (when (object-renderable-p entity pass)
             (enter entity pass))))

(defmethod deregister :after ((entity renderable) (scene pipelined-scene))
  (loop for pass across (passes scene)
        do (when (object-renderable-p entity pass)
             (leave entity pass))))

(defmethod save-image ((scene pipelined-scene) target type &rest args)
  (apply #'save-image (aref (passes scene) (1- (length (passes scene)))) target type args))

(defmethod clear-pipeline :after ((scene pipelined-scene))
  (loop for pass across (passes scene)
        do (remove-listener pass scene)))
