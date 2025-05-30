(in-package #:org.shirakumo.fraf.trial)

(defclass pose (sequences:sequence standard-object)
  ((joints :initform #() :accessor joints)
   (parents :initform (make-array 0 :element-type '(signed-byte 16)) :accessor parents)
   (weights :initform (make-hash-table :test 'eql) :accessor weights)
   (data :initform (make-hash-table :test 'eql) :initarg :data :accessor data)))

(defmethod shared-initialize :after ((pose pose) slots &key size source)
  (cond (source
         (pose<- pose source))
        (size
         (sequences:adjust-sequence pose size))))

(defmethod print-object ((pose pose) stream)
  (print-unreadable-object (pose stream :type T :identity T)
    (format stream "~d joint~:p" (length (joints pose)))))

(defmethod describe-object :after ((pose pose) stream)
  (format stream "~&~%Weights:")
  (if (< 0 (hash-table-count (weights pose)))
      (loop for k being the hash-key of (weights pose) using (hash-value v)
            do (format stream "~%  ~30a: ~,3f" k v))
      (format stream "~%  No weights."))
  (format stream "~&~%Joints:~%")
  (let ((parents (parents pose))
        (joints (joints pose)))
    (flet ((bone-label (i)
             (format NIL "~3d~@< ~@;~a~;~:>" i (when (<= 0 i) (write-transform (aref joints i) NIL))))
           (bone-children (i)
             (loop for j from 0 below (length parents)
                   when (= (aref parents j) i) collect j)))
      (org.shirakumo.text-draw:tree -1 #'bone-children :key #'bone-label :stream stream :max-depth NIL))))

(defmethod clone ((pose pose) &key)
  (pose<- (make-instance 'pose) pose))

(defun pose<- (target source)
  (let* ((orig-joints (joints source))
         (orig-parents (parents source))
         (size (length orig-joints))
         (joints (joints target))
         (parents (parents target)))
    (let ((old (length joints)))
      (when (/= old size)
        (setf (joints target) (setf joints (adjust-array joints size)))
        (setf (parents target) (setf parents (adjust-array parents size)))
        (loop for i from old below size
              do (setf (svref joints i) (transform)))))
    (loop for i from 0 below size
          do (setf (aref parents i) (aref orig-parents i))
             (t<- (aref joints i) (aref orig-joints i)))
    (loop for k being the hash-keys of (weights source) using (hash-value v)
          do (setf (gethash k (weights target)) v))
    target))

(defun pose= (a b)
  (let ((a-joints (joints a))
        (b-joints (joints b))
        (a-parents (parents a))
        (b-parents (parents b)))
    (and (= (length a-joints) (length b-joints))
         (loop for i from 0 below (length a-joints)
               always (and (= (aref a-parents i) (aref b-parents i))
                           (t= (svref a-joints i) (svref b-joints i)))))))

(defmethod sequences:length ((pose pose))
  (length (joints pose)))

(defmethod sequences:adjust-sequence ((pose pose) length &rest args)
  (declare (ignore args))
  (let ((old (length (joints pose))))
    (setf (joints pose) (adjust-array (joints pose) length))
    (when (< old length)
      (loop for i from old below length
            do (setf (svref (joints pose) i) (transform)))))
  (setf (parents pose) (adjust-array (parents pose) length :initial-element 0))
  pose)

(defmethod check-consistent ((pose pose))
  (let ((parents (parents pose))
        (visit (make-array (length pose) :element-type 'bit)))
    (dotimes (i (length parents) pose)
      (fill visit 0)
      (loop for parent = (aref parents i) then (aref parents parent)
            while (<= 0 parent)
            do (when (= 1 (aref visit parent))
                 (error "Bone ~a has a cycle in its parents chain." i))
               (setf (aref visit parent) 1)))))

(defmethod sequences:elt ((pose pose) index)
  (svref (joints pose) index))

(defmethod (setf sequences:elt) ((transform transform) (pose pose) index)
  (setf (svref (joints pose) index) transform))

(defmethod (setf sequences:elt) ((parent integer) (pose pose) index)
  (setf (aref (parents pose) index) parent))

(defmethod parent-joint ((pose pose) i)
  (aref (parents pose) i))

(defmethod (setf parent-joint) (value (pose pose) i)
  (setf (aref (parents pose) i) value))

(defmethod global-transform ((pose pose) i &optional (result (transform)))
  (let* ((joints (joints pose))
         (parents (parents pose)))
    (t<- result (svref joints i))
    (loop for parent = (aref parents i) then (aref parents parent)
          while (<= 0 parent)
          do (!t+ result (svref joints parent) result))
    result))

(defmethod global-quat2 ((pose pose) i &optional (result (quat2)))
  (let* ((joints (joints pose))
         (parents (parents pose)))
    (tquat2 (svref joints i) result)
    (loop for parent = (aref parents i) then (aref parents parent)
          while (<= 0 parent)
          do (let ((temp (quat2)))
               (declare (dynamic-extent temp))
               (nq2* result (tquat2 (svref joints parent) temp))))
    result))

(defmethod matrix-palette ((pose pose) result)
  (let ((length (length (joints pose)))
        (joints (joints pose))
        (parents (parents pose))
        (i 0))
    (setf result (%adjust-array result length (lambda () (meye 4))))
    (loop while (< i length)
          for parent = (aref parents i)
          do (when (< i parent) (return))
             (let ((global (!tmat (svref result i) (aref joints i))))
               (when (<= 0 parent)
                 (n*m (aref result parent) global)))
             (incf i))
    (loop while (< i length)
          do (!tmat (svref result i) (global-transform pose i))
             (incf i))
    result))

(defmethod quat2-palette ((pose pose) result)
  (let ((length (length (joints pose)))
        (joints (joints pose))
        (parents (parents pose)))
    (setf result (%adjust-array result length #'quat2))
    (loop for i from 0 below length
          for res = (svref result i)
          do (tquat2 (svref joints i) res)
             (loop for parent = (aref parents i) then (aref parents parent)
                   while (<= 0 parent)
                   do (let ((temp (quat2)))
                        (declare (dynamic-extent temp))
                        (nq2* res (tquat2 (svref joints parent) temp)))))
    result))

(defmethod descendant-joint-p (joint root (pose pose))
  (or (= joint root)
      (loop with parents = (parents pose)
            for parent = (aref parents joint) then (aref parents parent)
            while (<= 0 parent)
            do (when (= parent root) (return T)))))

(defmethod blend-into ((target pose) (a pose) (b pose) x &key (root -1))
  (let ((x (float x 0f0)))
    (dotimes (i (length target) target)
      (unless (and (<= 0 root)
                   (descendant-joint-p i root target))
        (ninterpolate (elt target i) (elt a i) (elt b i) x)))))

(defmethod blend-into (target a b x &key)
  (blend-into target a b (float x 0f0)))

(defmethod layer-onto ((target pose) (in pose) (add pose) (base pose) &key (root -1))
  (dotimes (i (length add) target)
    (unless (and (<= 0 root)
                 (not (descendant-joint-p i root add)))
      (let ((output (elt target i))
            (input (elt in i))
            (additive (elt add i))
            (additive-base (elt base i)))
        (!v+ (tlocation output) (tlocation input) (v- (tlocation additive) (tlocation additive-base)))
        (!v+ (tscaling output) (tscaling input) (v- (tscaling additive) (tscaling additive-base)))
        (!q* (trotation output) (trotation input) (q* (qinv (trotation additive-base)) (trotation additive)))
        (nqunit* (trotation output))))))

(defmethod layer-onto ((target vec3) (in vec3) (add vec3) (base vec3) &key)
  (!v+ target in (v- add base)))

(defmethod layer-onto ((target quat) (in quat) (add quat) (base quat) &key)
  (nqunit* (!q* target in (q* (qinv base) add))))

(defmethod layer-onto ((target transform) (in transform) (add transform) (base transform) &key)
  (!v+ (tlocation target) (tlocation in) (v- (tlocation add) (tlocation base)))
  (!v+ (tscaling target) (tscaling in) (v- (tscaling add) (tscaling base)))
  (nqunit* (!q* (trotation target) (trotation in) (q* (qinv (trotation base)) (trotation add))))
  target)

(defmethod replace-vertex-data ((lines lines) (pose pose) &rest args &key &allow-other-keys)
  (let ((points ()))
    (dotimes (i (length pose))
      (let ((parent (parent-joint pose i)))
        (when (<= 0 parent)
          (push (tlocation (global-transform pose i)) points)
          (push (tlocation (global-transform pose parent)) points))))
    (apply #'replace-vertex-data lines (nreverse points) args)))

;;; Minor optimisation to avoid sequence accessor overhead
(defmethod sample ((pose pose) (clip clip) time &key (loop-p (loop-p clip)))
  (declare (type single-float time))
  (declare (optimize speed))
  (if (< 0.0 (the single-float (end-time clip)))
      (let ((time (fit-to-clip clip time))
            (tracks (tracks clip))
            (joints (joints pose)))
        (declare (type single-float time))
        (declare (type simple-vector tracks joints))
        (loop for i from 0 below (length tracks)
              for track = (svref tracks i)
              for name = (name track)
              do (etypecase track
                   (transform-track (sample (aref joints name) track time :loop-p loop-p))
                   (weights-track (sample pose track time :loop-p loop-p))
                   (T (sample (data pose) track time :loop-p loop-p))))
        time)
      0.0))

(defmethod sample ((pose pose) (track weights-track) time &key loop-p)
  (declare (type single-float time))
  (declare (optimize speed))
  (let* ((all-weights (weights pose))
         (weights (gethash (name track) all-weights #.(make-array 0 :element-type 'single-float))))
    (declare (type (simple-array single-float (*)) weights))
    (declare (type hash-table all-weights))
    #-trial-release
    (unless (= (length weights) (weights track))
      (cerror "Adjust the array" "Weights do not match track! (have ~d, need ~d for ~a)"
              (length weights) (weights track) (name track))
      (setf weights (setf (gethash (name track) all-weights)
                          (make-array (weights track) :element-type 'single-float))))
    (sample weights track time :loop-p loop-p))
  pose)

(defmethod sample ((pose pose) thing time &rest args &key &allow-other-keys)
  (apply #'sample (data pose) thing time args))
