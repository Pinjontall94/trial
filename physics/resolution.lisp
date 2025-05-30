(in-package #:org.shirakumo.fraf.trial)

(defclass rigidbody-system (physics-system)
  ((velocity-eps :initform 0.01 :initarg :velocity-eps :accessor velocity-eps)
   (depth-eps :initform 0.01 :initarg :depth-eps :accessor depth-eps)
   (hits :initform (map-into (make-array 1024) #'make-contact))))

(defmethod (setf units-per-metre) (units (system rigidbody-system))
  ;; The default we pick here is for assuming 1un = 1cm
  (call-next-method)
  (setf (velocity-eps system) (* units 0.01))
  (setf (depth-eps system) (* units 0.01)))

(defgeneric collides-p (a b hit))
(defgeneric resolve-collision (a b contact))
(defgeneric impart-collision (entity contact linear angular))
(defgeneric resolve-collision-impact (a b contact))
(defgeneric impart-collision-impact (entity contact velocity rotation))

(defmethod collides-p ((a ray) (b rigid-shape) hit)
  T)

(defmethod collides-p ((a rigid-shape) (b rigid-shape) hit)
  NIL)

(defmethod collides-p ((a rigidbody) (b rigidbody) hit)
  T)

(defun resolve-collision-change (entity loc angular-inertia linear-inertia total-inertia
                                 angular-change linear-change contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (declare (type vec3 loc angular-change linear-change))
  (declare (type single-float angular-inertia linear-inertia total-inertia))
  (let ((angular-move (* (contact-depth contact)
                         (/ angular-inertia total-inertia)))
        (linear-move (* (contact-depth contact)
                        (/ linear-inertia total-inertia)))
        (projection (v* (contact-normal contact)
                        (- (v. loc (contact-normal contact))))))
    (declare (dynamic-extent projection))
    ;; Some kinda angular limit magic.
    (let ((max (* 0.2 (vlength (nv+ projection loc))))
          (total (+ angular-move linear-move)))
      (cond ((< angular-move (- max))
             (setf angular-move (- max))
             (setf linear-move (- total angular-move)))
            ((< max angular-move)
             (setf angular-move max)
             (setf linear-move (- total angular-move)))))
    (cond ((= 0 angular-move)
           (vsetf angular-change 0 0 0))
          (T
           (let ((target-direction (!vc angular-change loc (contact-normal contact)))
                 (inverse-tensor (the mat3 (world-inverse-inertia-tensor entity))))
             (n*m inverse-tensor target-direction)
             (nv* angular-change (/ angular-move angular-inertia)))))
    (!v* linear-change (contact-normal contact) linear-move)
    (impart-collision entity contact linear-change angular-change)
    (unless (awake-p entity)
      (%update-rigidbody-cache entity))))

(declaim (ftype (function (entity vec3 single-float contact) (values single-float &optional)) compute-angular-inertia))
(defun compute-angular-inertia (entity loc inverse-mass contact)
  (declare (optimize speed (safety 1)))
  (if (= 0 inverse-mass)
      0f0
      (let ((cross (vec3)))
        (declare (dynamic-extent cross))
        (!vc cross loc (contact-normal contact))
        (n*m (the mat3 (world-inverse-inertia-tensor entity)) cross)
        (!vc cross cross loc)
        (v. cross (contact-normal contact)))))

(defun resolve-collision-separate (contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (let* ((a (contact-a contact))
         (b (contact-b contact))
         (a-angular-inertia (compute-angular-inertia a (contact-a-relative contact) (contact-a-inverse-mass contact) contact))
         (b-angular-inertia (compute-angular-inertia b (contact-b-relative contact) (contact-b-inverse-mass contact) contact))
         (a-linear-inertia (contact-a-inverse-mass contact))
         (b-linear-inertia (contact-b-inverse-mass contact)))
    (unless (= 0 (contact-a-inverse-mass contact))
      (resolve-collision-change a (contact-a-relative contact) a-angular-inertia a-linear-inertia (+ a-angular-inertia a-linear-inertia)
                                (contact-a-rotation-change contact) (contact-a-velocity-change contact) contact))
    (unless (= 0 (contact-b-inverse-mass contact))
      (resolve-collision-change b (contact-b-relative contact) b-angular-inertia b-linear-inertia (- (+ b-angular-inertia b-linear-inertia))
                                (contact-b-rotation-change contact) (contact-b-velocity-change contact) contact))))

(defun resolve-collision-combined (contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (let* ((a (contact-a contact))
         (b (contact-b contact))
         (a-linear-inertia (contact-a-inverse-mass contact))
         (a-angular-inertia (compute-angular-inertia a (contact-a-relative contact) (contact-a-inverse-mass contact) contact))
         (b-linear-inertia (contact-b-inverse-mass contact))
         (b-angular-inertia (compute-angular-inertia b (contact-b-relative contact) (contact-b-inverse-mass contact) contact))
         (total-inertia (+ a-linear-inertia a-angular-inertia b-linear-inertia b-angular-inertia)))
    (unless (= 0 (contact-a-inverse-mass contact))
      (resolve-collision-change a (contact-a-relative contact) a-angular-inertia a-linear-inertia (+ total-inertia)
                                (contact-a-rotation-change contact) (contact-a-velocity-change contact) contact))
    (unless (= 0 (contact-b-inverse-mass contact))
      (resolve-collision-change b (contact-b-relative contact) b-angular-inertia b-linear-inertia (- total-inertia)
                                (contact-b-rotation-change contact) (contact-b-velocity-change contact) contact))))

(defmethod resolve-collision ((a rigidbody) (b rigidbody) contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (resolve-collision-combined contact))

(defmethod impart-collision ((entity rigidbody) contact linear angular)
  (nv+ (the vec3 (location entity)) (the vec3 linear))
  (nq+* (the quat (orientation entity)) (the vec3 angular) 1.0))

(defun resolve-collision-impact-separate (contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (let ((impulse (vec 0 0 0)))
    (declare (dynamic-extent impulse))
    (let ((entity (contact-a contact))
          (velocity-change (contact-a-velocity-change contact))
          (rotation-change (contact-a-rotation-change contact))
          (orig-inv-mass (shiftf (contact-b-inverse-mass contact) 0f0)))
      (unless (= 0.0 (contact-a-inverse-mass contact))
        ;; Compute contained impulse here
        (if (and (= 0 (contact-static-friction contact))
                 (= 0 (contact-dynamic-friction contact)))
            (frictionless-impulse contact impulse)
            (frictionful-impulse contact impulse))
        (n*m (contact-to-world contact) impulse)
        ;;
        (!vc rotation-change (contact-a-relative contact) impulse)
        (n*m (the mat3 (world-inverse-inertia-tensor entity)) rotation-change)
        (!v* velocity-change impulse (contact-a-inverse-mass contact))
        (impart-collision-impact entity contact velocity-change rotation-change))
      (setf (contact-b-inverse-mass contact) orig-inv-mass))
    ;; Second body needs to invert the direction.
    (let ((entity (contact-b contact))
          (velocity-change (contact-b-velocity-change contact))
          (rotation-change (contact-b-rotation-change contact))
          (orig-inv-mass (shiftf (contact-a-inverse-mass contact) 0f0)))
      (unless (= 0.0 (contact-b-inverse-mass contact))
        ;; Compute contained impulse here
        (if (and (= 0 (contact-static-friction contact))
                 (= 0 (contact-dynamic-friction contact)))
            (frictionless-impulse contact impulse)
            (frictionful-impulse contact impulse))
        (n*m (contact-to-world contact) impulse)
        ;;
        (!vc rotation-change impulse (contact-b-relative contact))
        (n*m (the mat3 (world-inverse-inertia-tensor entity)) rotation-change)
        (!v* velocity-change impulse (- (contact-b-inverse-mass contact)))
        (impart-collision-impact entity contact velocity-change rotation-change))
      (setf (contact-a-inverse-mass contact) orig-inv-mass))))

(defun resolve-collision-impact-combined (contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (let ((impulse (vec 0 0 0)))
    (declare (dynamic-extent impulse))
    (if (and (= 0 (contact-static-friction contact))
             (= 0 (contact-dynamic-friction contact)))
        (frictionless-impulse contact impulse)
        (frictionful-impulse contact impulse))
    (n*m (contact-to-world contact) impulse)
    (let ((entity (contact-a contact))
          (velocity-change (contact-a-velocity-change contact))
          (rotation-change (contact-a-rotation-change contact)))
      (unless (= 0.0 (contact-a-inverse-mass contact))
        (!vc rotation-change (contact-a-relative contact) impulse)
        (n*m (the mat3 (world-inverse-inertia-tensor entity)) rotation-change)
        (!v* velocity-change impulse (contact-a-inverse-mass contact))
        (impart-collision-impact entity contact velocity-change rotation-change)))
    ;; Second body needs to invert the direction.
    (let ((entity (contact-b contact))
          (velocity-change (contact-b-velocity-change contact))
          (rotation-change (contact-b-rotation-change contact)))
      (unless (= 0.0 (contact-b-inverse-mass contact))
        (!vc rotation-change impulse (contact-b-relative contact))
        (n*m (the mat3 (world-inverse-inertia-tensor entity)) rotation-change)
        (!v* velocity-change impulse (- (contact-b-inverse-mass contact)))
        (impart-collision-impact entity contact velocity-change rotation-change)))))

(defmethod resolve-collision-impact ((a rigidbody) (b rigidbody) contact)
  (declare (optimize speed (safety 1)))
  (declare (type contact contact))
  (resolve-collision-impact-combined contact))

(defmethod impart-collision-impact ((entity rigidbody) contact velocity rotation)
  (nv+ (the vec3 (velocity entity)) (the vec3 velocity))
  (nv+ (the vec3 (rotation entity)) (the vec3 rotation)))

(declaim (ftype (function (simple-vector (unsigned-byte 32) (unsigned-byte 32)) (unsigned-byte 32)) prune-hits))
(defun prune-hits (hits start new-start)
  (declare (type (unsigned-byte 32) start new-start))
  (loop for head from start below new-start
        for hit = (aref hits start)
        do (when (collides-p (hit-a hit) (hit-b hit) hit)
             (rotatef (aref hits start) (aref hits head))
             (incf start)))
  start)

(defmethod generate-hits ((system rigidbody-system) hits start end)
  ;; If this seems inefficient to you, it is! Use the ACCELERATED-RIGIDBODY-SYSTEM instead.
  (loop with objects = (%objects system)
        for i from 0 below (length objects)
        for a = (aref objects i)
        do (loop for j from (1+ i) below (length objects)
                 for b = (aref objects j)
                 do (when (and (or (< 0.0 (inverse-mass a))
                                   (< 0.0 (inverse-mass b)))
                               (or (awake-p a)
                                   (awake-p b))
                               (intersects-p (global-bounds-cache a) (global-bounds-cache b)))
                      ;; Don't bother detecting hits between immovable objects
                      (loop for a-p across (physics-primitives a)
                            do (loop for b-p across (physics-primitives b)
                                     do (when (and (< 0 (logand (collision-mask a-p) (collision-mask b-p)
                                                                (collision-mask a) (collision-mask b)))
                                                   (intersects-p (primitive-global-bounds-cache a-p)
                                                                 (primitive-global-bounds-cache b-p)))
                                          (let ((new-start (detect-hits a-p b-p hits start end)))
                                            (setf start (prune-hits hits start new-start)))))))))
  start)

(defmethod resolve-hits ((system rigidbody-system) contacts start end dt &key (iterations 200))
  (declare (type (simple-array contact (*)) contacts))
  (declare (type (unsigned-byte 32) start end iterations))
  (declare (type single-float dt))
  (declare (optimize speed))
  (macrolet ((do-contacts ((contact) &body body)
               `(loop for i from start below end
                      for ,contact = (aref contacts i)
                      do (progn ,@body)))
             (do-update (args &body body)
               `(do-contacts (other)
                  (flet ((change ,args
                           ,@body))
                    (when (eq (contact-a other) (contact-a contact))
                      (change (contact-a-rotation-change contact)
                              (contact-a-velocity-change contact)
                              (contact-a-relative other) -1))
                    (when (eq (contact-a other) (contact-b contact))
                      (change (contact-b-rotation-change contact)
                              (contact-b-velocity-change contact)
                              (contact-a-relative other) -1))
                    (when (eq (contact-b other) (contact-a contact))
                      (change (contact-a-rotation-change contact)
                              (contact-a-velocity-change contact)
                              (contact-b-relative other) +1))
                    (when (eq (contact-b other) (contact-b contact))
                      (change (contact-b-rotation-change contact)
                              (contact-b-velocity-change contact)
                              (contact-b-relative other) +1))))))
    ;; Prepare Contacts
    (do-contacts (contact)
      (upgrade-hit-to-contact contact dt))

    ;; Adjust Positions
    (loop repeat iterations
          for worst = (the single-float (depth-eps system))
          for contact = NIL
          do (do-contacts (tentative)
               (when (and (< worst (contact-depth tentative))
                          (< 0.0 (contact-depth tentative)))
                 (setf contact tentative)
                 (setf worst (contact-depth contact))))
             (unless contact (return))
             (match-awake-state contact)
             (resolve-collision (hit-a contact) (hit-b contact) contact)
             ;; We now need to fix up the contact depths.
             (do-update (rotation-change velocity-change loc sign)
               (let ((cross (vec3)))
                 (declare (dynamic-extent cross))
                 (!vc cross rotation-change loc)
                 (incf (contact-depth other)
                       (* sign (v. (nv+ cross velocity-change)
                                   (contact-normal other))))))
          finally (dbg "POS Overflow"))

    ;; Adjust Velocities
    (loop repeat iterations
          for worst = (the single-float (velocity-eps system)) ;; Some kinda epsilon.
          for contact = NIL
          do (do-contacts (tentative)
               (when (and (< worst (contact-desired-delta tentative))
                          (< 0.0 (contact-desired-delta tentative)))
                 (setf contact tentative)
                 (setf worst (contact-desired-delta contact))))
             (unless contact (return))
             (match-awake-state contact)
             (resolve-collision-impact (hit-a contact) (hit-b contact) contact)
             (when (< 0.0 (contact-desired-delta contact))
               (do-update (rotation-change velocity-change loc sign)
                 (let ((cross (vec3)))
                   (declare (dynamic-extent cross))
                   (!vc cross rotation-change loc)
                   (ntransform-inverse (nv+ cross velocity-change) (contact-to-world other))
                   (nv+* (contact-velocity other) cross (- sign))
                   (setf (contact-desired-delta other)
                         (desired-delta-velocity other (contact-velocity other) dt)))))
          finally (dbg "VEL Overflow"))))

;;;

(defun non-zero-mass ()
  (lambda (entity)
    (not (= 0.0 (inverse-mass entity)))))

(defun at-least-one (entity-predicate)
  (lambda (entity1 entity2)
    (or (funcall entity-predicate entity1)
        (funcall entity-predicate entity2))))

(defun both (entity-predicate)
  (lambda (entity1 entity2)
    (and (funcall entity-predicate entity1)
         (funcall entity-predicate entity2))))

(defun consider-entities (entity-pair-predicate)
  (lambda (primitive1 primitive2)
    (funcall entity-pair-predicate
             (primitive-entity primitive1)
             (primitive-entity primitive2))))

(defclass debug-rigidbody-mixin ()
  ((show-collision-debug :initarg :show-collision-debug
                         :initform NIL
                         :accessor show-collision-debug)
   (show-collision-predicate :initarg :show-collision-predicate
                             :accessor show-collision-predicate
                             :initform NIL)
   (debug-instances :reader debug-instances
                    :initform (make-hash-table :test #'eq))
   (generation      :accessor generation
                    :initform 0))
  (:default-initargs
   :show-collision-predicate (consider-entities (at-least-one (non-zero-mass)))))

(defmethod start-frame :after ((system debug-rigidbody-mixin))
  (when (show-collision-debug system)
    (let ((generation (generation system)))
      (debug-clear)
      (clrhash (debug-instances system))
      (setf (generation system) (1+ generation)))))

(defmethod generate-hits :around ((system debug-rigidbody-mixin) hits start end)
  (if (show-collision-debug system)
      (labels ((object-color (object1 object2)
                 (let* ((a1 #+sbcl (sb-vm::get-lisp-obj-address object1)
                            #-sbcl (sxhash (descriptor object1)))
                        (a2 #+sbcl (sb-vm::get-lisp-obj-address object2)
                            #-sbcl (sxhash (descriptor object1)))
                        (h (random (ash 1 24) (random-state:make-generator :squirrel (logxor a1 a2))))
                        (r (float (/ (ldb (byte 8  0) h) (ash 1 8)) 1.0f0))
                        (g (float (/ (ldb (byte 8  8) h) (ash 1 8)) 1.0f0))
                        (b (float (/ (ldb (byte 8 16) h) (ash 1 8)) 1.0f0)))
                   (values (vec3 r g b) h)))
               (debug-draw-hit (a b hit)
                 (debug-point (hit-location hit))
                 (debug-line (hit-location hit) (v+* (hit-location hit) (hit-normal hit) -2)
                             :color-a #.(vec 0 0 0) :color-b #.(vec 0 1 0))
                 (let ((color (object-color (hit-a hit) (hit-b hit))))
                   (flet ((debug-primitive (primitive)
                            ;; Oriented bounding box in green.
                            (multiple-value-bind (c b) (compute-bounding-box primitive)
                              (debug-box c b
                                         :transform (primitive-global-transform primitive)
                                         :color (vec3 0 1 0)))
                            ;; Collider geometry in object color.
                            (debug-draw primitive :color color)))
                     (debug-primitive a)
                     (debug-primitive b)))))
        (let* ((broadphase-pairs '())
               (collision-pairs '())
               (result (let ((start start))
                         (loop with structure = (static-acceleration-structure system)
                               for object across (%objects system)
                               do (when (and (< 0 (inverse-mass object))
                                             (awake-p object))
                                    (loop for a across (physics-primitives object)
                                          do (3ds:do-overlapping (b structure a)
                                               (when (< 0 (logand (collision-mask a) (collision-mask b)
                                                                  (collision-mask object) (collision-mask (primitive-entity b))))
                                                 (push (cons a b) broadphase-pairs)
                                                 (let ((new-start (prune-hits hits start (detect-hits a b hits start end))))
                                                   (when (> new-start start)
                                                     (push (cons a b) collision-pairs))
                                                   (when (funcall (show-collision-predicate system) a b)
                                                     (loop for i from start below new-start
                                                           do (debug-draw-hit a b (aref hits i))))
                                                   (setf start new-start))
                                                 (when (<= end start) (return start)))))))
                         (3ds:do-pairs (a b (dynamic-acceleration-structure system) start)
                           (let ((entity1 (primitive-entity a))
                                 (entity2 (primitive-entity b)))
                             (when (< 0 (logand (primitive-collision-mask a) (primitive-collision-mask b)
                                                (collision-mask entity1) (collision-mask entity2)))
                               (unless (and (= 0.0 (inverse-mass entity1))
                                            (= 0.0 (inverse-mass entity2)))
                                 (push (cons a b) broadphase-pairs)
                                 (let ((new-start (prune-hits hits start (detect-hits a b hits start end))))
                                   (when (> new-start start)
                                     (push (cons a b) collision-pairs))
                                   (when (funcall (show-collision-predicate system) a b)
                                     (loop for i from start below new-start
                                           do (debug-draw-hit a b (aref hits i))))
                                   (setf start new-start))
                                 (when (<= end start) (return start))))))))
               (drawn '()))
          (labels ((debug-bbox (system object location bsize color)
                     (let* ((debug-instances (debug-instances system))
                            (generation (generation system))
                            (info (gethash object debug-instances))
                            (old-id (when info (car info)))
                            (id (debug-box location bsize :color color :instance old-id)))
                       (when info
                         (setf (cdr info) generation))
                       (unless old-id
                         (setf (gethash object debug-instances) (cons id generation)))))
                   (draw-primitive (primitive color)
                     (when (not (find primitive drawn))
                       (push primitive drawn)
                       (let ((location (3ds:location primitive))
                             (bsize (3ds:bsize primitive)))
                         (debug-bbox system primitive location bsize color))))
                   (draw-phase (pairs color)
                     (loop for (a . b) in pairs
                           when (funcall (show-collision-predicate system) a b)
                           do (draw-primitive a color)
                              (draw-primitive b color))))
            (draw-phase collision-pairs (vec3 1 0 0))
            (draw-phase broadphase-pairs (vec3 .8 .8 0)))
          result))
      (call-next-method)))
