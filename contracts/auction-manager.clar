;; auction-manager.clar
;; Manages draw execution using a commit-reveal scheme and
;; Dutch auction incentives for prize claims.

;; ============================================================
;; CONSTANTS
;; ============================================================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-ALREADY-COMMITTED (err u5001))
(define-constant ERR-NO-COMMITMENT (err u5002))
(define-constant ERR-REVEAL-TOO-EARLY (err u5003))
(define-constant ERR-REVEAL-TOO-LATE (err u5004))
(define-constant ERR-INVALID-REVEAL (err u5005))
(define-constant ERR-AUCTION-NOT-ACTIVE (err u5006))
(define-constant ERR-AUCTION-EXPIRED (err u5007))

;; Commit-reveal parameters
(define-constant REVEAL-DELAY u2)        ;; Must wait 2 blocks after commit
(define-constant REVEAL-DEADLINE u10)     ;; Must reveal within 10 blocks

;; Dutch auction parameters
(define-constant AUCTION-DURATION u50)   ;; Auction lasts 50 blocks
(define-constant MAX-INCENTIVE u100000)  ;; Max incentive: 0.1 STX
(define-constant MIN-INCENTIVE u10000)   ;; Min incentive: 0.01 STX

;; ============================================================
;; STATE
;; ============================================================

(define-data-var request-counter uint u0)

;; Commitments for draw requests
(define-map commitments
  { requester: principal }
  {
    commit-hash: (buff 32),
    commit-block: uint,
    fulfilled: bool
  }
)

;; Auction state for prize claims
(define-map claim-auctions
  { draw-id: uint }
  {
    start-block: uint,
    is-active: bool,
    claimer: (optional principal)
  }
)

;; ============================================================
;; PUBLIC: COMMIT PHASE (request draw)
;; ============================================================

;; Step 1: Requester commits a hash of their secret seed.
;; This prevents frontrunning of the randomness.
(define-public (commit-draw-request (commit-hash (buff 32)))
  (begin
    (asserts!
      (is-none (map-get? commitments { requester: tx-sender }))
      ERR-ALREADY-COMMITTED
    )

    (map-set commitments
      { requester: tx-sender }
      {
        commit-hash: commit-hash,
        commit-block: stacks-block-height,
        fulfilled: false
      }
    )

    (print {
      event: "draw-committed",
      requester: tx-sender,
      commit-block: stacks-block-height
    })
    (ok true)
  )
)

;; ============================================================
;; PUBLIC: REVEAL PHASE (complete draw)
;; ============================================================

;; Step 2: Requester reveals their secret. The hash is verified
;; against the commitment, then combined with block data to
;; produce a verifiable random seed.
(define-public (reveal-draw-request (secret (buff 32)))
  (let (
    (commitment (unwrap! (map-get? commitments { requester: tx-sender }) ERR-NO-COMMITMENT))
  )
    (asserts! (not (get fulfilled commitment)) ERR-ALREADY-COMMITTED)
    (asserts!
      (>= stacks-block-height (+ (get commit-block commitment) REVEAL-DELAY))
      ERR-REVEAL-TOO-EARLY
    )
    (asserts!
      (<= stacks-block-height (+ (get commit-block commitment) REVEAL-DEADLINE))
      ERR-REVEAL-TOO-LATE
    )

    ;; Verify the commitment
    (asserts!
      (is-eq (keccak256 secret) (get commit-hash commitment))
      ERR-INVALID-REVEAL
    )

    ;; Generate combined seed
    (let (
      (block-data (unwrap-panic (get-stacks-block-info? id-header-hash (- stacks-block-height u1))))
      (combined-seed (keccak256 (concat secret block-data)))
    )
      ;; Trigger the draw on the prize pool
      (try! (contract-call? .prize-pool award-queen-bee combined-seed))

      ;; Mark commitment as fulfilled
      (map-set commitments
        { requester: tx-sender }
        (merge commitment { fulfilled: true })
      )

      ;; Start claim auction for the new draw
      (let (
        (draw-id (var-get request-counter))
        (new-draw-id (+ draw-id u1))
      )
        (map-set claim-auctions
          { draw-id: new-draw-id }
          {
            start-block: stacks-block-height,
            is-active: true,
            claimer: none
          }
        )
        (var-set request-counter new-draw-id)

        (print {
          event: "draw-revealed",
          requester: tx-sender,
          draw-id: new-draw-id,
          seed: combined-seed
        })
        (ok new-draw-id)
      )
    )
  )
)

;; ============================================================
;; PUBLIC: CLAIM AUCTION
;; ============================================================

;; Dutch auction: the incentive starts high and decays linearly.
;; Anyone can claim on behalf of the winner and earn the incentive.
(define-public (execute-claim-auction (draw-id uint))
  (let (
    (auction (unwrap! (map-get? claim-auctions { draw-id: draw-id }) ERR-AUCTION-NOT-ACTIVE))
  )
    (asserts! (get is-active auction) ERR-AUCTION-NOT-ACTIVE)
    (asserts!
      (<= stacks-block-height (+ (get start-block auction) AUCTION-DURATION))
      ERR-AUCTION-EXPIRED
    )

    ;; Calculate decaying incentive
    (let (
      (elapsed (- stacks-block-height (get start-block auction)))
      (incentive (calculate-incentive elapsed))
    )
      ;; Mark auction as completed
      (map-set claim-auctions
        { draw-id: draw-id }
        (merge auction { is-active: false, claimer: (some tx-sender) })
      )

      (print {
        event: "claim-auction-executed",
        draw-id: draw-id,
        claimer: tx-sender,
        incentive: incentive,
        elapsed-blocks: elapsed
      })
      (ok incentive)
    )
  )
)

;; ============================================================
;; PRIVATE: INCENTIVE CALCULATION
;; ============================================================

;; Linear decay from MAX-INCENTIVE to MIN-INCENTIVE over AUCTION-DURATION
(define-private (calculate-incentive (elapsed uint))
  (let (
    (range (- MAX-INCENTIVE MIN-INCENTIVE))
    (decay (/ (* range elapsed) AUCTION-DURATION))
  )
    (if (>= decay range)
      MIN-INCENTIVE
      (- MAX-INCENTIVE decay)
    )
  )
)

;; ============================================================
;; PUBLIC: CLEAR EXPIRED COMMITMENT
;; ============================================================

(define-public (clear-expired-commitment (requester principal))
  (let (
    (commitment (unwrap! (map-get? commitments { requester: requester }) ERR-NO-COMMITMENT))
  )
    (asserts!
      (> stacks-block-height (+ (get commit-block commitment) REVEAL-DEADLINE))
      ERR-REVEAL-TOO-EARLY
    )
    (map-delete commitments { requester: requester })
    (print { event: "commitment-cleared", requester: requester })
    (ok true)
  )
)

;; ============================================================
;; READ-ONLY
;; ============================================================

(define-read-only (get-commitment (requester principal))
  (ok (map-get? commitments { requester: requester }))
)

(define-read-only (get-claim-auction (draw-id uint))
  (ok (map-get? claim-auctions { draw-id: draw-id }))
)

(define-read-only (get-current-incentive (draw-id uint))
  (match (map-get? claim-auctions { draw-id: draw-id })
    auction (if (get is-active auction)
      (ok (calculate-incentive (- stacks-block-height (get start-block auction))))
      ERR-AUCTION-NOT-ACTIVE
    )
    ERR-AUCTION-NOT-ACTIVE
  )
)

(define-read-only (get-request-count)
  (ok (var-get request-counter))
)
