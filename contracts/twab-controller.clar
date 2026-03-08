;; twab-controller.clar
;; Time-Weighted Average Balance controller for LuckyHive.
;; Tracks historical balances using a ring buffer to compute
;; fair draw odds over arbitrary time ranges.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u2000))

;; Ring buffer capacity: 720 slots (30 days at 1-hour epochs)
(define-constant RING-BUFFER-SIZE u720)

;; ============================================================
;; STATE
;; ============================================================

;; Authorized contract that can record observations (the prize-pool)
(define-data-var authorized-recorder principal CONTRACT-OWNER)

;; Global cumulative stats
(define-data-var total-supply-current uint u0)

;; Per-user observation ring buffer
;; Each observation records: timestamp, balance, cumulative-balance
(define-map user-observations
  { user: principal, index: uint }
  {
    timestamp: uint,
    balance: uint,
    cumulative-balance: uint
  }
)

;; Ring buffer pointers per user
(define-map user-ring-state
  { user: principal }
  {
    next-index: uint,
    count: uint,
    current-balance: uint
  }
)

;; Global total-supply observations (same ring buffer pattern)
(define-map supply-observations
  { index: uint }
  {
    timestamp: uint,
    balance: uint,
    cumulative-balance: uint
  }
)

(define-data-var supply-ring-next-index uint u0)
(define-data-var supply-ring-count uint u0)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-authorized-recorder)
  (is-eq contract-caller (var-get authorized-recorder))
)

;; ============================================================
;; INTERNAL HELPERS
;; ============================================================

(define-private (compute-cumulative
    (prev-cumulative uint)
    (prev-balance uint)
    (prev-timestamp uint)
    (current-timestamp uint)
  )
  (let (
    (elapsed (- current-timestamp prev-timestamp))
  )
    (+ prev-cumulative (* prev-balance elapsed))
  )
)

;; ============================================================
;; PUBLIC: RECORD OBSERVATION
;; ============================================================

;; Called by prize-pool on every deposit/withdrawal to record a new
;; balance observation for the given user.
(define-public (record-observation (user principal) (new-balance uint) (timestamp uint))
  (begin
    (asserts! (is-authorized-recorder) ERR-NOT-AUTHORIZED)
    (let (
      (ring-state (default-to
        { next-index: u0, count: u0, current-balance: u0 }
        (map-get? user-ring-state { user: user })
      ))
      (prev-index (if (> (get count ring-state) u0)
        (mod (- (+ (get next-index ring-state) RING-BUFFER-SIZE) u1) RING-BUFFER-SIZE)
        u0
      ))
      (prev-obs (default-to
        { timestamp: timestamp, balance: u0, cumulative-balance: u0 }
        (map-get? user-observations { user: user, index: prev-index })
      ))
      (new-cumulative (if (> (get count ring-state) u0)
        (compute-cumulative
          (get cumulative-balance prev-obs)
          (get balance prev-obs)
          (get timestamp prev-obs)
          timestamp
        )
        u0
      ))
      (write-index (get next-index ring-state))
    )
      ;; Write the observation
      (map-set user-observations
        { user: user, index: write-index }
        {
          timestamp: timestamp,
          balance: new-balance,
          cumulative-balance: new-cumulative
        }
      )
      ;; Advance ring pointer
      (map-set user-ring-state
        { user: user }
        {
          next-index: (mod (+ write-index u1) RING-BUFFER-SIZE),
          count: (if (< (get count ring-state) RING-BUFFER-SIZE)
            (+ (get count ring-state) u1)
            RING-BUFFER-SIZE
          ),
          current-balance: new-balance
        }
      )
      ;; Update total supply observation
      (let (
        (old-balance (get current-balance ring-state))
        (supply-delta (if (>= new-balance old-balance)
          (- new-balance old-balance)
          u0
        ))
        (supply-reduction (if (< new-balance old-balance)
          (- old-balance new-balance)
          u0
        ))
        (new-total (+ (- (var-get total-supply-current) supply-reduction) supply-delta))
        (supply-idx (var-get supply-ring-next-index))
        (supply-count (var-get supply-ring-count))
        (prev-supply-idx (if (> supply-count u0)
          (mod (- (+ supply-idx RING-BUFFER-SIZE) u1) RING-BUFFER-SIZE)
          u0
        ))
        (prev-supply-obs (default-to
          { timestamp: timestamp, balance: u0, cumulative-balance: u0 }
          (map-get? supply-observations { index: prev-supply-idx })
        ))
        (supply-cumulative (if (> supply-count u0)
          (compute-cumulative
            (get cumulative-balance prev-supply-obs)
            (get balance prev-supply-obs)
            (get timestamp prev-supply-obs)
            timestamp
          )
          u0
        ))
      )
        (map-set supply-observations
          { index: supply-idx }
          {
            timestamp: timestamp,
            balance: new-total,
            cumulative-balance: supply-cumulative
          }
        )
        (var-set supply-ring-next-index (mod (+ supply-idx u1) RING-BUFFER-SIZE))
        (var-set supply-ring-count (if (< supply-count RING-BUFFER-SIZE) (+ supply-count u1) RING-BUFFER-SIZE))
        (var-set total-supply-current new-total)
      )
      (print {
        event: "observation-recorded",
        user: user,
        balance: new-balance,
        timestamp: timestamp
      })
      (ok true)
    )
  )
)

;; ============================================================
;; READ-ONLY: TWAB QUERIES
;; ============================================================

;; Get a user's current balance
(define-read-only (get-current-balance (user principal))
  (let (
    (ring-state (default-to
      { next-index: u0, count: u0, current-balance: u0 }
      (map-get? user-ring-state { user: user })
    ))
  )
    (ok (get current-balance ring-state))
  )
)

;; Get user ring state metadata
(define-read-only (get-user-ring-state (user principal))
  (ok (default-to
    { next-index: u0, count: u0, current-balance: u0 }
    (map-get? user-ring-state { user: user })
  ))
)

;; Get a specific observation for a user
(define-read-only (get-observation (user principal) (index uint))
  (ok (map-get? user-observations { user: user, index: index }))
)

;; Get the total supply currently tracked
(define-read-only (get-total-supply)
  (ok (var-get total-supply-current))
)

;; ============================================================
;; ADMIN
;; ============================================================

(define-public (set-authorized-recorder (new-recorder principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (print { event: "recorder-updated", new-recorder: new-recorder })
    (ok (var-set authorized-recorder new-recorder))
  )
)
