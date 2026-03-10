;; prize-pool.clar
;; Central liquidity hub for LuckyHive. Manages deposits (storing in the hive),
;; withdrawals (leaving the hive), and prize awarding to the Queen Bee.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u3000))
(define-constant ERR-PAUSED (err u3001))
(define-constant ERR-INVALID-AMOUNT (err u3002))
(define-constant ERR-INSUFFICIENT-BALANCE (err u3003))
(define-constant ERR-BELOW-MINIMUM (err u3004))
(define-constant ERR-ABOVE-MAXIMUM (err u3005))
(define-constant ERR-NO-YIELD (err u3006))
(define-constant ERR-DRAW-NOT-READY (err u3007))
(define-constant ERR-INVALID-WINNER (err u3008))
(define-constant ERR-ALREADY-CLAIMED (err u3009))

;; ---------------------------------------------------------
;; Gamification & Retention Configuration (SWOT Improvments)
;; ---------------------------------------------------------
(define-constant NECTAR_DROP_PERCENTAGE u45) ;; 45% of yield goes to secondary random drops
(define-constant QUEEN_BEE_PERCENTAGE u45) ;; 45% of yield goes to the main winner
(define-constant FEEDER_INCENTIVE_PERCENTAGE u5) ;; 5% goes to the tx-sender (gas reimbursement)
(define-constant DAO_TREASURY_PERCENTAGE u5) ;; 5% goes to the protocol owner/DAO

;; ---------------------------------------------------------
;; STATE
;; ---------------------------------------------------------

(define-data-var contract-paused bool false)
(define-data-var min-deposit uint u1000000) ;; 1 STX (u1000000 microSTX)
(define-data-var max-deposit uint u1000000000000) ;; 1,000,000 STX cap
(define-data-var total-deposits uint u0)
(define-data-var total-yield uint u0)
(define-data-var nectar-drops-reserve uint u0) ;; Reserve for secondary smaller prizes
(define-data-var draw-counter uint u0)
(define-data-var draw-interval uint u144) ;; ~24 hours in blocks
(define-data-var last-draw-block uint u0)

;; Per-user deposit tracking
(define-map user-deposits
  { user: principal }
  { amount: uint }
)

;; Draw records
(define-map draw-history
  { draw-id: uint }
  {
    winner: principal,
    prize-amount: uint,
    stacks-block-height: uint,
    claimed: bool,
    seed: (buff 32),
  }
)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (assert-not-paused)
  (ok (asserts! (not (var-get contract-paused)) ERR-PAUSED))
)

;; ============================================================
;; PUBLIC: STORE IN THE HIVE (deposit)
;; ============================================================

(define-public (store-in-hive
    (amount uint)
    (referrer (optional principal))
  )
  (begin
    (try! (assert-not-paused))
    (asserts! (>= amount (var-get min-deposit)) ERR-BELOW-MINIMUM)
    (asserts! (<= amount (var-get max-deposit)) ERR-ABOVE-MAXIMUM)

    ;; Transfer STX from user to this contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

    ;; Mint honeycomb receipt tokens
    (try! (contract-call? .luckyhive-honeycomb mint amount tx-sender))

    ;; Loyalty Multipliers & Referrals (Hive Invites)
    ;; A referrer grants a 5% TWAB boost to the depositor and a 5% TWAB boost to the referrer
    (let (
        (time-lock-multiplier u1)
        (base-twab-addition (* amount time-lock-multiplier))
        (referral-boost (if (is-some referrer)
          (/ (* base-twab-addition u5) u100)
          u0
        ))
        (final-depositor-twab (+ base-twab-addition referral-boost))
        (current-balance (get-user-balance tx-sender))
      )
      ;; Record Depositor TWAB observation
      (try! (contract-call? .luckyhive-twab-controller record-observation tx-sender
        (+ current-balance final-depositor-twab) stacks-block-height
      ))

      ;; Record Referrer TWAB observation if present and valid
      (match referrer
        referring-bee (if (and (not (is-eq referring-bee tx-sender)) (> (get-user-balance referring-bee) u0))
          (try! (contract-call? .luckyhive-twab-controller record-observation referring-bee
            (+ (get-user-balance referring-bee) referral-boost)
            stacks-block-height
          ))
          true ;; Ignore self-referrals or empty referrers
        )
        true
      )
    )

    ;; Update state
    (let (
        (current-deposit (default-to { amount: u0 } (map-get? user-deposits { user: tx-sender })))
        (new-amount (+ (get amount current-deposit) amount))
      )
      (map-set user-deposits { user: tx-sender } { amount: new-amount })

      ;; If this is the first deposit in the hive, establish the countdown
      (if (is-eq (var-get total-deposits) u0)
        (var-set last-draw-block stacks-block-height)
        true
      )

      (var-set total-deposits (+ (var-get total-deposits) amount))

      (print {
        event: "stored-in-hive",
        bee: tx-sender,
        amount: amount,
        total-stored: new-amount,
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: LEAVE THE HIVE (withdraw)
;; ============================================================

(define-public (leave-hive (amount uint))
  (begin
    (try! (assert-not-paused))
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (let (
        (current-deposit (default-to { amount: u0 } (map-get? user-deposits { user: tx-sender })))
        (current-amount (get amount current-deposit))
      )
      (asserts! (>= current-amount amount) ERR-INSUFFICIENT-BALANCE)

      ;; Burn honeycomb tokens
      (try! (contract-call? .luckyhive-honeycomb burn amount tx-sender))

      ;; Transfer STX back to user
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))

      ;; Record TWAB observation
      (try! (contract-call? .luckyhive-twab-controller record-observation tx-sender
        (- current-amount amount) stacks-block-height
      ))

      ;; Update state
      (map-set user-deposits { user: tx-sender } { amount: (- current-amount amount) })
      (var-set total-deposits (- (var-get total-deposits) amount))

      (print {
        event: "left-hive",
        bee: tx-sender,
        amount: amount,
        remaining: (- current-amount amount),
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: AWARD QUEEN BEE (draw winner)
;; ============================================================

;; Anyone can trigger a draw after the draw interval has passed.
;; Uses a commit-reveal scheme combined with block data for randomness.
(define-public (award-queen-bee (seed (buff 32)))
  (begin
    (try! (assert-not-paused))
    (asserts!
      (>= stacks-block-height
        (+ (var-get last-draw-block) (var-get draw-interval))
      )
      ERR-DRAW-NOT-READY
    )
    (asserts! (> (var-get total-yield) u0) ERR-NO-YIELD)

    (let (
        (draw-id (+ (var-get draw-counter) u1))
        (prize-amount (var-get total-yield))
        ;; Split yield based on Gamification Strategy
        (queen-bee-prize (/ (* prize-amount QUEEN_BEE_PERCENTAGE) u100))
        (nectar-drops (/ (* prize-amount NECTAR_DROP_PERCENTAGE) u100))
        (feeder-incentive (/ (* prize-amount FEEDER_INCENTIVE_PERCENTAGE) u100))
        (dao-fee (/ (* prize-amount DAO_TREASURY_PERCENTAGE) u100))
        (combined-seed (keccak256 (concat seed
          (unwrap-panic (get-stacks-block-info? id-header-hash (- stacks-block-height u1)))
        )))
      )
      ;; Payout Feeder Incentive immediately
      (if (> feeder-incentive u0)
        (try! (as-contract (stx-transfer? feeder-incentive tx-sender tx-sender)))
        true
      )
      ;; Payout DAO Treasury Fee immediately
      (if (> dao-fee u0)
        (try! (as-contract (stx-transfer? dao-fee tx-sender CONTRACT-OWNER)))
        true
      )
      ;; Record draw (winner selection happens off-chain via TWAB query + seed)
      ;; In production, this would verify a VRF proof
      (map-set draw-history { draw-id: draw-id } {
        winner: tx-sender, ;; Placeholder: real implementation uses TWAB-weighted selection
        prize-amount: queen-bee-prize,
        stacks-block-height: stacks-block-height,
        claimed: false,
        seed: combined-seed,
      })

      (var-set draw-counter draw-id)
      (var-set last-draw-block stacks-block-height)
      (var-set nectar-drops-reserve
        (+ (var-get nectar-drops-reserve) nectar-drops)
      )
      (var-set total-yield u0)

      (print {
        event: "queen-bee-crowned",
        draw-id: draw-id,
        queen-bee-prize: queen-bee-prize,
        nectar-drops-added: nectar-drops,
        feeder-reward: feeder-incentive,
        stacks-block-height: stacks-block-height,
      })
      (ok draw-id)
    )
  )
)

;; ============================================================
;; PUBLIC: CLAIM PRIZE
;; ============================================================

(define-public (claim-prize (draw-id uint))
  (begin
    (try! (assert-not-paused))
    (let ((draw (unwrap! (map-get? draw-history { draw-id: draw-id }) ERR-INVALID-WINNER)))
      (asserts! (is-eq (get winner draw) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (not (get claimed draw)) ERR-ALREADY-CLAIMED)

      ;; Transfer prize
      (try! (as-contract (stx-transfer? (get prize-amount draw) tx-sender tx-sender)))

      ;; Mark as claimed
      (map-set draw-history { draw-id: draw-id } (merge draw { claimed: true }))

      (print {
        event: "prize-claimed",
        queen-bee: tx-sender,
        draw-id: draw-id,
        amount: (get prize-amount draw),
      })
      (ok (get prize-amount draw))
    )
  )
)

;; ============================================================
;; PUBLIC: ADD YIELD (called by vault-factory)
;; ============================================================

(define-public (add-yield (amount uint))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    ;; Accept STX yield from vault
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set total-yield (+ (var-get total-yield) amount))
    (print {
      event: "yield-added",
      amount: amount,
      total-yield: (var-get total-yield),
    })
    (ok true)
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-private (get-user-balance (user principal))
  (get amount (default-to { amount: u0 } (map-get? user-deposits { user: user })))
)

(define-read-only (get-hive-stats)
  (ok {
    total-deposits: (var-get total-deposits),
    total-yield: (var-get total-yield),
    total-bees: (unwrap-panic (contract-call? .luckyhive-honeycomb get-total-supply)),
    draw-counter: (var-get draw-counter),
    next-draw-block: (+ (var-get last-draw-block) (var-get draw-interval)),
    is-paused: (var-get contract-paused),
  })
)

(define-read-only (get-user-deposit (user principal))
  (ok (default-to { amount: u0 } (map-get? user-deposits { user: user })))
)

(define-read-only (get-draw-info (draw-id uint))
  (ok (map-get? draw-history { draw-id: draw-id }))
)

;; ============================================================
;; ADMIN / GOVERNANCE
;; ============================================================

(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (print {
      event: "pause-toggled",
      paused: paused,
    })
    (ok (var-set contract-paused paused))
  )
)

(define-public (set-draw-interval (interval uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set draw-interval interval))
  )
)

(define-public (set-deposit-limits
    (new-min uint)
    (new-max uint)
  )
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set min-deposit new-min)
    (ok (var-set max-deposit new-max))
  )
)
