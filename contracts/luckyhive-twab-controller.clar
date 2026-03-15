;; twab-controller.clar
;; Time-Weighted Average Balance controller for LuckyHive.
;; Tracks historical balances using a ring buffer to compute
;; fair draw odds over arbitrary time ranges.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant ERR-NOT-AUTHORIZED (err u2000))

;; Ring buffer capacity: 720 slots (30 days at 1-hour epochs)
(define-constant RING-BUFFER-SIZE u720)

;; 10 binary search steps: 2^10 = 1024 > 720
(define-constant SEARCH-STEPS (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9))

;; ============================================================
;; STATE
;; ============================================================

(define-data-var total-supply-current uint u0)

;; Per-user observation ring buffer
(define-map user-observations
  {
    user: principal,
    index: uint,
  }
  {
    timestamp: uint,
    balance: uint,
    cumulative-balance: uint,
  }
)

;; Ring buffer pointers per user
(define-map user-ring-state
  { user: principal }
  {
    next-index: uint,
    count: uint,
    current-balance: uint,
  }
)

;; Global total-supply observations (same ring buffer pattern)
(define-map supply-observations
  { index: uint }
  {
    timestamp: uint,
    balance: uint,
    cumulative-balance: uint,
  }
)

(define-data-var supply-ring-next-index uint u0)
(define-data-var supply-ring-count uint u0)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-authorized-recorder)
  (is-eq contract-caller .luckyhive-prize-pool)
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
  (let ((elapsed (- current-timestamp prev-timestamp)))
    (+ prev-cumulative (* prev-balance elapsed))
  )
)

;; Convert logical index (0=oldest) to physical ring buffer index
(define-private (logical-to-physical
    (logical-idx uint)
    (oldest-physical uint)
  )
  (mod (+ oldest-physical logical-idx) RING-BUFFER-SIZE)
)

;; ============================================================
;; BINARY SEARCH: USER OBSERVATIONS
;; ============================================================

;; Each step halves the search space to find the rightmost
;; observation with timestamp <= target-ts.
(define-private (bs-step-user
    (ignored uint)
    (state {
      low: uint,
      high: uint,
      target-ts: uint,
      user: principal,
      oldest: uint,
    })
  )
  (let (
      (low (get low state))
      (high (get high state))
    )
    (if (>= low high)
      state
      (let (
          (mid (/ (+ low high) u2))
          (phys (logical-to-physical mid (get oldest state)))
          (obs (default-to {
            timestamp: u0,
            balance: u0,
            cumulative-balance: u0,
          }
            (map-get? user-observations {
              user: (get user state),
              index: phys,
            })
          ))
        )
        (if (<= (get timestamp obs) (get target-ts state))
          (merge state { low: (+ mid u1) })
          (merge state { high: mid })
        )
      )
    )
  )
)

;; Returns the observation at or just before target-ts for a user.
;; If no observation exists at or before target-ts, returns default
;; with timestamp u0 (caller must check this).
(define-private (find-obs-before-user
    (user principal)
    (target-ts uint)
  )
  (let (
      (ring (default-to {
        next-index: u0,
        count: u0,
        current-balance: u0,
      }
        (map-get? user-ring-state { user: user })
      ))
      (count (get count ring))
    )
    (if (is-eq count u0)
      {
        timestamp: u0,
        balance: u0,
        cumulative-balance: u0,
      }
      (let (
          (oldest (if (< count RING-BUFFER-SIZE)
            u0
            (get next-index ring)
          ))
          (result (fold bs-step-user SEARCH-STEPS {
            low: u0,
            high: count,
            target-ts: target-ts,
            user: user,
            oldest: oldest,
          }))
          (found-logical (if (> (get low result) u0)
            (- (get low result) u1)
            u0
          ))
          (found-phys (logical-to-physical found-logical oldest))
        )
        (default-to {
          timestamp: u0,
          balance: u0,
          cumulative-balance: u0,
        }
          (map-get? user-observations {
            user: user,
            index: found-phys,
          })
        )
      )
    )
  )
)

;; ============================================================
;; BINARY SEARCH: SUPPLY OBSERVATIONS
;; ============================================================

(define-private (bs-step-supply
    (ignored uint)
    (state {
      low: uint,
      high: uint,
      target-ts: uint,
      oldest: uint,
    })
  )
  (let (
      (low (get low state))
      (high (get high state))
    )
    (if (>= low high)
      state
      (let (
          (mid (/ (+ low high) u2))
          (phys (logical-to-physical mid (get oldest state)))
          (obs (default-to {
            timestamp: u0,
            balance: u0,
            cumulative-balance: u0,
          }
            (map-get? supply-observations { index: phys })
          ))
        )
        (if (<= (get timestamp obs) (get target-ts state))
          (merge state { low: (+ mid u1) })
          (merge state { high: mid })
        )
      )
    )
  )
)

(define-private (find-obs-before-supply (target-ts uint))
  (let ((count (var-get supply-ring-count)))
    (if (is-eq count u0)
      {
        timestamp: u0,
        balance: u0,
        cumulative-balance: u0,
      }
      (let (
          (oldest (if (< count RING-BUFFER-SIZE)
            u0
            (var-get supply-ring-next-index)
          ))
          (result (fold bs-step-supply SEARCH-STEPS {
            low: u0,
            high: count,
            target-ts: target-ts,
            oldest: oldest,
          }))
          (found-logical (if (> (get low result) u0)
            (- (get low result) u1)
            u0
          ))
          (found-phys (logical-to-physical found-logical oldest))
        )
        (default-to {
          timestamp: u0,
          balance: u0,
          cumulative-balance: u0,
        }
          (map-get? supply-observations { index: found-phys })
        )
      )
    )
  )
)

;; ============================================================
;; INTERPOLATION
;; ============================================================

;; Compute the cumulative balance at an arbitrary timestamp by
;; interpolating from the nearest prior observation.
(define-private (interpolate-cumulative
    (obs {
      timestamp: uint,
      balance: uint,
      cumulative-balance: uint,
    })
    (at-ts uint)
  )
  (if (or (is-eq (get timestamp obs) u0) (> (get timestamp obs) at-ts))
    u0 ;; No valid observation before at-ts
    (+ (get cumulative-balance obs)
      (* (get balance obs) (- at-ts (get timestamp obs)))
    )
  )
)

;; ============================================================
;; PUBLIC: RECORD OBSERVATION
;; ============================================================

(define-public (record-observation
    (user principal)
    (new-balance uint)
    (timestamp uint)
  )
  (begin
    (asserts! (is-authorized-recorder) ERR-NOT-AUTHORIZED)
    (let (
        (ring-state (default-to {
          next-index: u0,
          count: u0,
          current-balance: u0,
        }
          (map-get? user-ring-state { user: user })
        ))
        (prev-index (if (> (get count ring-state) u0)
          (mod (- (+ (get next-index ring-state) RING-BUFFER-SIZE) u1)
            RING-BUFFER-SIZE
          )
          u0
        ))
        (prev-obs (default-to {
          timestamp: timestamp,
          balance: u0,
          cumulative-balance: u0,
        }
          (map-get? user-observations {
            user: user,
            index: prev-index,
          })
        ))
        (new-cumulative (if (> (get count ring-state) u0)
          (compute-cumulative (get cumulative-balance prev-obs)
            (get balance prev-obs) (get timestamp prev-obs) timestamp
          )
          u0
        ))
        (write-index (get next-index ring-state))
      )
      ;; Write the observation
      (map-set user-observations {
        user: user,
        index: write-index,
      } {
        timestamp: timestamp,
        balance: new-balance,
        cumulative-balance: new-cumulative,
      })
      ;; Advance ring pointer
      (map-set user-ring-state { user: user } {
        next-index: (mod (+ write-index u1) RING-BUFFER-SIZE),
        count: (if (< (get count ring-state) RING-BUFFER-SIZE)
          (+ (get count ring-state) u1)
          RING-BUFFER-SIZE
        ),
        current-balance: new-balance,
      })
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
          (prev-supply-obs (default-to {
            timestamp: timestamp,
            balance: u0,
            cumulative-balance: u0,
          }
            (map-get? supply-observations { index: prev-supply-idx })
          ))
          (supply-cumulative (if (> supply-count u0)
            (compute-cumulative (get cumulative-balance prev-supply-obs)
              (get balance prev-supply-obs) (get timestamp prev-supply-obs)
              timestamp
            )
            u0
          ))
        )
        (map-set supply-observations { index: supply-idx } {
          timestamp: timestamp,
          balance: new-total,
          cumulative-balance: supply-cumulative,
        })
        (var-set supply-ring-next-index (mod (+ supply-idx u1) RING-BUFFER-SIZE))
        (var-set supply-ring-count
          (if (< supply-count RING-BUFFER-SIZE)
            (+ supply-count u1)
            RING-BUFFER-SIZE
          ))
        (var-set total-supply-current new-total)
      )
      (print {
        event: "observation-recorded",
        user: user,
        balance: new-balance,
        timestamp: timestamp,
      })
      (ok true)
    )
  )
)

;; ============================================================
;; READ-ONLY: TWAB QUERIES
;; ============================================================

;; Compute Time-Weighted Average Balance for a user over [start-ts, end-ts].
;; Returns the average balance the user held during that period.
(define-read-only (get-twab-between
    (user principal)
    (start-ts uint)
    (end-ts uint)
  )
  (if (>= start-ts end-ts)
    (ok u0)
    (let (
        (obs-start (find-obs-before-user user start-ts))
        (obs-end (find-obs-before-user user end-ts))
        (duration (- end-ts start-ts))
        (cum-start (interpolate-cumulative obs-start start-ts))
        (cum-end (interpolate-cumulative obs-end end-ts))
      )
      (ok (/ (- cum-end cum-start) duration))
    )
  )
)

;; Compute Time-Weighted Average total supply over [start-ts, end-ts].
(define-read-only (get-total-twab-between
    (start-ts uint)
    (end-ts uint)
  )
  (if (>= start-ts end-ts)
    (ok u0)
    (let (
        (obs-start (find-obs-before-supply start-ts))
        (obs-end (find-obs-before-supply end-ts))
        (duration (- end-ts start-ts))
        (cum-start (interpolate-cumulative obs-start start-ts))
        (cum-end (interpolate-cumulative obs-end end-ts))
      )
      (ok (/ (- cum-end cum-start) duration))
    )
  )
)

;; Get a user's current balance
(define-read-only (get-current-balance (user principal))
  (let ((ring-state (default-to {
      next-index: u0,
      count: u0,
      current-balance: u0,
    }
      (map-get? user-ring-state { user: user })
    )))
    (ok (get current-balance ring-state))
  )
)

;; Get user ring state metadata
(define-read-only (get-user-ring-state (user principal))
  (ok (default-to {
    next-index: u0,
    count: u0,
    current-balance: u0,
  }
    (map-get? user-ring-state { user: user })
  ))
)

;; Get a specific observation for a user
(define-read-only (get-observation
    (user principal)
    (index uint)
  )
  (ok (map-get? user-observations {
    user: user,
    index: index,
  }))
)

;; Get the total supply currently tracked
(define-read-only (get-total-supply)
  (ok (var-get total-supply-current))
)
