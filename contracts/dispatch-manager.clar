;; dispatch-manager.clar
;; A robust dispatch management system enabling secure, role-based task routing
;; and tracking across decentralized networks using the Stacks blockchain.

;; =============================
;; Constants / Error Codes
;; =============================

;; General errors
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-DISPATCH-ALREADY-EXISTS (err u101))
(define-constant ERR-DISPATCH-NOT-FOUND (err u102))

;; Role errors
(define-constant ERR-INVALID-ROLE (err u200))
(define-constant ERR-ROLE-TRANSITION-NOT-ALLOWED (err u201))

;; Task state errors
(define-constant ERR-INVALID-STATE-TRANSITION (err u300))
(define-constant ERR-TASK-ALREADY-COMPLETED (err u301))

;; Role constants
(define-constant ROLE-ADMIN u1)
(define-constant ROLE-DISPATCHER u2)
(define-constant ROLE-RESPONDER u3)

;; Task state constants
(define-constant STATE-PENDING u1)
(define-constant STATE-IN-PROGRESS u2)
(define-constant STATE-COMPLETED u3)
(define-constant STATE-CANCELLED u4)

;; =============================
;; Data Maps and Variables
;; =============================

;; Contract administrator - initially set to contract deployer
(define-data-var contract-admin principal tx-sender)

;; User registry with role management
(define-map users principal {
  role: uint,
  is-active: bool,
  name: (string-utf8 64),
  registration-time: uint
})

;; Dispatch task tracking
(define-map dispatch-tasks 
  uint  ;; Task ID
  {
    title: (string-utf8 100),
    description: (string-utf8 500),
    creator: principal,
    assigned-to: principal,
    state: uint,
    priority: uint,
    created-at: uint,
    updated-at: uint
  }
)

;; Audit log for task state changes
(define-map task-audit-log 
  { task-id: uint, log-id: uint }
  {
    actor: principal,
    previous-state: uint,
    new-state: uint,
    timestamp: uint,
    reason: (string-utf8 200)
  }
)

;; Global counters
(define-data-var task-counter uint u0)
(define-data-var audit-log-counter uint u0)

;; =============================
;; Private Functions
;; =============================

;; Check if user has specific role
(define-private (has-role (user principal) (expected-role uint))
  (match (map-get? users user)
    user-data (and 
      (is-eq (get role user-data) expected-role)
      (get is-active user-data))
    false
  )
)

;; Check if user is admin
(define-private (is-admin (user principal))
  (is-eq user (var-get contract-admin))
)

;; Create audit log entry for task state change
(define-private (log-task-state-change 
  (task-id uint) 
  (actor principal) 
  (previous-state uint) 
  (new-state uint)
  (reason (string-utf8 200)))
  
  (let ((log-id (+ (var-get audit-log-counter) u1)))
    (var-set audit-log-counter log-id)
    (map-set task-audit-log 
      { task-id: task-id, log-id: log-id }
      {
        actor: actor,
        previous-state: previous-state,
        new-state: new-state,
        timestamp: block-height,
        reason: reason
      }
    )
    log-id
  )
)

;; =============================
;; Read-Only Functions
;; =============================

;; Get task details
(define-read-only (get-task-details (task-id uint))
  (map-get? dispatch-tasks task-id)
)

;; Get user information
(define-read-only (get-user-info (user principal))
  (map-get? users user)
)

;; =============================
;; Public Functions
;; =============================

;; Register a new user in the system
(define-public (register-user 
  (name (string-utf8 64)) 
  (role uint))
  (begin
    (asserts! (or (is-admin tx-sender) (is-eq role ROLE-RESPONDER)) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= role ROLE-ADMIN) (<= role ROLE-RESPONDER)) ERR-INVALID-ROLE)
    
    (map-set users tx-sender {
      role: role,
      is-active: true,
      name: name,
      registration-time: block-height
    })
    (ok true)
  )
)

;; Create a new dispatch task
(define-public (create-task 
  (title (string-utf8 100))
  (description (string-utf8 500))
  (assigned-to principal)
  (priority uint))
  (begin
    (asserts! (has-role tx-sender ROLE-DISPATCHER) ERR-NOT-AUTHORIZED)
    (asserts! (has-role assigned-to ROLE-RESPONDER) ERR-NOT-AUTHORIZED)
    
    (let ((task-id (+ (var-get task-counter) u1)))
      (var-set task-counter task-id)
      
      (map-set dispatch-tasks task-id {
        title: title,
        description: description,
        creator: tx-sender,
        assigned-to: assigned-to,
        state: STATE-PENDING,
        priority: priority,
        created-at: block-height,
        updated-at: block-height
      })
      
      (ok task-id)
    )
  )
)

;; Update task state
(define-public (update-task-state 
  (task-id uint)
  (new-state uint)
  (reason (string-utf8 200)))
  (let ((current-task (unwrap! (map-get? dispatch-tasks task-id) ERR-DISPATCH-NOT-FOUND))
        (current-state (get state current-task)))
    
    (asserts! 
      (or 
        (and 
          (is-eq new-state STATE-IN-PROGRESS) 
          (is-eq current-state STATE-PENDING)
          (has-role tx-sender ROLE-RESPONDER)
          (is-eq (get assigned-to current-task) tx-sender)
        )
        (and
          (is-eq new-state STATE-COMPLETED)
          (is-eq current-state STATE-IN-PROGRESS)
          (has-role tx-sender ROLE-RESPONDER)
          (is-eq (get assigned-to current-task) tx-sender)
        )
        (and
          (is-eq new-state STATE-CANCELLED)
          (or 
            (is-eq current-state STATE-PENDING)
            (is-eq current-state STATE-IN-PROGRESS)
          )
          (or 
            (is-eq (get creator current-task) tx-sender)
            (is-admin tx-sender)
          )
        )
      )
      ERR-INVALID-STATE-TRANSITION
    )
    
    (map-set dispatch-tasks task-id (merge current-task {
      state: new-state,
      updated-at: block-height
    }))
    
    (log-task-state-change task-id tx-sender current-state new-state reason)
    
    (ok true)
  )
)

;; Change contract administrator
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)