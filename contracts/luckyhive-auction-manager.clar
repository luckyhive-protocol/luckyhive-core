;; auction-manager.clar
;; Manages draw execution using a commit-reveal scheme for verifiable
;; randomness, preventing the draw caller from manipulating outcomes.
;;
;; Flow:
;;   1. Admin commits hash(secret) via commit-draw-request
;;   2. Wait 2+ blocks (prevents choosing favorable block hashes)
;;   3. Admin reveals secret + nominated winner via reveal-and-award
;;   4. Contract combines secret with block hash for verifiable seed
;;   5. Prize pool verifies winner has valid TWAB

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u5000))
(define-constant ERR-ALREADY-COMMITTED (err u5001))
(define-constant ERR-NO-COMMITMENT (err u5002))
(define-constant ERR-REVEAL-TOO-EARLY (err u5003))
(define-constant ERR-REVEAL-TOO-LATE (err u5004))
(define-constant ERR-INVALID-REVEAL (err u5005))

;; Commit-reveal timing
(define-constant REVEAL-DELAY u2)      ;; Must wait 2 blocks after commit
(define-constant REVEAL-DEADLINE u10)  ;; Must reveal within 10 blocks

;; ============================================================
;; STATE
;; ============================================================

;; Commitments for draw requests
(define-map commitments
  { requester: principal }
  {
    commit-hash: (buff 32),
    commit-block: uint,
    fulfilled: bool,
  }
)

;; ============================================================
;; AUTHORIZATION
;; ============================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; ============================================================
;; PUBLIC: COMMIT PHASE
;; ============================================================

;; Step 1: Commit hash(secret). The secret is not known on-chain,
;; preventing miners from front-running.
(define-public (commit-draw-request (commit-hash (buff 32)))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts!
      (is-none (map-get? commitments { requester: tx-sender }))
      ERR-ALREADY-COMMITTED
    )
    (map-set commitments { requester: tx-sender } {
      commit-hash: commit-hash,
      commit-block: stacks-block-height,
      fulfilled: false,
    })
    (print {
      event: "draw-committed",
      requester: tx-sender,
      commit-block: stacks-block-height,
    })
    (ok true)
  )
)

;; ============================================================
;; PUBLIC: REVEAL AND AWARD
;; ============================================================

;; Step 2: Reveal secret, nominate TWAB-derived winner.
;; The prize pool verifies winner has valid TWAB.
;; Combined seed = keccak256(secret + prev-block-hash)
(define-public (reveal-and-award
    (secret (buff 32))
    (winner principal)
  )
  (let (
      (commitment (unwrap!
        (map-get? commitments { requester: tx-sender })
        ERR-NO-COMMITMENT
      ))
    )
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (get fulfilled commitment)) ERR-ALREADY-COMMITTED)
    (asserts!
      (>= stacks-block-height
        (+ (get commit-block commitment) REVEAL-DELAY))
      ERR-REVEAL-TOO-EARLY
    )
    (asserts!
      (<= stacks-block-height
        (+ (get commit-block commitment) REVEAL-DEADLINE))
      ERR-REVEAL-TOO-LATE
    )
    ;; Verify commitment integrity
    (asserts!
      (is-eq (keccak256 secret) (get commit-hash commitment))
      ERR-INVALID-REVEAL
    )

    ;; Generate combined seed from secret + block data
    (let (
        (block-data (unwrap-panic
          (get-stacks-block-info? id-header-hash
            (- stacks-block-height u1))))
        (combined-seed (keccak256 (concat secret block-data)))
      )
      ;; Trigger draw on prize pool -- contract-caller will be
      ;; .luckyhive-auction-manager, which is authorized
      (try! (contract-call? .luckyhive-prize-pool
        award-queen-bee winner combined-seed))

      ;; Mark commitment as fulfilled and clean up
      (map-set commitments { requester: tx-sender }
        (merge commitment { fulfilled: true }))

      (print {
        event: "draw-revealed-and-awarded",
        requester: tx-sender,
        seed: combined-seed,
        winner: winner,
      })
      (ok true)
    )
  )
)

;; ============================================================
;; PUBLIC: CLEAR EXPIRED COMMITMENT
;; ============================================================

;; If admin fails to reveal in time, clean up the stale commitment
;; so a new draw can be initiated.
(define-public (clear-expired-commitment)
  (let (
      (commitment (unwrap!
        (map-get? commitments { requester: tx-sender })
        ERR-NO-COMMITMENT
      ))
    )
    (asserts!
      (> stacks-block-height
        (+ (get commit-block commitment) REVEAL-DEADLINE))
      ERR-REVEAL-TOO-EARLY
    )
    (map-delete commitments { requester: tx-sender })
    (print { event: "commitment-cleared", requester: tx-sender })
    (ok true)
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-commitment (requester principal))
  (ok (map-get? commitments { requester: requester }))
)
