;; prize-pool.clar
;; Central liquidity hub for LuckyHive. Manages deposits, withdrawals,
;; yield splitting, prize draws with TWAB-verified winner selection,
;; auto-claim, and solvency invariants.

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
(define-constant ERR-CLAIM-EXPIRED (err u3010))
(define-constant ERR-ZERO-TWAB (err u3011))
(define-constant ERR-INSOLVENT (err u3012))

;; Yield split percentages
(define-constant NECTAR_DROP_PERCENTAGE u45)
(define-constant QUEEN_BEE_PERCENTAGE u45)
(define-constant FEEDER_INCENTIVE_PERCENTAGE u5)
(define-constant DAO_TREASURY_PERCENTAGE u5)

;; Claim expiry: 1008 blocks (~7 days)
(define-constant CLAIM-DEADLINE u1008)
;; Auto-claim fee: 1% of prize to the claimer bot
(define-constant CLAIM-FEE-BPS u100)
(define-constant BPS-DENOMINATOR u10000)

;; ============================================================
;; STATE
;; ============================================================

(define-data-var contract-paused bool false)
(define-data-var min-deposit uint u1000000)        ;; 1 STX
(define-data-var max-deposit uint u1000000000000)   ;; 1,000,000 STX
(define-data-var total-deposits uint u0)
(define-data-var total-yield uint u0)
(define-data-var total-depositors uint u0)
(define-data-var nectar-drops-reserve uint u0)
(define-data-var nectar-drop-amount uint u0)        ;; Temp for fold
(define-data-var draw-counter uint u0)
(define-data-var draw-interval uint u144)            ;; ~24 hours
(define-data-var last-draw-block uint u0)

;; Per-user deposit tracking
(define-map user-deposits
  { user: principal }
  { amount: uint }
)

;; Draw records (enhanced with TWAB verification data)
(define-map draw-history
  { draw-id: uint }
  {
    winner: principal,
    prize-amount: uint,
    block-height: uint,
    claimed: bool,
    seed: (buff 32),
    draw-start-block: uint,
    winner-twab: uint,
    total-twab: uint,
  }
)

;; Referral tracking
(define-map referral-records
  { referee: principal }
  { referrer: principal, boost: uint, block-height: uint }
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

    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

    ;; Mint honeycomb receipt tokens
    (try! (contract-call? .luckyhive-honeycomb mint amount tx-sender))

    ;; Referral and TWAB logic
    (let (
        (base-twab-addition amount)
        (referral-boost (if (is-some referrer)
          (/ (* base-twab-addition u5) u100)
          u0
        ))
        (final-depositor-twab (+ base-twab-addition referral-boost))
        (current-balance (get-user-balance tx-sender))
      )
      ;; Record TWAB for depositor
      (try! (contract-call? .luckyhive-twab-controller record-observation tx-sender
        (+ current-balance final-depositor-twab) stacks-block-height
      ))

      ;; Record referral and referrer TWAB boost
      (match referrer
        referring-bee
          (if (and (not (is-eq referring-bee tx-sender))
                   (> (get-user-balance referring-bee) u0))
            (begin
              ;; Track referral on-chain
              (map-set referral-records { referee: tx-sender } {
                referrer: referring-bee,
                boost: referral-boost,
                block-height: stacks-block-height,
              })
              ;; Boost referrer TWAB
              (try! (contract-call? .luckyhive-twab-controller record-observation
                referring-bee (+ (get-user-balance referring-bee) referral-boost)
                stacks-block-height
              ))
              true
            )
            true
          )
        true
      )
    )

    ;; Update state
    (let (
        (current-deposit (default-to { amount: u0 }
          (map-get? user-deposits { user: tx-sender })))
        (new-amount (+ (get amount current-deposit) amount))
      )
      ;; Increment depositor count on first deposit
      (if (is-eq (get amount current-deposit) u0)
        (var-set total-depositors (+ (var-get total-depositors) u1))
        true
      )

      (map-set user-deposits { user: tx-sender } { amount: new-amount })

      ;; Initialize draw countdown on first-ever deposit
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
  (let ((user tx-sender))
    (begin
      (try! (assert-not-paused))
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (let (
          (current-deposit (default-to { amount: u0 }
            (map-get? user-deposits { user: user })))
          (current-amount (get amount current-deposit))
          (new-amount (- current-amount amount))
        )
        (asserts! (>= current-amount amount) ERR-INSUFFICIENT-BALANCE)

        ;; Burn honeycomb tokens
        (try! (contract-call? .luckyhive-honeycomb burn amount user))

        ;; Transfer STX back to user
        (try! (as-contract (stx-transfer? amount tx-sender user)))

        ;; Record TWAB observation
        (try! (contract-call? .luckyhive-twab-controller record-observation user
          new-amount stacks-block-height
        ))

        ;; Decrement depositor count on full withdrawal
        (if (is-eq new-amount u0)
          (var-set total-depositors (- (var-get total-depositors) u1))
          true
        )

        ;; Update state
        (map-set user-deposits { user: user } { amount: new-amount })
        (var-set total-deposits (- (var-get total-deposits) amount))

        (print {
          event: "left-hive",
          bee: user,
          amount: amount,
          remaining: new-amount,
        })
        (ok true)
      )
    )
  )
)

;; ============================================================
;; PUBLIC: AWARD QUEEN BEE (draw with TWAB verification)
;; ============================================================

;; Winner is nominated off-chain via TWAB-weighted selection.
;; The contract verifies: winner has non-zero TWAB for the draw
;; period and logs all verification data for public auditability.
;; Anyone can independently verify by reading on-chain TWAB data.
(define-public (award-queen-bee
    (winner principal)
    (seed (buff 32))
  )
  (let ((feeder tx-sender))
    (begin
      (try! (assert-not-paused))
      (asserts! (or (is-contract-owner)
        (is-eq contract-caller .luckyhive-auction-manager))
        ERR-NOT-AUTHORIZED
      )
      (asserts!
        (>= stacks-block-height
          (+ (var-get last-draw-block) (var-get draw-interval))
        )
        ERR-DRAW-NOT-READY
      )
      (asserts! (> (var-get total-yield) u0) ERR-NO-YIELD)

      ;; Verify winner has non-zero TWAB for the draw period
      (let (
          (draw-start (var-get last-draw-block))
          (draw-end stacks-block-height)
          (winner-twab (unwrap-panic
            (contract-call? .luckyhive-twab-controller
              get-twab-between winner draw-start draw-end)
          ))
          (total-twab (unwrap-panic
            (contract-call? .luckyhive-twab-controller
              get-total-twab-between draw-start draw-end)
          ))
        )
        ;; Winner must have a non-zero time-weighted balance
        (asserts! (> winner-twab u0) ERR-ZERO-TWAB)
        ;; Winner must be a current depositor
        (asserts! (> (get-user-balance winner) u0) ERR-INVALID-WINNER)

        (let (
            (draw-id (+ (var-get draw-counter) u1))
            (prize-amount (var-get total-yield))
            (queen-bee-prize (/ (* prize-amount QUEEN_BEE_PERCENTAGE) u100))
            (nectar-drops (/ (* prize-amount NECTAR_DROP_PERCENTAGE) u100))
            (feeder-incentive (/ (* prize-amount FEEDER_INCENTIVE_PERCENTAGE) u100))
            (dao-fee (/ (* prize-amount DAO_TREASURY_PERCENTAGE) u100))
            (combined-seed (keccak256 (concat seed
              (unwrap-panic (get-stacks-block-info? id-header-hash
                (- stacks-block-height u1)))
            )))
          )
          ;; Pay feeder incentive
          (if (> feeder-incentive u0)
            (try! (as-contract (stx-transfer? feeder-incentive tx-sender feeder)))
            true
          )
          ;; Pay DAO treasury fee
          (if (> dao-fee u0)
            (try! (as-contract (stx-transfer? dao-fee tx-sender CONTRACT-OWNER)))
            true
          )

          ;; Record draw with TWAB verification data
          (map-set draw-history { draw-id: draw-id } {
            winner: winner,
            prize-amount: queen-bee-prize,
            block-height: stacks-block-height,
            claimed: false,
            seed: combined-seed,
            draw-start-block: draw-start,
            winner-twab: winner-twab,
            total-twab: total-twab,
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
            winner: winner,
            queen-bee-prize: queen-bee-prize,
            nectar-drops-added: nectar-drops,
            feeder-reward: feeder-incentive,
            winner-twab: winner-twab,
            total-twab: total-twab,
            seed: combined-seed,
          })
          (ok draw-id)
        )
      )
    )
  )
)

;; ============================================================
;; PUBLIC: DISTRIBUTE NECTAR DROPS
;; ============================================================

(define-public (distribute-nectar-drops
    (recipients (list 50 principal))
    (amount-per-bee uint)
  )
  (let ((total-payout (* (len recipients) amount-per-bee)))
    (begin
      (try! (assert-not-paused))
      (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
      (asserts! (<= total-payout (var-get nectar-drops-reserve))
        ERR-INSUFFICIENT-BALANCE
      )
      (var-set nectar-drop-amount amount-per-bee)
      (try! (fold stx-transfer-iter recipients (ok true)))
      (var-set nectar-drops-reserve
        (- (var-get nectar-drops-reserve) total-payout)
      )
      (print {
        event: "nectar-drops-distributed",
        bee-count: (len recipients),
        amount-per-bee: amount-per-bee,
        total-payout: total-payout,
      })
      (ok total-payout)
    )
  )
)

(define-private (stx-transfer-iter
    (recipient principal)
    (previous-result (response bool uint))
  )
  (match previous-result
    prev-ok (as-contract (stx-transfer?
      (var-get nectar-drop-amount) tx-sender recipient))
    prev-err previous-result
  )
)

;; ============================================================
;; PUBLIC: CLAIM PRIZE (self-claim)
;; ============================================================

(define-public (claim-prize (draw-id uint))
  (let ((claimer tx-sender))
    (begin
      (try! (assert-not-paused))
      (let ((draw (unwrap! (map-get? draw-history { draw-id: draw-id })
            ERR-INVALID-WINNER)))
        (asserts! (is-eq (get winner draw) claimer) ERR-NOT-AUTHORIZED)
        (asserts! (not (get claimed draw)) ERR-ALREADY-CLAIMED)
        ;; Check claim deadline
        (asserts!
          (<= stacks-block-height
            (+ (get block-height draw) CLAIM-DEADLINE))
          ERR-CLAIM-EXPIRED
        )
        ;; Transfer full prize to winner
        (try! (as-contract (stx-transfer?
          (get prize-amount draw) tx-sender claimer)))
        (map-set draw-history { draw-id: draw-id }
          (merge draw { claimed: true }))
        (print {
          event: "prize-claimed",
          queen-bee: claimer,
          draw-id: draw-id,
          amount: (get prize-amount draw),
        })
        (ok (get prize-amount draw))
      )
    )
  )
)

;; ============================================================
;; PUBLIC: AUTO-CLAIM (anyone claims for winner, earns fee)
;; ============================================================

(define-public (claim-prize-for (draw-id uint))
  (let ((bot tx-sender))
    (begin
      (try! (assert-not-paused))
      (let (
          (draw (unwrap! (map-get? draw-history { draw-id: draw-id })
            ERR-INVALID-WINNER))
          (prize (get prize-amount draw))
          (winner (get winner draw))
          (fee (/ (* prize CLAIM-FEE-BPS) BPS-DENOMINATOR))
          (winner-payout (- prize fee))
        )
        (asserts! (not (get claimed draw)) ERR-ALREADY-CLAIMED)
        (asserts!
          (<= stacks-block-height
            (+ (get block-height draw) CLAIM-DEADLINE))
          ERR-CLAIM-EXPIRED
        )
        ;; Transfer prize minus fee to winner
        (try! (as-contract (stx-transfer? winner-payout tx-sender winner)))
        ;; Transfer fee to claimer bot
        (if (> fee u0)
          (try! (as-contract (stx-transfer? fee tx-sender bot)))
          true
        )
        (map-set draw-history { draw-id: draw-id }
          (merge draw { claimed: true }))
        (print {
          event: "prize-auto-claimed",
          draw-id: draw-id,
          winner: winner,
          winner-payout: winner-payout,
          bot: bot,
          bot-fee: fee,
        })
        (ok winner-payout)
      )
    )
  )
)

;; ============================================================
;; PUBLIC: RECLAIM EXPIRED PRIZE
;; ============================================================

;; After CLAIM-DEADLINE, unclaimed prizes return to yield reserve.
(define-public (reclaim-expired-prize (draw-id uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (let ((draw (unwrap! (map-get? draw-history { draw-id: draw-id })
          ERR-INVALID-WINNER)))
      (asserts! (not (get claimed draw)) ERR-ALREADY-CLAIMED)
      (asserts!
        (> stacks-block-height
          (+ (get block-height draw) CLAIM-DEADLINE))
        ERR-DRAW-NOT-READY
      )
      ;; Mark as claimed so it can't be double-reclaimed
      (map-set draw-history { draw-id: draw-id }
        (merge draw { claimed: true }))
      ;; Return prize to yield reserve
      (var-set total-yield (+ (var-get total-yield) (get prize-amount draw)))
      (print {
        event: "expired-prize-reclaimed",
        draw-id: draw-id,
        amount: (get prize-amount draw),
      })
      (ok (get prize-amount draw))
    )
  )
)

;; ============================================================
;; PUBLIC: ADD YIELD
;; ============================================================

(define-public (add-yield (amount uint))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    ;; WARNING: Only vault or contract owner may add yield
    (asserts! (or (is-contract-owner)
      (is-eq contract-caller .luckyhive-vault))
      ERR-NOT-AUTHORIZED
    )
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
  (get amount (default-to { amount: u0 }
    (map-get? user-deposits { user: user })))
)

(define-read-only (get-hive-stats)
  (ok {
    total-deposits: (var-get total-deposits),
    total-yield: (var-get total-yield),
    total-bees: (var-get total-depositors),
    nectar-drops-reserve: (var-get nectar-drops-reserve),
    draw-counter: (var-get draw-counter),
    next-draw-block: (+ (var-get last-draw-block) (var-get draw-interval)),
    is-paused: (var-get contract-paused),
  })
)

(define-read-only (get-user-deposit (user principal))
  (ok (default-to { amount: u0 }
    (map-get? user-deposits { user: user })))
)

(define-read-only (get-draw-info (draw-id uint))
  (ok (map-get? draw-history { draw-id: draw-id }))
)

(define-read-only (get-referral-info (referee principal))
  (ok (map-get? referral-records { referee: referee }))
)

;; Solvency invariant: contract balance must cover all obligations.
;; WARNING: If this returns is-solvent: false, the protocol has a bug.
(define-read-only (check-solvency)
  (let (
      (obligations (+ (var-get total-deposits)
        (+ (var-get total-yield) (var-get nectar-drops-reserve))))
    )
    (ok {
      obligations: obligations,
      is-solvent: (>= (stx-get-balance (as-contract tx-sender)) obligations),
    })
  )
)

;; ============================================================
;; ADMIN / GOVERNANCE
;; ============================================================

(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (print { event: "pause-toggled", paused: paused })
    (ok (var-set contract-paused paused))
  )
)

(define-public (set-draw-interval (interval uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set draw-interval interval))
  )
)

(define-public (set-deposit-limits (new-min uint) (new-max uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set min-deposit new-min)
    (ok (var-set max-deposit new-max))
  )
)
