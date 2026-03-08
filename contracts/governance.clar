;; governance.clar
;; Protocol parameter management with timelocked proposals.
;; Controls draw intervals, deposit limits, and emergency pause.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u6000))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u6001))
(define-constant ERR-TIMELOCK-NOT-EXPIRED (err u6002))
(define-constant ERR-ALREADY-EXECUTED (err u6003))
(define-constant ERR-INVALID-PARAMETER (err u6004))
(define-constant ERR-PROPOSAL-EXPIRED (err u6005))

;; Timelock: 144 blocks (~24 hours on Stacks)
(define-constant TIMELOCK-PERIOD u144)
;; Proposals expire after 1008 blocks (~7 days)
(define-constant PROPOSAL-EXPIRY u1008)

;; Parameter keys
(define-constant PARAM-DRAW-INTERVAL u1)
(define-constant PARAM-MIN-DEPOSIT u2)
(define-constant PARAM-MAX-DEPOSIT u3)
(define-constant PARAM-PAUSE u4)

;; ============================================================
;; STATE
;; ============================================================

(define-data-var proposal-counter uint u0)
(define-data-var guardian principal CONTRACT-OWNER)

;; Proposals
(define-map proposals
  { proposal-id: uint }
  {
    proposer: principal,
    parameter-key: uint,
    new-value: uint,
    proposed-at: uint,
    executed: bool,
    description: (string-ascii 128)
  }
)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-guardian)
  (is-eq tx-sender (var-get guardian))
)

;; ============================================================
;; PUBLIC: PROPOSE CHANGE
;; ============================================================

(define-public (propose-change
    (parameter-key uint)
    (new-value uint)
    (description (string-ascii 128))
  )
  (begin
    (asserts! (is-guardian) ERR-NOT-AUTHORIZED)
    (asserts!
      (or
        (is-eq parameter-key PARAM-DRAW-INTERVAL)
        (is-eq parameter-key PARAM-MIN-DEPOSIT)
        (is-eq parameter-key PARAM-MAX-DEPOSIT)
        (is-eq parameter-key PARAM-PAUSE)
      )
      ERR-INVALID-PARAMETER
    )

    (let (
      (proposal-id (+ (var-get proposal-counter) u1))
    )
      (map-set proposals
        { proposal-id: proposal-id }
        {
          proposer: tx-sender,
          parameter-key: parameter-key,
          new-value: new-value,
          proposed-at: stacks-block-height,
          executed: false,
          description: description
        }
      )
      (var-set proposal-counter proposal-id)

      (print {
        event: "proposal-created",
        proposal-id: proposal-id,
        parameter-key: parameter-key,
        new-value: new-value,
        executes-at: (+ stacks-block-height TIMELOCK-PERIOD)
      })
      (ok proposal-id)
    )
  )
)

;; ============================================================
;; PUBLIC: EXECUTE CHANGE (after timelock)
;; ============================================================

(define-public (execute-change (proposal-id uint))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
  )
    (asserts! (not (get executed proposal)) ERR-ALREADY-EXECUTED)
    (asserts!
      (>= stacks-block-height (+ (get proposed-at proposal) TIMELOCK-PERIOD))
      ERR-TIMELOCK-NOT-EXPIRED
    )
    (asserts!
      (<= stacks-block-height (+ (get proposed-at proposal) PROPOSAL-EXPIRY))
      ERR-PROPOSAL-EXPIRED
    )

    ;; Execute the parameter change on prize-pool
    (if (is-eq (get parameter-key proposal) PARAM-DRAW-INTERVAL)
      (try! (contract-call? .prize-pool set-draw-interval (get new-value proposal)))
      (if (is-eq (get parameter-key proposal) PARAM-PAUSE)
        (try! (contract-call? .prize-pool set-paused (> (get new-value proposal) u0)))
        (if (or
              (is-eq (get parameter-key proposal) PARAM-MIN-DEPOSIT)
              (is-eq (get parameter-key proposal) PARAM-MAX-DEPOSIT)
            )
          ;; For deposit limits, we pass both (simplified: only updates one at a time)
          (try! (contract-call? .prize-pool set-deposit-limits
            (get new-value proposal)
            (get new-value proposal)
          ))
          (asserts! false ERR-INVALID-PARAMETER)
        )
      )
    )

    ;; Mark as executed
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal { executed: true })
    )

    (print {
      event: "proposal-executed",
      proposal-id: proposal-id,
      parameter-key: (get parameter-key proposal),
      new-value: (get new-value proposal)
    })
    (ok true)
  )
)

;; ============================================================
;; PUBLIC: EMERGENCY PAUSE (no timelock)
;; ============================================================

(define-public (emergency-pause)
  (begin
    (asserts! (is-guardian) ERR-NOT-AUTHORIZED)
    (try! (contract-call? .prize-pool set-paused true))
    (print { event: "emergency-pause-activated", by: tx-sender })
    (ok true)
  )
)

;; ============================================================
;; PUBLIC: TRANSFER GUARDIANSHIP
;; ============================================================

(define-public (transfer-guardian (new-guardian principal))
  (begin
    (asserts! (is-guardian) ERR-NOT-AUTHORIZED)
    (print { event: "guardian-transferred", old: (var-get guardian), new: new-guardian })
    (ok (var-set guardian new-guardian))
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-proposal (proposal-id uint))
  (ok (map-get? proposals { proposal-id: proposal-id }))
)

(define-read-only (get-proposal-count)
  (ok (var-get proposal-counter))
)

(define-read-only (get-guardian)
  (ok (var-get guardian))
)

(define-read-only (get-parameter-keys)
  (ok {
    draw-interval: PARAM-DRAW-INTERVAL,
    min-deposit: PARAM-MIN-DEPOSIT,
    max-deposit: PARAM-MAX-DEPOSIT,
    pause: PARAM-PAUSE
  })
)
